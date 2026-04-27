const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    value: std.StringHashMap([]const u8),

    pub const jsonschema = .{
        .patternProperties = 123,
    };
};

test "patternProperties wrong type" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
