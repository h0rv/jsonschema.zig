const std = @import("std");
const jsonschema = @import("jsonschema");

const Node = struct {
    name: []const u8,
    children: []const @This(),
};

test "recursive without defs" {
    const schema = try jsonschema.stringifyAlloc(Node, std.testing.allocator, .{ .use_defs = .never });
    defer std.testing.allocator.free(schema);
}
