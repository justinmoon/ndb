const std = @import("std");
pub const c = @import("c").c;
pub const profile = @import("profile.zig");

pub const Error = error{
    InitFailed,
    ProcessFailed,
    QueryFailed,
    AllocatorRequired,
    NotFound,
    TransactionEnded,
    UnsubscribeFailed,
};

pub const Config = struct {
    inner: c.struct_ndb_config = undefined,

    pub fn initDefault() Config {
        var cfg: Config = .{ .inner = undefined };
        // Zero-initialize then call C default to fill sane defaults
        @memset(std.mem.asBytes(&cfg.inner), 0);
        c.ndb_default_config(&cfg.inner);
        return cfg;
    }

    pub fn setFlags(self: *Config, flags: u32) void {
        c.ndb_config_set_flags(&self.inner, @intCast(flags));
    }

    pub fn setIngestThreads(self: *Config, threads: i32) void {
        c.ndb_config_set_ingest_threads(&self.inner, threads);
    }

    pub fn setMapSize(self: *Config, mapsize: usize) void {
        c.ndb_config_set_mapsize(&self.inner, mapsize);
    }
};

pub const Ndb = struct {
    ptr: *c.struct_ndb,

    pub fn init(allocator: std.mem.Allocator, dbdir: []const u8, cfg: *const Config) !Ndb {
        // Ensure NUL-terminated path for C
        const dbdir_z = try allocator.alloc(u8, dbdir.len + 1);
        defer allocator.free(dbdir_z);
        @memcpy(dbdir_z[0..dbdir.len], dbdir);
        dbdir_z[dbdir.len] = 0;

        var out: ?*c.struct_ndb = null;
        const ok = c.ndb_init(&out, @ptrCast(dbdir_z.ptr), &cfg.inner);
        if (ok == 0 or out == null) return Error.InitFailed;
        return .{ .ptr = out.? };
    }

    pub fn deinit(self: *Ndb) void {
        c.ndb_destroy(self.ptr);
    }

    pub fn processEvent(self: *Ndb, json: []const u8) !void {
        const ok = c.ndb_process_event(self.ptr, @ptrCast(json.ptr), @intCast(json.len));
        if (ok == 0) return Error.ProcessFailed;
    }

    pub fn subscribe(self: *Ndb, filter: *Filter, num_filters: i32) u64 {
        return c.ndb_subscribe(self.ptr, &filter.inner, num_filters);
    }

    pub fn unsubscribe(self: *Ndb, subid: u64) !void {
        const result = c.ndb_unsubscribe(self.ptr, subid);
        if (result == 0) return Error.UnsubscribeFailed;
    }

    pub fn pollForNotes(self: *Ndb, subid: u64, out_ids: []u64) i32 {
        return c.ndb_poll_for_notes(self.ptr, subid, out_ids.ptr, @intCast(out_ids.len));
    }

    pub fn waitForNotes(self: *Ndb, subid: u64, out_ids: []u64) i32 {
        return c.ndb_wait_for_notes(self.ptr, subid, out_ids.ptr, @intCast(out_ids.len));
    }

    /// Drain subscription until target count is reached or timeout
    /// For use when subscription was created BEFORE events were processed
    pub fn drainSubscription(self: *Ndb, subid: u64, target_count: usize, timeout_ms: u64) !usize {
        var ids_buf: [256]u64 = undefined;
        var total: usize = 0;
        const start_time = std.time.milliTimestamp();
        var polls: usize = 0;

        while (total < target_count) {
            const remaining = target_count - total;
            const batch_size = @min(remaining, ids_buf.len);

            // Try polling first (non-blocking)
            const got = self.pollForNotes(subid, ids_buf[0..batch_size]);

            if (got > 0) {
                total += @intCast(got);
                polls = 0; // Reset poll counter on success
                continue;
            }

            polls += 1;

            // Check timeout
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > timeout_ms or polls > 200) {
                // Return what we have so far
                return total;
            }

            // Small sleep then retry poll
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        return total;
    }

    /// Ensure background writer has processed pending events
    /// This is a workaround - ideally nostrdb would expose a flush method
    pub fn ensureProcessed(self: *Ndb, timeout_ms: u64) void {
        _ = timeout_ms;
        // The old approach of using waitForNotes with dummy subid
        // seems to help nudge the background writer
        var dummy_ids: [1]u64 = .{0};
        _ = self.waitForNotes(999999, &dummy_ids);
        // Give it a moment to actually write
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    /// Get a profile by its public key
    /// Matches Rust API: get_profile_by_pubkey(&self, transaction, pubkey)
    pub fn getProfileByPubkey(self: *Ndb, txn: *Transaction, pubkey: *const [32]u8) !profile.ProfileRecord {
        _ = self; // Method is on Ndb for API consistency
        return getProfileByPubkeyFree(txn, pubkey);
    }

    /// Get a note by its ID
    /// Matches Rust API: get_note_by_id(&self, transaction, id)
    pub fn getNoteById(self: *Ndb, txn: *Transaction, id: *const [32]u8) ?Note {
        _ = self; // Method is on Ndb for API consistency
        return getNoteByIdFree(txn, id);
    }

    /// Search for profiles matching the query string
    /// Returns references to pubkeys that are valid for the transaction lifetime
    /// This matches the Rust API: search_profile(&self, transaction, search, limit)
    pub fn searchProfile(self: *Ndb, txn: *Transaction, search: []const u8, limit: u32, allocator: std.mem.Allocator) ![]SearchResult {
        _ = self; // Method is on Ndb for API consistency with Rust
        return searchProfileFree(txn, search, limit, allocator);
    }

    /// Search for profiles using an iterator (memory efficient)
    /// Similar to Rust's zero-copy approach but adapted for Zig
    pub fn searchProfileIter(self: *Ndb, txn: *Transaction, search: []const u8, allocator: std.mem.Allocator) !ProfileSearchIterator {
        _ = self; // Method is on Ndb for API consistency
        const c_query = try allocator.dupeZ(u8, search);
        // Note: caller must manage c_query lifetime
        var iter = ProfileSearchIterator.init(txn);
        try iter.start(c_query);
        return iter;
    }
};

pub const Transaction = struct {
    inner: c.struct_ndb_txn = undefined,
    is_valid: bool = false,

    pub fn begin(ndb: *Ndb) !Transaction {
        var txn: Transaction = .{
            .inner = undefined,
            .is_valid = true,
        };
        const ok = c.ndb_begin_query(ndb.ptr, &txn.inner);
        if (ok == 0) return Error.QueryFailed;
        return txn;
    }

    pub fn end(self: *Transaction) void {
        self.is_valid = false;
        _ = c.ndb_end_query(&self.inner);
    }

    pub fn ensureValid(self: Transaction) !void {
        if (!self.is_valid) return Error.TransactionEnded;
    }
};

pub const Note = struct {
    ptr: *c.struct_ndb_note,

    pub fn kind(self: Note) u32 {
        return c.ndb_note_kind(self.ptr);
    }

    pub fn createdAt(self: Note) u32 {
        return c.ndb_note_created_at(self.ptr);
    }

    pub fn id(self: Note) [32]u8 {
        var out: [32]u8 = undefined;
        const src = c.ndb_note_id(self.ptr);
        @memcpy(out[0..], src[0..32]);
        return out;
    }

    pub fn pubkey(self: Note) [32]u8 {
        var out: [32]u8 = undefined;
        const src = c.ndb_note_pubkey(self.ptr);
        @memcpy(out[0..], src[0..32]);
        return out;
    }

    pub fn content(self: Note) []const u8 {
        const s = c.ndb_note_content(self.ptr);
        return std.mem.span(s);
    }

    pub fn json(self: Note, allocator: std.mem.Allocator) ![]u8 {
        // Serialize to a temporary fixed buffer, then copy into allocator-owned slice.
        var buf: [4096]u8 = undefined;
        const written = c.ndb_note_json(self.ptr, &buf, buf.len);
        if (written <= 0) return Error.QueryFailed;
        return allocator.dupe(u8, buf[0..@intCast(written)]);
    }
};

pub const NoteKey = u64;

pub const Filter = struct {
    inner: c.struct_ndb_filter = undefined,

    pub fn init() !Filter {
        var f: Filter = .{ .inner = undefined };
        const ok = c.ndb_filter_init(&f.inner);
        if (ok == 0) return Error.QueryFailed;
        return f;
    }

    pub fn deinit(self: *Filter) void {
        c.ndb_filter_destroy(&self.inner);
    }

    pub fn kinds(self: *Filter, kinds_slice: []const u64) !void {
        if (c.ndb_filter_start_field(&self.inner, c.NDB_FILTER_KINDS) == 0) return Error.QueryFailed;
        for (kinds_slice) |k| {
            if (c.ndb_filter_add_int_element(&self.inner, k) == 0) return Error.QueryFailed;
        }
        c.ndb_filter_end_field(&self.inner);
        if (c.ndb_filter_end(&self.inner) == 0) return Error.QueryFailed;
    }

    pub fn ids(self: *Filter, id_list: []const [32]u8) !void {
        if (c.ndb_filter_start_field(&self.inner, c.NDB_FILTER_IDS) == 0) return Error.QueryFailed;
        for (id_list) |id| {
            if (c.ndb_filter_add_id_element(&self.inner, &id[0]) == 0) return Error.QueryFailed;
        }
        c.ndb_filter_end_field(&self.inner);
        if (c.ndb_filter_end(&self.inner) == 0) return Error.QueryFailed;
    }
};

pub const FilterElements = struct {
    inner: *c.struct_ndb_filter_elements,

    pub fn fieldType(self: FilterElements) c.enum_ndb_filter_fieldtype {
        return self.inner.field.type;
    }

    pub fn count(self: FilterElements) i32 {
        return self.inner.count;
    }

    pub fn intAt(self: FilterElements, index: i32) u64 {
        return c.ndb_filter_get_int_element(self.inner, index);
    }

    pub fn intPtrAt(self: FilterElements, index: i32) *u64 {
        return c.ndb_filter_get_int_element_ptr(self.inner, index);
    }

    pub fn stringAt(self: FilterElements, filter: *Filter, index: i32) []const u8 {
        const s = c.ndb_filter_get_string_element(&filter.inner, self.inner, index);
        return std.mem.span(s);
    }
};

pub const FilterBuilder = struct {
    filter: *Filter,
    built: bool = false,

    pub fn init(filter: *Filter) FilterBuilder {
        return .{ .filter = filter, .built = false };
    }

    pub fn kinds(self: *FilterBuilder, kinds_slice: []const u64) !*FilterBuilder {
        if (c.ndb_filter_start_field(&self.filter.inner, c.NDB_FILTER_KINDS) == 0) return Error.QueryFailed;
        for (kinds_slice) |k| if (c.ndb_filter_add_int_element(&self.filter.inner, k) == 0) return Error.QueryFailed;
        c.ndb_filter_end_field(&self.filter.inner);
        return self;
    }

    pub fn limit(self: *FilterBuilder, n: u64) !*FilterBuilder {
        if (c.ndb_filter_start_field(&self.filter.inner, c.NDB_FILTER_LIMIT) == 0) return Error.QueryFailed;
        if (c.ndb_filter_add_int_element(&self.filter.inner, n) == 0) return Error.QueryFailed;
        c.ndb_filter_end_field(&self.filter.inner);
        return self;
    }

    pub fn since(self: *FilterBuilder, ts: u64) !*FilterBuilder {
        if (c.ndb_filter_start_field(&self.filter.inner, c.NDB_FILTER_SINCE) == 0) return Error.QueryFailed;
        if (c.ndb_filter_add_int_element(&self.filter.inner, ts) == 0) return Error.QueryFailed;
        c.ndb_filter_end_field(&self.filter.inner);
        return self;
    }

    pub fn ids(self: *FilterBuilder, id_list: []const [32]u8) !*FilterBuilder {
        if (c.ndb_filter_start_field(&self.filter.inner, c.NDB_FILTER_IDS) == 0) return Error.QueryFailed;
        for (id_list) |id| if (c.ndb_filter_add_id_element(&self.filter.inner, &id[0]) == 0) return Error.QueryFailed;
        c.ndb_filter_end_field(&self.filter.inner);
        return self;
    }

    pub fn authors(self: *FilterBuilder, authors_list: []const [32]u8) !*FilterBuilder {
        if (c.ndb_filter_start_field(&self.filter.inner, c.NDB_FILTER_AUTHORS) == 0) return Error.QueryFailed;
        for (authors_list) |author| if (c.ndb_filter_add_id_element(&self.filter.inner, &author[0]) == 0) return Error.QueryFailed;
        c.ndb_filter_end_field(&self.filter.inner);
        return self;
    }

    pub fn event(self: *FilterBuilder, id_list: []const [32]u8) !*FilterBuilder {
        if (c.ndb_filter_start_tag_field(&self.filter.inner, 'e') == 0) return Error.QueryFailed;
        for (id_list) |id| if (c.ndb_filter_add_id_element(&self.filter.inner, &id[0]) == 0) return Error.QueryFailed;
        c.ndb_filter_end_field(&self.filter.inner);
        return self;
    }

    pub fn build(self: *FilterBuilder) !void {
        if (self.built) return;
        if (c.ndb_filter_end(&self.filter.inner) == 0) return Error.QueryFailed;
        self.built = true;
    }
};

pub fn filterElementsAt(filter: *Filter, index: i32) ?FilterElements {
    const elems = c.ndb_filter_get_elements(&filter.inner, index);
    if (elems == null) return null;
    return FilterElements{ .inner = elems.? };
}

pub fn findField(filter: *Filter, typ: c.enum_ndb_filter_fieldtype) ?FilterElements {
    var i: i32 = 0;
    while (true) : (i += 1) {
        const opt = c.ndb_filter_get_elements(&filter.inner, i);
        if (opt == null) break;
        const ptr = opt.?;
        if (ptr.*.field.type == typ) return FilterElements{ .inner = ptr };
    }
    return null;
}

pub fn hexTo32(out: *[32]u8, hex_str: []const u8) !void {
    if (hex_str.len != 64) return error.InvalidHex;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = try fromHexNibble(hex_str[i * 2]);
        const lo = try fromHexNibble(hex_str[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
}

fn fromHexNibble(cu: u8) !u8 {
    return switch (cu) {
        '0'...'9' => cu - '0',
        'a'...'f' => 10 + (cu - 'a'),
        'A'...'F' => 10 + (cu - 'A'),
        else => error.InvalidHex,
    };
}

pub fn getNoteByIdFree(txn: *Transaction, id: *const [32]u8) ?Note {
    var note_len: usize = 0;
    var primkey: u64 = 0;
    const note_ptr = c.ndb_get_note_by_id(&txn.inner, &id[0], &note_len, &primkey);
    if (note_ptr == null) return null;
    return Note{ .ptr = note_ptr.? };
}

pub fn getProfileByPubkeyFree(txn: *Transaction, pubkey: *const [32]u8) !profile.ProfileRecord {
    var len: usize = 0;
    var primkey: u64 = 0;
    const profile_ptr = c.ndb_get_profile_by_pubkey(&txn.inner, &pubkey[0], &len, &primkey);
    if (profile_ptr == null) return Error.NotFound;

    return profile.ProfileRecord{
        .ptr = profile_ptr.?,
        .len = len,
        .primary_key = profile.ProfileKey.new(primkey),
        .txn = txn,
    };
}

pub const SearchResult = struct {
    pubkey: [32]u8,
};

// Export search types for direct use
const search_mod = @import("search.zig");
pub const ProfileSearchIterator = search_mod.ProfileSearchIterator;
pub const SearchWindow = search_mod.SearchWindow;

/// Free function for backward compatibility
pub fn searchProfileFree(txn: *Transaction, search_query: []const u8, limit: u32, allocator: std.mem.Allocator) ![]SearchResult {
    // Use the new iterator-based implementation for better memory efficiency
    return try search_mod.searchProfileCompat(txn, search_query, limit, allocator);
}

pub const QueryResult = struct {
    note: Note,
    note_id: u64,
};

pub fn query(txn: *Transaction, filters: []Filter, results_out: []QueryResult) !usize {
    return queryWithAllocator(txn, filters, results_out, null);
}

/// Query with optional allocator for large result sets
/// For small queries (<=64 results, <=8 filters), uses stack allocation
/// For larger queries, requires an allocator to be passed
pub fn queryWithAllocator(txn: *Transaction, filters: []Filter, results_out: []QueryResult, allocator: ?std.mem.Allocator) !usize {
    var count: c_int = 0;

    // Stack allocation for common cases
    const MAX_STACK_RESULTS = 64;
    const MAX_STACK_FILTERS = 8;

    // Handle results allocation
    var stack_results: [MAX_STACK_RESULTS]c.struct_ndb_query_result = undefined;
    var heap_results: ?[]c.struct_ndb_query_result = null;
    defer if (heap_results) |h| allocator.?.free(h);

    const c_results = if (results_out.len <= MAX_STACK_RESULTS)
        stack_results[0..results_out.len]
    else blk: {
        if (allocator == null) return Error.AllocatorRequired;
        heap_results = try allocator.?.alloc(c.struct_ndb_query_result, results_out.len);
        break :blk heap_results.?;
    };

    // Handle filters allocation
    var stack_filters: [MAX_STACK_FILTERS]c.struct_ndb_filter = undefined;
    var heap_filters: ?[]c.struct_ndb_filter = null;
    defer if (heap_filters) |h| allocator.?.free(h);

    const tmp_filters = if (filters.len <= MAX_STACK_FILTERS)
        stack_filters[0..filters.len]
    else blk: {
        if (allocator == null) return Error.AllocatorRequired;
        heap_filters = try allocator.?.alloc(c.struct_ndb_filter, filters.len);
        break :blk heap_filters.?;
    };

    for (filters, 0..) |f, i| tmp_filters[i] = f.inner;

    const ok = c.ndb_query(&txn.inner, &tmp_filters[0], @intCast(tmp_filters.len), &c_results[0], @intCast(c_results.len), &count);
    if (ok == 0) return Error.QueryFailed;

    const n: usize = @intCast(count);
    var i: usize = 0;
    while (i < n and i < results_out.len) : (i += 1) {
        const note_ptr = c_results[i].note.?;
        results_out[i] = .{ .note = .{ .ptr = note_ptr }, .note_id = c_results[i].note_id };
    }
    return n;
}

pub const Keypair = struct {
    inner: c.struct_ndb_keypair = undefined,

    pub fn create() !Keypair {
        var kp: Keypair = .{ .inner = undefined };
        if (c.ndb_create_keypair(&kp.inner) == 0) return Error.QueryFailed;
        return kp;
    }
};

pub const NoteBuilder = struct {
    builder: c.struct_ndb_builder = undefined,
    buf: []u8,

    pub fn init(allocator: std.mem.Allocator, buf_size: usize) !NoteBuilder {
        // Use c_allocator (which wraps malloc/free) like nostrdb-rs
        // FIXME: allocator parameter is ignored; kept for API symmetry.
        _ = allocator;

        var nb: NoteBuilder = .{ .builder = undefined, .buf = try std.heap.c_allocator.alloc(u8, buf_size) };
        errdefer std.heap.c_allocator.free(nb.buf);

        if (c.ndb_builder_init(&nb.builder, nb.buf.ptr, nb.buf.len) == 0) {
            std.heap.c_allocator.free(nb.buf);
            return Error.QueryFailed;
        }
        return nb;
    }

    pub fn deinit(self: *NoteBuilder) void {
        std.heap.c_allocator.free(self.buf);
    }

    pub fn setContent(self: *NoteBuilder, content: []const u8) !void {
        if (c.ndb_builder_set_content(&self.builder, @ptrCast(content.ptr), @intCast(content.len)) == 0) return Error.QueryFailed;
    }

    pub fn setKind(self: *NoteBuilder, kind: u32) void {
        c.ndb_builder_set_kind(&self.builder, kind);
    }

    pub fn setCreatedAt(self: *NoteBuilder, ts: u64) void {
        c.ndb_builder_set_created_at(&self.builder, ts);
    }

    pub fn newTag(self: *NoteBuilder) !void {
        if (c.ndb_builder_new_tag(&self.builder) == 0) return Error.QueryFailed;
    }

    pub fn pushTagStr(self: *NoteBuilder, s: []const u8) !void {
        if (c.ndb_builder_push_tag_str(&self.builder, @ptrCast(s.ptr), @intCast(s.len)) == 0) return Error.QueryFailed;
    }

    pub fn pushTagId(self: *NoteBuilder, id: *[32]u8) !void {
        if (c.ndb_builder_push_tag_id(&self.builder, &id[0]) == 0) return Error.QueryFailed;
    }

    pub fn finalize(self: *NoteBuilder, keypair: *Keypair) !Note {
        var note_ptr: ?*c.struct_ndb_note = null;
        if (c.ndb_builder_finalize(&self.builder, &note_ptr, &keypair.inner) == 0) return Error.QueryFailed;
        return Note{ .ptr = note_ptr.? };
    }

    pub fn finalizeUnsigned(self: *NoteBuilder) !Note {
        var note_ptr: ?*c.struct_ndb_note = null;
        if (c.ndb_builder_finalize(&self.builder, &note_ptr, null) == 0) return Error.QueryFailed;
        return Note{ .ptr = note_ptr.? };
    }
};

pub const TagIter = struct {
    iter: c.struct_ndb_iterator = .{ .note = undefined, .tag = undefined, .index = 0 },

    pub fn start(note: Note) TagIter {
        var it: TagIter = .{};
        c.ndb_tags_iterate_start(note.ptr, &it.iter);
        return it;
    }

    pub fn next(self: *TagIter) bool {
        return c.ndb_tags_iterate_next(&self.iter) != 0;
    }

    pub fn tagStr(self: *TagIter, idx: i32) []const u8 {
        const s = c.ndb_iter_tag_str(&self.iter, idx);
        const len: usize = @intCast(c.ndb_str_len(@constCast(&s)));
        const ptr = s.unnamed_0.str;
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }
};

pub const BlocksIter = struct {
    iter: c.struct_ndb_block_iterator = .{ .content = undefined, .blocks = undefined, .block = undefined, .p = undefined },

    pub fn start(content: []const u8, blocks: *c.struct_ndb_blocks) BlocksIter {
        var it: BlocksIter = .{};
        c.ndb_blocks_iterate_start(@ptrCast(content.ptr), blocks, &it.iter);
        return it;
    }

    pub fn next(self: *BlocksIter) ?*c.struct_ndb_block {
        return c.ndb_blocks_iterate_next(&self.iter);
    }
};

pub const BlocksOwner = struct {
    blocks: *c.struct_ndb_blocks,
    buf: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BlocksOwner) void {
        c.ndb_blocks_free(self.blocks);
        self.allocator.free(self.buf);
    }
};

pub fn parseContentBlocks(allocator: std.mem.Allocator, content: []const u8) !BlocksOwner {
    // Provide an aligned scratch buffer (use C allocator for safe alignment)
    // 32KB scratch is enough for small tests
    _ = allocator;
    const buf = try std.heap.c_allocator.alignedAlloc(u8, @enumFromInt(3), 32 * 1024);
    errdefer std.heap.c_allocator.free(buf);
    var blocks_ptr: ?*c.struct_ndb_blocks = null;
    if (c.ndb_parse_content(buf.ptr, @intCast(buf.len), @ptrCast(content.ptr), @intCast(content.len), &blocks_ptr) == 0) {
        return Error.QueryFailed;
    }
    return .{ .blocks = blocks_ptr.?, .buf = buf, .allocator = std.heap.c_allocator };
}
