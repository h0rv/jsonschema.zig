const std = @import("std");
const jsonschema = @import("jsonschema");

const A = struct {
    pub const Address = struct { city: []const u8 };
};

const B = struct {
    pub const Address = struct { zip: u32 };
};

const Bad = struct {
    home: A.Address,
    work: B.Address,
};

test "defs name collision" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{ .use_defs = true });
    defer std.testing.allocator.free(schema);
}
