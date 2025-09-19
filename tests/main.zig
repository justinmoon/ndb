const std = @import("std");
const ndb = @import("nostrdb");

const DbContext = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    db: ndb.Ndb,
};

fn initDb(allocator: std.mem.Allocator) !DbContext {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    errdefer allocator.free(path);

    var cfg = ndb.Config.initDefault();
    const db = try ndb.Ndb.init(allocator, path, &cfg);

    return DbContext{ .tmp = tmp, .path = path, .db = db };
}

const sample_note_event = "[\"EVENT\",\"s\",{\"id\":\"0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930\",\"pubkey\":\"aeadd3bf2fd92e509e137c9e8bdf20e99f286b90be7692434e03c015e1d3bbfe\",\"created_at\":1704401597,\"kind\":1,\"tags\":[],\"content\":\"hello\",\"sig\":\"232395427153b693e0426b93d89a8319324d8657e67d23953f014a22159d2127b4da20b95644b3e34debd5e20be0401c283e7308ccb63c1c1e0f81cac7502f09\"}]";

const sample_note_event_two = "[\"EVENT\",\"s\",{\"id\":\"0a350c5851af6f6ce368bab4e2d4fe442a1318642c7fe58de5392103700c10fc\",\"pubkey\":\"dfa3fc062f7430dab3d947417fd3c6fb38a7e60f82ffe3387e2679d4c6919b1d\",\"created_at\":1704404822,\"kind\":1,\"tags\":[],\"content\":\"hello2\",\"sig\":\"48a0bb9560b89ee2c6b88edcf1cbeeff04f5e1b10d26da8564cac851065f30fa6961ee51f450cefe5e8f4895e301e8ffb2be06a2ff44259684fbd4ea1c885696\"}]";


fn shutdownDb(allocator: std.mem.Allocator, ctx: *DbContext) void {
    ctx.db.deinit();
    allocator.free(ctx.path);
    ctx.tmp.cleanup();
}

test "open database" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = try initDb(alloc);
    defer shutdownDb(alloc, &ctx);
}

test "process event and fetch by id" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = try initDb(alloc);
    defer shutdownDb(alloc, &ctx);

    try ctx.db.processEvent(sample_note_event);
    ctx.db.ensureProcessed(500);

    var id_bytes: [32]u8 = undefined;
    try ndb.hexTo32(&id_bytes, "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");

    var txn = try ndb.Transaction.begin(&ctx.db);
    defer txn.end();
    const note_opt = ndb.getNoteByIdFree(&txn, &id_bytes);
    try std.testing.expect(note_opt != null);
    const note = note_opt.?;
    try std.testing.expectEqual(@as(u32, 1), note.kind());
    try std.testing.expect(std.mem.eql(u8, note.content(), "hello"));
}

test "query by ids" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = try initDb(alloc);
    defer shutdownDb(alloc, &ctx);

    try ctx.db.processEvent(sample_note_event);
    try ctx.db.processEvent(sample_note_event_two);
    ctx.db.ensureProcessed(200);

    var txn = try ndb.Transaction.begin(&ctx.db);
    defer txn.end();

    var id_one: [32]u8 = undefined;
    var id_two: [32]u8 = undefined;
    try ndb.hexTo32(&id_one, "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");
    try ndb.hexTo32(&id_two, "0a350c5851af6f6ce368bab4e2d4fe442a1318642c7fe58de5392103700c10fc");
    var filters = [_]ndb.Filter{try ndb.Filter.init()};
    defer filters[0].deinit();
    try filters[0].ids(&.{ id_one, id_two });

    var results: [4]ndb.QueryResult = undefined;
    const count = try ndb.query(&txn, filters[0..], results[0..]);
    try std.testing.expectEqual(@as(usize, 2), count);

    const contents = [_][]const u8{ results[0].note.content(), results[1].note.content() };
    var saw_hello = false;
    var saw_hello2 = false;
    for (contents) |c| {
        if (std.mem.eql(u8, c, "hello")) saw_hello = true;
        if (std.mem.eql(u8, c, "hello2")) saw_hello2 = true;
    }
    try std.testing.expect(saw_hello and saw_hello2);
}
