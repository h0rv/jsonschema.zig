const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    age: u8,

    pub const jsonschema = .{
        .fields = .{
            .age = .{ .multipleOf = 0 },
        },
    };
};

test "multipleOf nonpositive" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
