const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    score: f64 = std.math.nan(f64),
};

test "nonfinite default" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
