const std = @import("std");
const Options = @import("options.zig").Options;
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");

const draft202012_uri = "https://json-schema.org/draft/2020-12/schema";

const Object = struct {
    first: bool = true,

    fn field(self: *Object, writer: anytype, name: []const u8) !void {
        if (self.first) {
            self.first = false;
        } else {
            try writer.writeAll(",");
        }
        try writeString(writer, name);
        try writer.writeAll(":");
    }
};

pub fn topSchema(comptime T: type, writer: anytype, options: Options) !void {
    try writer.writeAll("{");
    var obj: Object = .{};

    if (options.include_schema_uri) {
        try obj.field(writer, "$schema");
        try writeString(writer, draft202012_uri);
    }

    try emitTypeMetadata(T, writer, &obj, options);

    try inferredSchema(T, writer, options, &obj);

    if (options.use_defs) {
        try emitDefs(T, writer, options, &obj);
    }

    try writer.writeAll("}");
}

fn schema(comptime T: type, writer: anytype, options: Options, comptime field_meta: anytype) anyerror!void {
    try writer.writeAll("{");
    var obj: Object = .{};

    try emitTypeMetadata(T, writer, &obj, options);
    try inferredSchema(T, writer, options, &obj);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_annotation_keys, options);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_constraint_keys, options);
    try emitMetadataDefault(writer, &obj, field_meta, options);

    try writer.writeAll("}");
}

fn schemaWithZigDefault(
    comptime T: type,
    writer: anytype,
    options: Options,
    comptime field_meta: anytype,
    comptime default_value: T,
) anyerror!void {
    try writer.writeAll("{");
    var obj: Object = .{};

    try emitTypeMetadata(T, writer, &obj, options);
    try inferredSchema(T, writer, options, &obj);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_annotation_keys, options);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_constraint_keys, options);
    try emitMetadataDefault(writer, &obj, field_meta, options);

    if (options.emit_defaults and !@hasField(@TypeOf(field_meta), "default")) {
        try obj.field(writer, "default");
        try writeJsonValue(T, writer, default_value);
    }

    try writer.writeAll("}");
}

fn inferredSchema(comptime T: type, writer: anytype, options: Options, obj: *Object) anyerror!void {
    switch (@typeInfo(T)) {
        .bool => {
            try obj.field(writer, "type");
            try writeString(writer, "boolean");
        },
        .int, .comptime_int => {
            try obj.field(writer, "type");
            try writeString(writer, "integer");
        },
        .float, .comptime_float => {
            try obj.field(writer, "type");
            try writeString(writer, "number");
        },
        .pointer => |ptr| {
            if (comptime reflect.isString(T)) {
                try obj.field(writer, "type");
                try writeString(writer, "string");
            } else if (ptr.size == .slice) {
                try obj.field(writer, "type");
                try writeString(writer, "array");
                try obj.field(writer, "items");
                if (options.use_defs and comptime isDefStruct(ptr.child)) {
                    try refSchema(ptr.child, writer);
                } else {
                    try schema(ptr.child, writer, options, .{});
                }
            } else {
                reflect.unsupported(T);
            }
        },
        .array => |arr| {
            try obj.field(writer, "type");
            try writeString(writer, "array");
            try obj.field(writer, "items");
            if (options.use_defs and comptime isDefStruct(arr.child)) {
                try refSchema(arr.child, writer);
            } else {
                try schema(arr.child, writer, options, .{});
            }
        },
        .optional => |opt| {
            try obj.field(writer, "anyOf");
            try writer.writeAll("[");
            if (options.use_defs and comptime isDefStruct(opt.child)) {
                try refSchema(opt.child, writer);
            } else {
                try schema(opt.child, writer, options, .{});
            }
            try writer.writeAll(",{");
            var null_obj: Object = .{};
            try null_obj.field(writer, "type");
            try writeString(writer, "null");
            try writer.writeAll("}]");
        },
        .@"enum" => |enm| {
            try obj.field(writer, "type");
            try writeString(writer, "string");
            try obj.field(writer, "enum");
            try writer.writeAll("[");
            inline for (enm.fields, 0..) |field, i| {
                if (i != 0) try writer.writeAll(",");
                try writeString(writer, field.name);
            }
            try writer.writeAll("]");
        },
        .@"struct" => |st| {
            if (st.is_tuple) reflect.unsupported(T);

            try obj.field(writer, "type");
            try writeString(writer, "object");

            if (options.require_all_fields) {
                try obj.field(writer, "required");
                try writer.writeAll("[");
                inline for (st.fields, 0..) |field, i| {
                    if (i != 0) try writer.writeAll(",");
                    try writeString(writer, field.name);
                }
                try writer.writeAll("]");
            }

            try obj.field(writer, "properties");
            try writer.writeAll("{");
            var props: Object = .{};
            inline for (st.fields) |field| {
                try props.field(writer, field.name);
                try fieldSchema(T, field, writer, options);
            }
            try writer.writeAll("}");

            try obj.field(writer, "additionalProperties");
            try writeJsonValue(bool, writer, options.additional_properties);
        },
        else => reflect.unsupported(T),
    }
}

