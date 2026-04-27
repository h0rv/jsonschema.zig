const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    credit_card: []const u8,
    billing_address: []const u8,

    pub const jsonschema = .{
        .dependentRequired = .{
            .credit_card = 123,
        },
    };
};

test "dependentRequired wrong type" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
