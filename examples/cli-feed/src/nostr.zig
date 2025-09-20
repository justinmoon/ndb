const std = @import("std");

const Allocator = std.mem.Allocator;
const json = std.json;

pub const ParseError = error{
    OutOfMemory,
    InvalidJson,
    InvalidMessageFormat,
    InvalidMessageType,
    MissingField,
    InvalidFieldType,
};

pub const Tag = struct {
    values: []([]const u8),

    pub fn deinit(self: *Tag, allocator: Allocator) void {
        for (self.values) |slice| allocator.free(slice);
        allocator.free(self.values);
    }
};

pub const Event = struct {
    id: []const u8,
    pubkey: []const u8,
    created_at: i64,
    kind: u32,
    tags: []Tag,
    content: []const u8,
    sig: []const u8,

    pub fn deinit(self: *Event, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.pubkey);
        allocator.free(self.content);
        allocator.free(self.sig);
        for (self.tags) |*tag| tag.deinit(allocator);
        allocator.free(self.tags);
    }

    pub fn eql(a: Event, b: Event) bool {
        if (!std.mem.eql(u8, a.id, b.id)) return false;
        if (!std.mem.eql(u8, a.pubkey, b.pubkey)) return false;
        if (a.created_at != b.created_at) return false;
        if (a.kind != b.kind) return false;
        if (!std.mem.eql(u8, a.content, b.content)) return false;
        if (!std.mem.eql(u8, a.sig, b.sig)) return false;
        if (a.tags.len != b.tags.len) return false;
        for (a.tags, b.tags) |tag_a, tag_b| {
            if (tag_a.values.len != tag_b.values.len) return false;
            for (tag_a.values, tag_b.values) |val_a, val_b| {
                if (!std.mem.eql(u8, val_a, val_b)) return false;
            }
        }
        return true;
    }
};

pub const EventMessage = struct {
    subscription: []const u8,
    event: Event,

    pub fn deinit(self: *EventMessage, allocator: Allocator) void {
        allocator.free(self.subscription);
        self.event.deinit(allocator);
    }
};

