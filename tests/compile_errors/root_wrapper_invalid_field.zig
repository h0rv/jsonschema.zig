const std = @import("std");
const jsonschema = @import("jsonschema");

const Item = struct { name: []const u8 };

test "root wrapper invalid field" {
    const schema = try jsonschema.stringifyAlloc([]const Item, std.testing.allocator, .{
        .root_wrapper = .{ .object = .{ .field_name = "" } },
    });
    defer std.testing.allocator.free(schema);
}
