const std = @import("std");
const options = @import("options.zig");
const emit = @import("emit.zig");
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");

pub const Dialect = options.Dialect;
pub const Options = options.Options;

pub fn write(comptime T: type, writer: anytype, opts: Options) !void {
    switch (opts.dialect) {
        .draft202012 => {},
    }

    comptime reflect.validateType(T);
    comptime meta.validateTypeMetadata(T);

    try emit.topSchema(T, writer, opts);
}

pub fn stringifyAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    opts: Options,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try write(T, &out.writer, opts);
    return out.toOwnedSlice();
}
