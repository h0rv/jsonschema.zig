const std = @import("std");
const jsonschema = @import("jsonschema");

const Example = struct {
    name: []const u8,
    age: u8 = 18,

    pub const jsonschema = .{
        .title = "Example",
        .fields = .{
            .name = .{ .minLength = 1 },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    try jsonschema.write(Example, &stdout.interface, .{});
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}
