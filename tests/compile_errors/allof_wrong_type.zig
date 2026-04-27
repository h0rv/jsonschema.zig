const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    value: u8,

    pub const jsonschema = .{
        .allOf = .{ .type = "object" },
    };
};

test "allOf wrong type" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
