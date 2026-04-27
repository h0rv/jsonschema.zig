const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    name: []const u8,

    pub const jsonschema = .{
        .fields = .{
            .name = .{ .contains = .{ .type = "string" } },
        },
    };
};

test "contains non-array" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
