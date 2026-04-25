const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    role: enum { admin, user },

    pub const jsonschema = .{
        .fields = .{
            .role = .{ .default = "owner" },
        },
    };
};

test "enum default unknown" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
