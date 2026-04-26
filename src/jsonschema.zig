//! JSON Schema emitter for Zig types.

const std = @import("std");
const options = @import("options.zig");
const emit = @import("emit.zig");
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");
const validate = @import("validate.zig");

/// `$defs` emission policy.
pub const DefMode = options.DefMode;
/// JSON Schema dialect to emit.
pub const Dialect = options.Dialect;
/// Controls schema emission.
pub const Options = options.Options;
/// Object wrapper for schemas that must have an object root.
pub const ObjectRootWrapper = options.ObjectRootWrapper;
/// Field name transform applied before per-field `.name` overrides.
pub const FieldNaming = options.FieldNaming;
/// Root schema wrapper policy.
pub const RootWrapper = options.RootWrapper;
/// Output formatting.
pub const Whitespace = options.Whitespace;
/// Provider-neutral strict schema preset.
pub const strict_options = options.strict_options;

/// Provider-neutral schema descriptor.
pub const ToolSchema = struct {
    /// Schema/tool name.
    name: []const u8,
    /// Schema/tool description, if declared on `T`.
    description: ?[]const u8,
    /// JSON Schema document. Free with `deinit`.
    schema_json: []u8,

    /// Free owned schema JSON.
    pub fn deinit(self: *ToolSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.schema_json);
        self.* = .{ .name = "", .description = null, .schema_json = &.{} };
    }
};

/// Write the JSON Schema for `T` to `writer`.
///
/// `opts` is comptime because it changes schema shape.
/// `writer` must provide `writeAll`, `writeByte`, and `print`.
pub fn write(comptime T: type, writer: anytype, comptime opts: Options) !void {
    switch (opts.dialect) {
        .draft202012 => {},
    }

    comptime reflect.validateType(T);
    comptime meta.validateTypeMetadata(T);

    switch (opts.whitespace) {
        .minified => try emit.topSchema(T, writer, opts),
        .indent_2 => {
            var pretty = PrettyWriter(@TypeOf(writer)).init(writer);
            const emit_opts = comptime blk: {
                var next = opts;
                next.whitespace = .minified;
                break :blk next;
            };
            try emit.topSchema(T, &pretty, emit_opts);
        },
    }
}

/// Allocate and return the JSON Schema for `T`.
///
/// Caller owns the returned slice and must free it with `allocator`.
pub fn stringifyAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    comptime opts: Options,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try write(T, &out.writer, opts);
    return out.toOwnedSlice();
}

/// Allocate a provider-neutral schema descriptor for `T`.
///
/// Caller owns `schema_json` and must call `ToolSchema.deinit`.
pub fn toolSchemaAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    comptime opts: Options,
) !ToolSchema {
    return .{
        .name = comptime schemaName(T, opts),
        .description = comptime schemaDescription(T),
        .schema_json = try stringifyAlloc(T, allocator, opts),
    };
}

/// Validate a parsed Zig value against supported jsonschema metadata.
///
/// Returns `true` when valid. On failure, writes one error per line to `writer`.
pub fn validateValue(
    comptime T: type,
    value: T,
    writer: anytype,
    comptime opts: Options,
) !bool {
    return validate.value(T, value, writer, opts);
}

/// Return the schema name for `T`.
///
/// Precedence: `opts.name`, then `T.jsonschema.name`, then Zig type name.
/// Names must be non-empty, at most 64 bytes, and match `[A-Za-z0-9_-]`.
pub fn schemaName(comptime T: type, comptime opts: Options) []const u8 {
    if (comptime opts.name != null) return validateSchemaName(opts.name.?);
    if (comptime @hasDecl(T, "jsonschema") and @hasField(@TypeOf(T.jsonschema), "name")) {
        return validateSchemaName(stringValue(T.jsonschema.name));
    }
    return validateSchemaName(fallbackName(T));
}

/// Return `T.jsonschema.description`, if present.
pub fn schemaDescription(comptime T: type) ?[]const u8 {
    if (@hasDecl(T, "jsonschema") and @hasField(@TypeOf(T.jsonschema), "description")) {
        return T.jsonschema.description;
    }
    return null;
}

fn stringValue(comptime value: anytype) []const u8 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => value,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| value[0..arr.len],
                else => @compileError("jsonschema name must be a string"),
            },
            else => @compileError("jsonschema name must be a string"),
        },
        else => @compileError("jsonschema name must be a string"),
    };
}

fn validateSchemaName(comptime name: []const u8) []const u8 {
    if (name.len == 0) @compileError("jsonschema schema name must not be empty");
    if (name.len > 64) @compileError("jsonschema schema name must be at most 64 characters");
    inline for (name) |byte| {
        const ok = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '-';
        if (!ok) @compileError("jsonschema schema name must match [A-Za-z0-9_-]");
    }
    return name;
}

fn fallbackName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const last_dot = comptime lastDot(full) orelse return full;
    return full[last_dot + 1 ..];
}

fn lastDot(comptime value: []const u8) ?usize {
    var result: ?usize = null;
    for (value, 0..) |byte, i| {
        if (byte == '.') result = i;
    }
    return result;
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
            try self.inner.print(fmt, args);
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
