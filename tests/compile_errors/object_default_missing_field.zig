const std = @import("std");
const jsonschema = @import("jsonschema");

const Address = struct {
    city: []const u8,
    zip: u32,
};

const Bad = struct {
    address: Address,

    pub const jsonschema = .{
        .fields = .{
            .address = .{ .default = .{ .city = "Philadelphia" } },
        },
    };
};

test "object default missing field" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
