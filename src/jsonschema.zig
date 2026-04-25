const std = @import("std");
const options = @import("options.zig");
const emit = @import("emit.zig");
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");

pub const Dialect = options.Dialect;
pub const Options = options.Options;
pub const Whitespace = options.Whitespace;

pub fn write(comptime T: type, writer: anytype, opts: Options) !void {
    switch (opts.dialect) {
        .draft202012 => {},
    }

    comptime reflect.validateType(T);
    comptime meta.validateTypeMetadata(T);

    switch (opts.whitespace) {
        .minified => try emit.topSchema(T, writer, opts),
        .indent_2 => {
            var pretty = PrettyWriter(@TypeOf(writer)).init(writer);
            var emit_opts = opts;
            emit_opts.whitespace = .minified;
            try emit.topSchema(T, &pretty, emit_opts);
        },
    }
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

fn PrettyWriter(comptime Inner: type) type {
    return struct {
        inner: Inner,
        depth: usize = 0,
        in_string: bool = false,
        escaped: bool = false,
        pending_indent: bool = false,

        const Self = @This();

        fn init(inner: Inner) Self {
            return .{ .inner = inner };
        }

        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            for (bytes) |byte| try self.writeByte(byte);
        }

        pub fn writeByte(self: *Self, byte: u8) !void {
            if (self.in_string) {
                try self.inner.writeByte(byte);
                if (self.escaped) {
                    self.escaped = false;
                } else if (byte == '\\') {
                    self.escaped = true;
                } else if (byte == '"') {
                    self.in_string = false;
                }
                return;
            }

            switch (byte) {
                '{', '[' => {
                    try self.flushPendingIndent(byte);
                    try self.inner.writeByte(byte);
                    self.depth += 1;
                    self.pending_indent = true;
                },
                '}', ']' => {
                    if (self.pending_indent) {
                        self.pending_indent = false;
                        self.depth -= 1;
                    } else {
                        self.depth -= 1;
                        try self.newlineIndent();
                    }
                    try self.inner.writeByte(byte);
                },
                ',' => {
                    try self.inner.writeByte(byte);
                    self.pending_indent = true;
                },
                ':' => try self.inner.writeAll(": "),
                '"' => {
                    try self.flushPendingIndent(byte);
                    self.in_string = true;
                    try self.inner.writeByte(byte);
                },
                else => {
                    try self.flushPendingIndent(byte);
                    try self.inner.writeByte(byte);
                },
            }
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            var buf: [128]u8 = undefined;
            const bytes = try std.fmt.bufPrint(&buf, fmt, args);
            try self.writeAll(bytes);
        }

        fn flushPendingIndent(self: *Self, next: u8) !void {
            if (!self.pending_indent) return;
            self.pending_indent = false;
            if (next == '}' or next == ']') return;
            try self.newlineIndent();
        }

        fn newlineIndent(self: *Self) !void {
            try self.inner.writeByte('\n');
            try self.inner.splatByteAll(' ', self.depth * 2);
        }
    };
}
