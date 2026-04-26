const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = union {
    name: []const u8,
    age: u8,
};

test "untagged union" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
