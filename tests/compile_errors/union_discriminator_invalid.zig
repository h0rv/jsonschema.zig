const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = union(enum) {
    value: u8,

    pub const jsonschema = .{ .discriminator = "" };
};

test "union discriminator invalid" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
