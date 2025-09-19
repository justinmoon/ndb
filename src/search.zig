// Iterator-based search implementation for improved memory efficiency
const std = @import("std");
const c = @import("c").c;
const ndb = @import("ndb.zig");

/// Search iterator for lazy evaluation of profile search results
/// This avoids allocating all results upfront, allowing for:
/// - Memory-efficient large result sets
/// - Early termination when enough results are found
/// - No allocator needed for the iterator itself
pub const ProfileSearchIterator = struct {
    search: c.struct_ndb_search,
    txn: *ndb.Transaction,
    initialized: bool,
    first_returned: bool,
    ended: bool,

    /// Initialize a new search iterator
    pub fn init(txn: *ndb.Transaction) ProfileSearchIterator {
        return .{
            .search = .{
                .key = null,
                .profile_key = 0,
                .cursor = null,
            },
            .txn = txn,
            .initialized = false,
            .first_returned = false,
            .ended = false,
        };
    }

    /// Start the search. Call this before calling next().
    /// Returns error if search initialization fails
    pub fn start(self: *ProfileSearchIterator, query: [:0]const u8) !void {
        if (self.initialized) return;

        const success = c.ndb_search_profile(&self.txn.inner, &self.search, query.ptr);
        if (success == 0) {
            self.ended = true;
            return error.SearchFailed;
        }
        self.initialized = true;
    }

    /// Get the next search result
    /// Returns null when no more results are available
    pub fn next(self: *ProfileSearchIterator) ?[32]u8 {
        if (!self.initialized or self.ended) return null;

        // First call after start() should return the initial result
        if (!self.first_returned) {
            self.first_returned = true;
            if (self.search.key) |key| {
                return key.*.id;
            }
        }

        // Subsequent calls need to advance the cursor
        const success = c.ndb_search_profile_next(&self.search);
        if (success == 0) {
            self.ended = true;
            return null;
        }

        if (self.search.key) |key| {
            return key.*.id;
        }

        return null;
    }

    /// Clean up the search cursor
    pub fn deinit(self: *ProfileSearchIterator) void {
        if (self.initialized and !self.ended) {
            c.ndb_search_profile_end(&self.search);
            self.ended = true;
        }
    }

    /// Collect up to `limit` results into a slice
    /// Caller owns the returned slice and must free it
    pub fn collect(self: *ProfileSearchIterator, allocator: std.mem.Allocator, limit: usize) ![]ndb.SearchResult {
        var results = try std.ArrayList(ndb.SearchResult).initCapacity(allocator, @min(limit, 100));
        defer results.deinit(allocator);

        var count: usize = 0;
        while (count < limit) : (count += 1) {
            const pubkey = self.next() orelse break;
            try results.append(allocator, .{ .pubkey = pubkey });
        }

        return try results.toOwnedSlice(allocator);
    }

    /// Take the first N results, returning an array (no allocation needed)
    pub fn take(self: *ProfileSearchIterator, comptime n: usize) [n]?[32]u8 {
        var results: [n]?[32]u8 = undefined;
        for (&results) |*result| {
            result.* = self.next();
        }
        return results;
    }
};

/// Fixed-size search result window for pagination
/// Avoids dynamic allocation by using a fixed buffer
pub const SearchWindow = struct {
    pub const max_window_size = 100;

    results: [max_window_size]ndb.SearchResult,
    count: usize,
    has_more: bool,

    /// Search and fill a window with up to window_size results
    pub fn search(txn: *ndb.Transaction, query: [:0]const u8, window_size: usize) !SearchWindow {
        var window = SearchWindow{
            .results = undefined,
            .count = 0,
            .has_more = false,
        };

        const actual_size = @min(window_size, max_window_size);

        var iter = ProfileSearchIterator.init(txn);
        defer iter.deinit();
        try iter.start(query);

        var i: usize = 0;
        while (i < actual_size) : (i += 1) {
            const pubkey = iter.next() orelse break;
            window.results[i] = .{ .pubkey = pubkey };
            window.count = i + 1;
        }

        // Check if there are more results
        if (iter.next() != null) {
            window.has_more = true;
        }

        return window;
    }

    /// Get the results as a slice
    pub fn getResults(self: *const SearchWindow) []const ndb.SearchResult {
        return self.results[0..self.count];
    }
};

/// Convenience function that maintains backward compatibility
/// This allocates all results like before, but uses the iterator internally
pub fn searchProfileCompat(txn: *ndb.Transaction, query: []const u8, limit: u32, allocator: std.mem.Allocator) ![]ndb.SearchResult {
    // Create null-terminated query
    const c_query = try allocator.dupeZ(u8, query);
    defer allocator.free(c_query);

    var iter = ProfileSearchIterator.init(txn);
    defer iter.deinit();

    try iter.start(c_query);
    return try iter.collect(allocator, limit);
}

/// Memory-efficient streaming search that processes results one at a time
/// The callback is called for each result until it returns false or no more results
pub fn streamSearchProfile(txn: *ndb.Transaction, query: [:0]const u8, context: anytype, callback: fn (@TypeOf(context), pubkey: [32]u8) bool) !usize {
    var iter = ProfileSearchIterator.init(txn);
    defer iter.deinit();
    try iter.start(query);

    var count: usize = 0;
    while (iter.next()) |pubkey| {
        if (!callback(context, pubkey)) break;
        count += 1;
    }

    return count;
}
