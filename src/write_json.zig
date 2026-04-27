const std = @import("std");
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");

pub const Object = struct {
    first: bool = true,

    pub fn field(self: *Object, writer: anytype, name: []const u8) !void {
        if (self.first) {
            self.first = false;
        } else {
            try writer.writeAll(",");
        }
        try writeString(writer, name);
        try writer.writeAll(":");
    }
};

pub fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u{x:0>4}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

fn writeExternalUnionValue(comptime un: std.builtin.Type.Union, writer: anytype, value: anytype) !void {
    try writer.writeAll("{");
    var obj: Object = .{};
    const tag_name = @tagName(value);
    inline for (un.fields) |field| {
        if (std.mem.eql(u8, field.name, tag_name)) {
            try obj.field(writer, field.name);
            if (field.type == void) {
                try writer.writeAll("{}");
            } else {
                try writeJsonValue(field.type, writer, @field(value, field.name));
            }
        }
    }
    try writer.writeAll("}");
}

fn writeDiscriminatorUnionValue(comptime T: type, comptime un: std.builtin.Type.Union, writer: anytype, value: T) !void {
    try writer.writeAll("{");
    var obj: Object = .{};
    const tag_name = @tagName(value);
    const discriminator = comptime meta.unionDiscriminator(T);
    try obj.field(writer, discriminator);
    try writeString(writer, tag_name);
    inline for (un.fields) |field| {
        if (std.mem.eql(u8, field.name, tag_name)) {
            if (field.type != void) {
                if (comptime unionPayloadIsStruct(field.type)) {
                    try writeUnionStructPayloadFields(field.type, writer, &obj, @field(value, field.name));
                } else {
                    try obj.field(writer, "value");
                    try writeJsonValue(field.type, writer, @field(value, field.name));
                }
            }
        }
    }
    try writer.writeAll("}");
}

fn unionPayloadIsStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| !st.is_tuple,
        else => false,
    };
}

fn writeUnionStructPayloadFields(comptime T: type, writer: anytype, obj: *Object, value: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime meta.fieldOmitted(T, field.name)) continue;
        try obj.field(writer, comptime meta.schemaFieldName(T, field.name, .identity));
        try writeJsonValue(field.type, writer, @field(value, field.name));
    }
}

pub fn writeJsonValue(comptime T: type, writer: anytype, value: T) anyerror!void {
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try writer.print("{}", .{value}),
        .float => {
            if (!std.math.isFinite(value)) return error.InvalidJsonNumber;
            try writer.print("{}", .{value});
        },
        .comptime_float => {
            if (!std.math.isFinite(@as(f128, value))) return error.InvalidJsonNumber;
            try writer.print("{}", .{value});
        },
        .null => try writer.writeAll("null"),
        .optional => |opt| {
            if (value) |child| {
                try writeJsonValue(opt.child, writer, child);
            } else {
                try writer.writeAll("null");
            }
        },
        .pointer => |ptr| {
            if (comptime reflect.isString(T)) {
                try writeString(writer, value);
            } else switch (ptr.size) {
                .slice => {
                    try writer.writeAll("[");
                    for (value, 0..) |item, i| {
                        if (i != 0) try writer.writeAll(",");
                        try writeJsonValue(ptr.child, writer, item);
                    }
                    try writer.writeAll("]");
                },
                .one => switch (@typeInfo(ptr.child)) {
                    .array => |arr| {
                        try writer.writeAll("[");
                        for (value.*, 0..) |item, i| {
                            if (i != 0) try writer.writeAll(",");
                            try writeJsonValue(arr.child, writer, item);
                        }
                        try writer.writeAll("]");
                    },
                    .@"struct", .@"union" => try writeJsonValue(ptr.child, writer, value.*),
                    else => reflect.unsupportedJsonValue(T),
                },
                else => reflect.unsupportedJsonValue(T),
            }
        },
        .array => |arr| {
            try writer.writeAll("[");
            for (value, 0..) |item, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonValue(arr.child, writer, item);
            }
            try writer.writeAll("]");
        },
        .@"enum" => try writeString(writer, @tagName(value)),
        .@"union" => |un| {
            if (un.tag_type == null) reflect.unsupportedJsonValue(T);
            if (comptime meta.hasUnionDiscriminator(T)) {
                try writeDiscriminatorUnionValue(T, un, writer, value);
            } else {
                try writeExternalUnionValue(un, writer, value);
            }
        },
        .@"struct" => |st| {
            if (st.is_tuple) {
                try writer.writeAll("[");
                inline for (st.fields, 0..) |field, i| {
                    if (i != 0) try writer.writeAll(",");
                    try writeJsonValue(field.type, writer, @field(value, field.name));
                }
                try writer.writeAll("]");
            } else {
                try writer.writeAll("{");
                var obj: Object = .{};
                inline for (st.fields) |field| {
                    if (comptime meta.fieldOmitted(T, field.name)) continue;
                    try obj.field(writer, comptime meta.schemaFieldName(T, field.name, .identity));
                    try writeJsonValue(field.type, writer, @field(value, field.name));
                }
                try writer.writeAll("}");
            }
        },
        else => reflect.unsupportedJsonValue(T),
    }
}

fn expectJsonValue(comptime T: type, value: T, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonValue(T, &out.writer, value);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "writeJsonValue uses native external union shape" {
    const Search = struct { query: []const u8 };
    const Event = union(enum) {
        search: Search,
        count: u8,
        wait: void,
    };

    try expectJsonValue(Event, .{ .search = .{ .query = "zig" } }, "{\"search\":{\"query\":\"zig\"}}");
    try expectJsonValue(Event, .{ .count = 2 }, "{\"count\":2}");
    try expectJsonValue(Event, .{ .wait = {} }, "{\"wait\":{}}");
}

test "writeJsonValue uses discriminator shape when requested" {
    const Search = struct {
        query_text: []const u8,

        pub const jsonschema = .{
            .fields = .{ .query_text = .{ .name = "query" } },
        };
    };
    const Event = union(enum) {
        search: Search,
        count: u8,

        pub const jsonschema = .{ .discriminator = "kind" };
    };

    try expectJsonValue(Event, .{ .search = .{ .query_text = "zig" } }, "{\"kind\":\"search\",\"query\":\"zig\"}");
    try expectJsonValue(Event, .{ .count = 2 }, "{\"kind\":\"count\",\"value\":2}");
}
