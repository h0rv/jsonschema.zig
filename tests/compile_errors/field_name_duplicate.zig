const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    first_name: []const u8,
    firstName: []const u8,

    pub const jsonschema = .{
        .fields = .{
            .first_name = .{ .name = "firstName" },
        },
    };
};

test "duplicate emitted field name" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