pub fn parseEventMessage(allocator: Allocator, raw: []const u8) ParseError!EventMessage {
    var parsed = json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch {
        return ParseError.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const array_value = switch (root) {
        .array => |arr| arr,
        else => return ParseError.InvalidMessageFormat,
    };
    const items = array_value.items;
    if (items.len < 3) return ParseError.InvalidMessageFormat;

    const typ_str = switch (items[0]) {
        .string => |s| s,
        else => return ParseError.InvalidMessageFormat,
    };
    if (!std.mem.eql(u8, typ_str, "EVENT")) return ParseError.InvalidMessageType;

    const sub_str = switch (items[1]) {
        .string => |s| s,
        else => return ParseError.InvalidFieldType,
    };

    var message = EventMessage{
        .subscription = try allocator.dupe(u8, sub_str),
        .event = undefined,
    };
    errdefer message.deinit(allocator);

    message.event = try parseEventValue(allocator, items[2]);

    return message;
}

pub fn formatEventMessage(allocator: Allocator, message: *const EventMessage) ![]u8 {
    var buffer = std.io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var stringify = json.Stringify{ .options = .{}, .writer = &buffer.writer };

    try stringify.beginArray();
    try stringify.write("EVENT");
    try stringify.write(message.subscription);
    try writeEventObject(&stringify, &message.event);
    try stringify.endArray();

    return try buffer.toOwnedSlice();
}

pub fn parseEventObject(allocator: Allocator, raw: []const u8) ParseError!Event {
    var parsed = json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch {
        return ParseError.InvalidJson;
    };
    defer parsed.deinit();

    return switch (parsed.value) {
        .object => |*obj| parseEventFromObject(allocator, obj),
        else => ParseError.InvalidMessageFormat,
    };
}

pub fn formatEventObject(allocator: Allocator, event: *const Event) ![]u8 {
    var buffer = std.io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var stringify = json.Stringify{ .options = .{}, .writer = &buffer.writer };
    try writeEventObject(&stringify, event);
    return try buffer.toOwnedSlice();
}

fn parseEventValue(allocator: Allocator, value: json.Value) ParseError!Event {
    return switch (value) {
        .object => |*obj| parseEventFromObject(allocator, obj),
        else => ParseError.InvalidMessageFormat,
    };
}

fn parseEventFromObject(allocator: Allocator, obj: *const json.ObjectMap) ParseError!Event {
    const id_slice = try expectString(obj, "id");
    const pubkey_slice = try expectString(obj, "pubkey");
    const content_slice = try expectString(obj, "content");
    const sig_slice = try expectString(obj, "sig");

    const created_at_val = try expectNumber(obj, "created_at");
    const kind_val = try expectNumber(obj, "kind");

    const id_owned = try allocator.dupe(u8, id_slice);
    errdefer allocator.free(id_owned);
    const pubkey_owned = try allocator.dupe(u8, pubkey_slice);
    errdefer allocator.free(pubkey_owned);
    const content_owned = try allocator.dupe(u8, content_slice);
    errdefer allocator.free(content_owned);
    const sig_owned = try allocator.dupe(u8, sig_slice);
    errdefer allocator.free(sig_owned);

    const tags_owned = try parseTags(allocator, obj);
    errdefer {
        for (tags_owned) |*tag| tag.deinit(allocator);
        allocator.free(tags_owned);
    }

    return Event{
        .id = id_owned,
        .pubkey = pubkey_owned,
        .created_at = created_at_val,
        .kind = @as(u32, @intCast(kind_val)),
        .tags = tags_owned,
        .content = content_owned,
        .sig = sig_owned,
    };
}

fn expectString(obj: *const json.ObjectMap, key: []const u8) ParseError![]const u8 {
    const value = obj.*.get(key) orelse return ParseError.MissingField;
    return switch (value) {
        .string => |s| s,
        else => ParseError.InvalidFieldType,
    };
}

fn expectNumber(obj: *const json.ObjectMap, key: []const u8) ParseError!i64 {
    const value = obj.*.get(key) orelse return ParseError.MissingField;
    return switch (value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch return ParseError.InvalidFieldType,
        else => ParseError.InvalidFieldType,
    };
}

fn parseTags(allocator: Allocator, obj: *const json.ObjectMap) ParseError![]Tag {
    const value = obj.*.get("tags") orelse return allocator.alloc(Tag, 0);
    const array_value = switch (value) {
        .array => |arr| arr,
        else => return ParseError.InvalidFieldType,
    };

    const tags_slice = try allocator.alloc(Tag, array_value.items.len);
    var tag_index: usize = 0;
    errdefer {
        for (tags_slice[0..tag_index]) |*tag| tag.deinit(allocator);
        allocator.free(tags_slice);
    }

    for (array_value.items) |tag_value| {
        const tag_array = switch (tag_value) {
            .array => |arr| arr,
            else => return ParseError.InvalidFieldType,
        };
        const values = try allocator.alloc([]const u8, tag_array.items.len);
        var inner_index: usize = 0;
        errdefer {
            for (values[0..inner_index]) |slice| allocator.free(slice);
            allocator.free(values);
        }

        for (tag_array.items) |inner| {
            const str_slice = switch (inner) {
                .string => |s| s,
                else => return ParseError.InvalidFieldType,
            };
            values[inner_index] = try allocator.dupe(u8, str_slice);
            inner_index += 1;
        }

        tags_slice[tag_index] = Tag{ .values = values };
        tag_index += 1;
    }

    return tags_slice;
}

fn writeEventObject(writer: *json.Stringify, event: *const Event) !void {
    try writer.beginObject();
    try writer.objectField("id");
    try writer.write(event.id);
    try writer.objectField("pubkey");
    try writer.write(event.pubkey);
    try writer.objectField("created_at");
    try writer.write(event.created_at);
    try writer.objectField("kind");
    try writer.write(event.kind);
    try writer.objectField("tags");
    try writer.beginArray();
    for (event.tags) |tag| {
        try writer.beginArray();
        for (tag.values) |value| {
            try writer.write(value);
        }
        try writer.endArray();
    }
    try writer.endArray();
    try writer.objectField("content");
    try writer.write(event.content);
    try writer.objectField("sig");
    try writer.write(event.sig);
    try writer.endObject();
}
