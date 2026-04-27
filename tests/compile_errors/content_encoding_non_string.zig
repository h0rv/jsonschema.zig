const std = @import("std");
const jsonschema = @import("jsonschema");

const Bad = struct {
    age: u8,

    pub const jsonschema = .{
        .fields = .{
            .age = .{ .contentEncoding = "base64" },
        },
    };
};

test "contentEncoding non-string" {
    const schema = try jsonschema.stringifyAlloc(Bad, std.testing.allocator, .{});
    defer std.testing.allocator.free(schema);
}