fn fieldSchema(comptime Parent: type, comptime field: std.builtin.Type.StructField, writer: anytype, options: Options) anyerror!void {
    if (comptime meta.hasFieldMetadata(Parent, field.name)) {
        const field_meta = meta.fieldMetadata(Parent, field.name);
        if (options.use_defs and comptime isDefStruct(field.type)) {
            if (field.defaultValue()) |default_value| {
                try refSchemaWithZigDefault(field.type, writer, options, field_meta, default_value);
            } else {
                try refSchemaWithMeta(field.type, writer, options, field_meta);
            }
        } else if (field.defaultValue()) |default_value| {
            try schemaWithZigDefault(field.type, writer, options, field_meta, default_value);
        } else {
            try schema(field.type, writer, options, field_meta);
        }
    } else if (options.use_defs and comptime isDefStruct(field.type)) {
        if (field.defaultValue()) |default_value| {
            try refSchemaWithZigDefault(field.type, writer, options, .{}, default_value);
        } else {
            try refSchema(field.type, writer);
        }
    } else if (field.defaultValue()) |default_value| {
        try schemaWithZigDefault(field.type, writer, options, .{}, default_value);
    } else {
        try schema(field.type, writer, options, .{});
    }
}

fn emitDefs(comptime T: type, writer: anytype, options: Options, obj: *Object) !void {
    const defs = comptime collectDefs(T);
    comptime validateDefNamesUnique(defs);
    if (defs.len == 0) return;

    try obj.field(writer, "$defs");
    try writer.writeAll("{");
    var defs_obj: Object = .{};

    inline for (defs) |Def| {
        try defs_obj.field(writer, defName(Def));
        var def_options = options;
        def_options.use_defs = true;
        try schema(Def, writer, def_options, .{});
    }

    try writer.writeAll("}");
}

fn refSchema(comptime T: type, writer: anytype) !void {
    try writer.writeAll("{");
    var obj: Object = .{};
    try emitRefField(T, writer, &obj);
    try writer.writeAll("}");
}

fn refSchemaWithMeta(comptime T: type, writer: anytype, options: Options, comptime field_meta: anytype) !void {
    try writer.writeAll("{");
    var obj: Object = .{};
    try emitRefField(T, writer, &obj);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_annotation_keys, options);
    try emitMetadataDefault(writer, &obj, field_meta, options);
    try writer.writeAll("}");
}

fn refSchemaWithZigDefault(
    comptime T: type,
    writer: anytype,
    options: Options,
    comptime field_meta: anytype,
    comptime default_value: T,
) !void {
    try writer.writeAll("{");
    var obj: Object = .{};
    try emitRefField(T, writer, &obj);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_annotation_keys, options);
    try emitMetadataDefault(writer, &obj, field_meta, options);

    if (options.emit_defaults and !@hasField(@TypeOf(field_meta), "default")) {
        try obj.field(writer, "default");
        try writeJsonValue(T, writer, default_value);
    }

    try writer.writeAll("}");
}

