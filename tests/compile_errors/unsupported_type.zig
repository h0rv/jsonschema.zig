const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    callback: fn () void,
};

test "unsupported field type" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
