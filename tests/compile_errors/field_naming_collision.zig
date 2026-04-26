const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    first_name: []const u8,
    firstName: []const u8,
};

test "field naming collision" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{ .field_naming = .camelCase });
    defer std.testing.allocator.free(schema);
}
