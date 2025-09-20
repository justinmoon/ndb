const std = @import("std");
const json = std.json;

/// Error set emitted when JSON fields are missing or the type is unexpected.
pub const FieldError = error{ MissingField, InvalidFieldType };

/// Returns the string stored at `key` or reports why it could not be read.
pub fn expectString(obj: *const json.ObjectMap, key: []const u8) FieldError![]const u8 {
    const value = obj.*.get(key) orelse return FieldError.MissingField;
    return switch (value) {
        .string => |s| s,
        else => FieldError.InvalidFieldType,
    };
}

/// Returns an integer value for `key`, accepting integer or numeric string forms.
pub fn expectInteger(obj: *const json.ObjectMap, key: []const u8) FieldError!i64 {
    const value = obj.*.get(key) orelse return FieldError.MissingField;
    return switch (value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch FieldError.InvalidFieldType,
        else => FieldError.InvalidFieldType,
    };
}
