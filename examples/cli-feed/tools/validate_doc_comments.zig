const std = @import("std");

/// Validation error reported when a declaration is missing a doc comment.
const ValidationError = error{DocCommentMissing};

/// Record describing a missing documentation comment and its location.
const MissingDoc = struct {
    path: []const u8,
    line: usize,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var missing = std.ArrayListUnmanaged(MissingDoc){};
    defer missing.deinit(allocator);

    try checkDir(allocator, "src", &missing);

    if (missing.items.len > 0) {
        for (missing.items) |item| {
            std.debug.print("missing doc comment before struct or union: {s}:{d}\n", .{ item.path, item.line });
        }
        return ValidationError.DocCommentMissing;
    }
}

fn checkDir(allocator: std.mem.Allocator, path: []const u8, missing: *std.ArrayList(MissingDoc)) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const file_path = try std.fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(file_path);
            try checkFile(allocator, file_path, missing);
        } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..")) {
            const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(child_path);
            try checkDir(allocator, child_path, missing);
        }
    }
}

fn checkFile(allocator: std.mem.Allocator, path: []const u8, missing: *std.ArrayList(MissingDoc)) !void {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    var previous_nonblank: []const u8 = "";
    var previous_indentless = false;
    var line_number: usize = 0;

    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }

        const is_comment = std.mem.startsWith(u8, trimmed, "//");
        const has_indent = line.len != trimmed.len;
        if (is_comment) {
            if (!has_indent) {
                previous_nonblank = trimmed;
                previous_indentless = true;
            }
            continue;
        }

        if (!has_indent and requiresDocComment(trimmed)) {
            if (!(previous_indentless and std.mem.startsWith(u8, previous_nonblank, "///"))) {
                const stored_path = try allocator.dupe(u8, path);
                try missing.append(allocator, .{ .path = stored_path, .line = line_number });
            }
        }

        if (!has_indent) {
            previous_nonblank = trimmed;
            previous_indentless = true;
        } else if (!is_comment) {
            previous_indentless = false;
        }
    }
}

fn requiresDocComment(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "return struct") or std.mem.startsWith(u8, line, "return union")) {
        return false;
    }

    const contains_struct = std.mem.indexOf(u8, line, "struct") != null;
    const contains_union = std.mem.indexOf(u8, line, "union") != null;
    if (!contains_struct and !contains_union) return false;

    if (!(std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "pub const ") or
        std.mem.startsWith(u8, line, "extern struct") or
        std.mem.startsWith(u8, line, "extern union") or
        std.mem.startsWith(u8, line, "pub var ") or
        std.mem.startsWith(u8, line, "var ")))
    {
        return false;
    }

    return true;
}
