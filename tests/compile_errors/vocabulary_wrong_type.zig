const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    name: []const u8,

    pub const jsonschema = .{
        .@"$vocabulary" = .{
            .@"https://json-schema.org/draft/2020-12/vocab/core" = "yes",
        },
    };
};

test "vocabulary wrong type" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
