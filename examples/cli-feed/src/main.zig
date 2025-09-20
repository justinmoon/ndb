const std = @import("std");
const ndb = @import("nostrdb");
const relay_pool = @import("pool.zig");
const nostr = @import("nostr.zig");

const DbContext = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    db: ndb.Ndb,
};

fn bytesToHexLower(bytes: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= bytes.len * 2);
    const digits = "0123456789abcdef";
    var i: usize = 0;
    for (bytes) |b| {
        out[i] = digits[(b >> 4) & 0xF];
        out[i + 1] = digits[b & 0xF];
        i += 2;
    }
    return out[0 .. bytes.len * 2];
}

fn initDb(allocator: std.mem.Allocator) !DbContext {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    errdefer allocator.free(path);

    var cfg = ndb.Config.initDefault();
    const db = try ndb.Ndb.init(allocator, path, &cfg);

    return DbContext{ .tmp = tmp, .path = path, .db = db };
}

fn shutdownDb(allocator: std.mem.Allocator, ctx: *DbContext) void {
    ctx.db.deinit();
    allocator.free(ctx.path);
    ctx.tmp.cleanup();
}

fn handleEvent(ctx: *DbContext, allocator: std.mem.Allocator, event: *relay_pool.Event) void {
    switch (event.*) {
        .connected => |payload| {
            std.debug.print("connected to {s}\n", .{payload.url});
        },
        .disconnect => |payload| {
            std.debug.print("disconnected {s}: {s}\n", .{ payload.url, payload.reason });
        },
        .notice => |payload| {
            std.debug.print("notice from {s}: {s}\n", .{ payload.relay, payload.message });
        },
        .failure => |payload| {
            std.debug.print("failure from {s}: {s}\n", .{ payload.relay, payload.message });
        },
        .eose => |payload| {
            std.debug.print("{s} completed subscription {s}\n", .{ payload.relay, payload.subscription });
        },
        .publish_ack => |payload| {
            std.debug.print(
                "publish ack from {s} accepted={any} id={s} message={s}\n",
                .{ payload.relay, payload.accepted, payload.event_id, payload.message },
            );
        },
        .received => |payload| {
            const raw_message = payload.payload;

            var parsed = nostr.parseEventMessage(allocator, raw_message) catch |err| {
                std.debug.print("failed to parse event from {s}: {s}\n", .{ payload.relay, @errorName(err) });
                return;
            };
            defer parsed.deinit(allocator);

            std.debug.print(
                "event {s} kind={d} content=\"{s}\"\n",
                .{ parsed.event.id, parsed.event.kind, parsed.event.content },
            );

            if (nostr.formatEventMessage(allocator, &parsed) catch null) |reserialized| {
                defer allocator.free(reserialized);
            }

            const aligned = std.heap.c_allocator.dupe(u8, raw_message) catch {
                std.debug.print("failed to allocate aligned event from {s}\n", .{payload.relay});
                return;
            };
            defer std.heap.c_allocator.free(aligned);

            {
                @setRuntimeSafety(false);
                ctx.db.processEvent(aligned) catch |err| {
                    std.debug.print("processEvent failed for {s}: {s}\n", .{ payload.relay, @errorName(err) });
                    return;
                };
            }
            ctx.db.ensureProcessed(250);

            var id_bytes: [32]u8 = undefined;
            ndb.hexTo32(&id_bytes, parsed.event.id) catch {
                std.debug.print("invalid event id from {s}\n", .{payload.relay});
                return;
            };

            var txn = ndb.Transaction.begin(&ctx.db) catch |err| {
                std.debug.print("transaction begin failed: {s}\n", .{@errorName(err)});
                return;
            };
            defer txn.end();

            if (ndb.getNoteByIdFree(&txn, &id_bytes)) |note| {
                const note_id = note.id();
                var note_id_hex_buf: [64]u8 = undefined;
                const note_id_hex = bytesToHexLower(note_id[0..], &note_id_hex_buf);

                const note_pubkey = note.pubkey();
                var note_pubkey_hex_buf: [64]u8 = undefined;
                const note_pubkey_hex = bytesToHexLower(note_pubkey[0..], &note_pubkey_hex_buf);

                const id_matches = std.mem.eql(u8, note_id_hex, parsed.event.id);
                const pubkey_matches = std.mem.eql(u8, note_pubkey_hex, parsed.event.pubkey);
                const kind_matches = note.kind() == parsed.event.kind;
                const content_matches = std.mem.eql(u8, note.content(), parsed.event.content);

                if (id_matches and pubkey_matches and kind_matches and content_matches) {
                    std.debug.print("verified stored event {s}\n", .{parsed.event.id});
                } else {
                    std.debug.print("stored event mismatch for {s} (id={any} pubkey={any} kind={any} content={any})\n", .{
                        parsed.event.id,
                        id_matches,
                        pubkey_matches,
                        kind_matches,
                        content_matches,
                    });
                }
            }
        },
        .shutdown_complete => std.debug.print("relay worker stopped\n", .{}),
    }
}

fn buildPublishEvent(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const prefix = "{\"id\":\"0a350c5851af6f6ce368bab4e2d4fe442a1318642c7fe58de5392103700c10fc\",\"pubkey\":\"dfa3fc062f7430dab3d947417fd3c6fb38a7e60f82ffe3387e2679d4c6919b1d\",\"created_at\":1704404822,\"kind\":1,\"tags\":[],\"content\":\"";
    const suffix = "\",\"sig\":\"48a0bb9560b89ee2c6b88edcf1cbeeff04f5e1b10d26da8564cac851065f30fa6961ee51f450cefe5e8f4895e301e8ffb2be06a2ff44259684fbd4ea1c885696\"}";
    return std.mem.concat(allocator, u8, &.{ prefix, content, suffix });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try initDb(allocator);
    defer shutdownDb(allocator, &ctx);

    var pool = try relay_pool.RelayPool.init(allocator);
    defer pool.deinit();

    const relays = [_][]const u8{
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
    };

    const filters_json = "{\"kinds\":[1],\"limit\":200}";
    const subscription = relay_pool.SubscriptionSpec{ .id = "cli-feed", .filters_json = filters_json };

    for (relays) |relay_url| {
        try pool.addRelay(relay_url, &.{subscription});
    }

    const publish_payload = try buildPublishEvent(allocator, "hello from cli-feed");
    defer allocator.free(publish_payload);
    std.Thread.sleep(300 * std.time.ns_per_ms);
    try pool.publish(&relays, publish_payload);

    const start_ms = std.time.milliTimestamp();
    const runtime_ms: i64 = 6_000;

    while (std.time.milliTimestamp() - start_ms < runtime_ms) {
        if (pool.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit(allocator);
            handleEvent(&ctx, allocator, &event);
        } else {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    while (pool.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit(allocator);
        handleEvent(&ctx, allocator, &event);
    }
}
