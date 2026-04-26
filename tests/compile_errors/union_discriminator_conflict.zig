const std = @import("std");
const jsonschema = @import("jsonschema");

const Search = struct {
    type: []const u8,
    query: []const u8,
};

const Bad = union(enum) {
    search: Search,

    pub const jsonschema = .{ .discriminator = "type" };
};

test "union discriminator conflict" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
