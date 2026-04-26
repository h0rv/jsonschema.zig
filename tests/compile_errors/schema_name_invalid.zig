const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    pub const jsonschema = .{ .name = "bad name!" };
};

test "invalid schema name" {
    try std.testing.expect(jsonschema.schemaName(Bad, .{}).len > 0);
}