fn emitRefField(comptime T: type, writer: anytype, obj: *Object) !void {
    try obj.field(writer, "$ref");
    try writer.writeAll("\"#/$defs/");
    try writer.writeAll(defName(T));
    try writer.writeAll("\"");
}

fn defType(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => if (isDefStruct(T)) T else null,
        .optional => |opt| defType(opt.child),
        .array => |arr| defType(arr.child),
        .pointer => |ptr| switch (ptr.size) {
            .slice => defType(ptr.child),
            else => null,
        },
        else => null,
    };
}

fn isDefStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| !st.is_tuple,
        else => false,
    };
}

fn collectDefs(comptime T: type) []const type {
    return collectDefsInSchema(T, &[_]type{}, &[_]type{});
}

fn collectDefsInSchema(comptime T: type, comptime defs: []const type, comptime stack: []const type) []const type {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| blk: {
            if (st.is_tuple or containsType(stack, T)) break :blk defs;
            const next_stack = stack ++ [_]type{T};
            var out = defs;
            inline for (st.fields) |field| out = collectDefsFromField(field.type, out, next_stack);
            break :blk out;
        },
        else => defs,
    };
}

fn collectDefsFromField(comptime T: type, comptime defs: []const type, comptime stack: []const type) []const type {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| blk: {
            if (st.is_tuple) break :blk defs;
            var out = defs;
            if (!containsType(out, T)) out = out ++ [_]type{T};
            out = collectDefsInSchema(T, out, stack);
            break :blk out;
        },
        .optional => |opt| collectDefsFromField(opt.child, defs, stack),
        .array => |arr| collectDefsFromField(arr.child, defs, stack),
        .pointer => |ptr| switch (ptr.size) {
            .slice => collectDefsFromField(ptr.child, defs, stack),
            else => defs,
        },
        else => defs,
    };
}

fn validateDefNamesUnique(comptime defs: []const type) void {
    inline for (defs, 0..) |Def, i| {
        inline for (defs[0..i]) |Prior| {
            if (Prior != Def and std.mem.eql(u8, defName(Prior), defName(Def))) {
                @compileError("jsonschema $defs name collision: '" ++ defName(Def) ++ "'");
            }
        }
    }
}

fn containsType(comptime haystack: []const type, comptime needle: type) bool {
    inline for (haystack) |item| {
        if (item == needle) return true;
    }
    return false;
}

fn defName(comptime T: type) []const u8 {
    const full = @typeName(T);
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |index| {
        return full[index + 1 ..];
    }
    return full;
}

fn emitTypeMetadata(comptime T: type, writer: anytype, obj: *Object, options: Options) !void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {
            if (@hasDecl(T, "jsonschema")) {
                try emitKnownMetadata(writer, obj, T.jsonschema, &meta.type_meta_keys, options);
            }
        },
        else => {},
    }
}

fn emitKnownMetadata(writer: anytype, obj: *Object, comptime metadata: anytype, comptime keys: []const []const u8, options: Options) !void {
    inline for (keys) |key| {
        if (@hasField(@TypeOf(metadata), key)) {
            _ = options;
            try obj.field(writer, key);
            try writeJsonValue(@TypeOf(@field(metadata, key)), writer, @field(metadata, key));
        }
    }
}

fn emitMetadataDefault(writer: anytype, obj: *Object, comptime metadata: anytype, options: Options) !void {
    if (options.emit_defaults and @hasField(@TypeOf(metadata), "default")) {
        try obj.field(writer, "default");
        try writeJsonValue(@TypeOf(metadata.default), writer, metadata.default);
    }
}

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
                    try obj.field(writer, field.name);
                    try writeJsonValue(field.type, writer, @field(value, field.name));
                }
                try writer.writeAll("}");
            }
        },
        else => reflect.unsupportedJsonValue(T),
    }
}
