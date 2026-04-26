const std = @import("std");
const jsonschema = @import("jsonschema");

const Address = struct { city: []const u8 };
const User = struct { address: Address };

test "external nested top-level struct inline" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try jsonschema.write(User, &out.writer, .{});
}

test "external nested top-level struct defs" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try jsonschema.write(User, &out.writer, .{ .use_defs = .always });
}
