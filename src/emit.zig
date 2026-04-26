const std = @import("std");
const options_mod = @import("options.zig");
const Options = options_mod.Options;
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");

const draft202012_uri = "https://json-schema.org/draft/2020-12/schema";

fn effectiveOptions(comptime T: type, comptime options: Options) Options {
    var result = options;
    switch (options.use_defs) {
        .always, .never => {},
        .auto => result.use_defs = if (hasRecursiveSchema(T)) .always else .never,
    }
    if (result.use_defs == .never and hasRecursiveSchema(T)) {
        @compileError("recursive schemas require use_defs=.auto or .always");
    }
    return result;
}

fn defsEnabled(comptime options: Options) bool {
    return options.use_defs == .always;
}

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

pub fn topSchema(comptime T: type, writer: anytype, comptime options: Options) !void {
    const effective_options = comptime effectiveOptions(T, options);
    try writer.writeAll("{");
    var obj: Object = .{};

    if (effective_options.include_schema_uri) {
        try obj.field(writer, "$schema");
        try writeString(writer, draft202012_uri);
    }

    try emitTypeMetadata(T, writer, &obj, effective_options);

    switch (effective_options.root_wrapper) {
        .none => try inferredSchema(T, writer, effective_options, &obj),
        .object => |wrapper| try emitObjectRootWrapper(T, wrapper, writer, effective_options, &obj),
    }

    if (defsEnabled(effective_options)) {
        try emitDefs(T, writer, effective_options, &obj);
    }

    try writer.writeAll("}");
}

fn emitObjectRootWrapper(
    comptime T: type,
    comptime wrapper: options_mod.ObjectRootWrapper,
    writer: anytype,
    comptime options: Options,
    obj: *Object,
) !void {
    const field_name = comptime meta.validateJsonPropertyName(wrapper.field_name, "root wrapper field_name");

    try obj.field(writer, "type");
    try writeString(writer, "object");

    try obj.field(writer, "required");
    try writer.writeAll("[");
    try writeString(writer, field_name);
    try writer.writeAll("]");

    try obj.field(writer, "properties");
    try writer.writeAll("{");
    var props: Object = .{};
    try props.field(writer, field_name);
    try schema(T, writer, options, .{});
    try writer.writeAll("}");

    try obj.field(writer, "additionalProperties");
    try writeJsonValue(bool, writer, options.additional_properties);
}

fn schema(comptime T: type, writer: anytype, comptime options: Options, comptime field_meta: anytype) anyerror!void {
    try writer.writeAll("{");
    var obj: Object = .{};

    try emitTypeMetadata(T, writer, &obj, options);
    try inferredSchema(T, writer, options, &obj);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_annotation_keys, options);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_const_key, options);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_constraint_keys, options);
    try emitMetadataDefault(writer, &obj, field_meta, options);

    try writer.writeAll("}");
}

fn schemaWithZigDefault(
    comptime T: type,
    writer: anytype,
    comptime options: Options,
    comptime field_meta: anytype,
    comptime default_value: T,
) anyerror!void {
    try writer.writeAll("{");
    var obj: Object = .{};

    try emitTypeMetadata(T, writer, &obj, options);
    try inferredSchema(T, writer, options, &obj);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_annotation_keys, options);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_const_key, options);
    try emitKnownMetadata(writer, &obj, field_meta, &meta.field_constraint_keys, options);
    try emitMetadataDefault(writer, &obj, field_meta, options);

    if (options.emit_defaults and !@hasField(@TypeOf(field_meta), "default")) {
        try obj.field(writer, "default");
        try writeJsonValue(T, writer, default_value);
    }

    try writer.writeAll("}");
}

fn inferredSchema(comptime T: type, writer: anytype, comptime options: Options, obj: *Object) anyerror!void {
    switch (@typeInfo(T)) {
        .bool => {
            try obj.field(writer, "type");
            try writeString(writer, "boolean");
        },
        .int => {
            try obj.field(writer, "type");
            try writeString(writer, "integer");
            if (options.infer_integer_bounds) {
                try obj.field(writer, "minimum");
                try writeJsonValue(T, writer, std.math.minInt(T));
                try obj.field(writer, "maximum");
                try writeJsonValue(T, writer, std.math.maxInt(T));
            }
        },
        .comptime_int => {
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
            } else switch (ptr.size) {
                .slice => {
                    try obj.field(writer, "type");
                    try writeString(writer, "array");
                    try obj.field(writer, "items");
                    if (defsEnabled(options)) {
                        if (comptime directRefType(ptr.child)) |Def| {
                            try refSchema(Def, writer);
                        } else {
                            try schema(ptr.child, writer, options, .{});
                        }
                    } else {
                        try schema(ptr.child, writer, options, .{});
                    }
                },
                .one => switch (@typeInfo(ptr.child)) {
                    .@"struct" => {
                        if (defsEnabled(options)) {
                            try refSchema(ptr.child, writer);
                        } else {
                            try emitTypeMetadata(ptr.child, writer, obj, options);
                            try inferredSchema(ptr.child, writer, options, obj);
                        }
                    },
                    .@"union" => {
                        try emitTypeMetadata(ptr.child, writer, obj, options);
                        try inferredSchema(ptr.child, writer, options, obj);
                    },
                    else => reflect.unsupported(T),
                },
                else => reflect.unsupported(T),
            }
        },
        .array => |arr| {
            try obj.field(writer, "type");
            try writeString(writer, "array");
            try obj.field(writer, "items");
            if (defsEnabled(options)) {
                if (comptime directRefType(arr.child)) |Def| {
                    try refSchema(Def, writer);
                } else {
                    try schema(arr.child, writer, options, .{});
                }
            } else {
                try schema(arr.child, writer, options, .{});
            }
            if (options.infer_fixed_array_bounds) {
                try obj.field(writer, "minItems");
                try writeJsonValue(usize, writer, arr.len);
                try obj.field(writer, "maxItems");
                try writeJsonValue(usize, writer, arr.len);
            }
        },
        .optional => |opt| {
            try obj.field(writer, "anyOf");
            try writer.writeAll("[");
            if (defsEnabled(options)) {
                if (comptime directRefType(opt.child)) |Def| {
                    try refSchema(Def, writer);
                } else {
                    try schema(opt.child, writer, options, .{});
                }
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
        .@"union" => |un| try emitUnionSchema(T, un, writer, options, obj),
        .@"struct" => |st| {
            if (comptime reflect.isStringMap(T)) {
                try obj.field(writer, "type");
                try writeString(writer, "object");
                try obj.field(writer, "additionalProperties");
                const Value = reflect.mapValueType(T);
                if (defsEnabled(options)) {
                    if (comptime directRefType(Value)) |Def| {
                        try refSchema(Def, writer);
                    } else {
                        try schema(Value, writer, options, .{});
                    }
                } else {
                    try schema(Value, writer, options, .{});
                }
                return;
            }
            if (st.is_tuple) {
                try emitTupleSchema(st, writer, options, obj);
                return;
            }
            comptime meta.validateSchemaFieldNames(T, options.field_naming);

            try obj.field(writer, "type");
            try writeString(writer, "object");

            if (comptime hasRequiredProperties(T, options.require_all_fields)) {
                try obj.field(writer, "required");
                try writer.writeAll("[");
                var first_required = true;
                inline for (st.fields) |field| {
                    if (comptime !meta.fieldOmitted(T, field.name) and meta.fieldRequired(T, field.name, options.require_all_fields)) {
                        if (first_required) {
                            first_required = false;
                        } else {
                            try writer.writeAll(",");
                        }
                        try writeString(writer, comptime meta.schemaFieldName(T, field.name, options.field_naming));
                    }
                }
                try writer.writeAll("]");
            }

            try obj.field(writer, "properties");
            try writer.writeAll("{");
            var props: Object = .{};
            inline for (st.fields) |field| {
                if (comptime meta.fieldOmitted(T, field.name)) continue;
                try props.field(writer, comptime meta.schemaFieldName(T, field.name, options.field_naming));
                try fieldSchema(T, field, writer, options);
            }
            try writer.writeAll("}");

            try obj.field(writer, "additionalProperties");
            try writeJsonValue(bool, writer, options.additional_properties);
        },
        else => reflect.unsupported(T),
    }
}

fn emitTupleSchema(
    comptime st: std.builtin.Type.Struct,
    writer: anytype,
    comptime options: Options,
    obj: *Object,
) !void {
    try obj.field(writer, "type");
    try writeString(writer, "array");

    try obj.field(writer, "prefixItems");
    try writer.writeAll("[");
    inline for (st.fields, 0..) |field, i| {
        if (i != 0) try writer.writeAll(",");
        if (defsEnabled(options)) {
            if (comptime directRefType(field.type)) |Def| {
                try refSchema(Def, writer);
            } else {
                try schema(field.type, writer, options, .{});
            }
        } else {
            try schema(field.type, writer, options, .{});
        }
    }
    try writer.writeAll("]");

    try obj.field(writer, "minItems");
    try writeJsonValue(usize, writer, st.fields.len);
    try obj.field(writer, "maxItems");
    try writeJsonValue(usize, writer, st.fields.len);
}

fn emitUnionSchema(
    comptime T: type,
    comptime un: std.builtin.Type.Union,
    writer: anytype,
    comptime options: Options,
    obj: *Object,
) !void {
    if (un.tag_type == null) @compileError("jsonschema union schemas require union(enum)");

    try obj.field(writer, "type");
    try writeString(writer, "object");
    try obj.field(writer, "oneOf");
    try writer.writeAll("[");
    inline for (un.fields, 0..) |field, i| {
        if (i != 0) try writer.writeAll(",");
        if (comptime meta.hasUnionDiscriminator(T)) {
            try emitDiscriminatorUnionVariantObject(field.name, field.type, comptime meta.unionDiscriminator(T), writer, options);
        } else {
            try emitExternalUnionVariantObject(field.name, field.type, writer, options);
        }
    }
    try writer.writeAll("]");
}

fn emitExternalUnionVariantObject(
    comptime tag_name: []const u8,
    comptime Payload: type,
    writer: anytype,
    comptime options: Options,
) !void {
    try writer.writeAll("{");
    var obj: Object = .{};

    try obj.field(writer, "type");
    try writeString(writer, "object");

    try obj.field(writer, "required");
    try writer.writeAll("[");
    try writeString(writer, tag_name);
    try writer.writeAll("]");

    try obj.field(writer, "properties");
    try writer.writeAll("{");
    var props: Object = .{};
    try props.field(writer, tag_name);
    try unionPayloadSchema(Payload, writer, options);
    try writer.writeAll("}");

    try obj.field(writer, "additionalProperties");
    try writeJsonValue(bool, writer, options.additional_properties);

    try writer.writeAll("}");
}

fn unionPayloadSchema(comptime Payload: type, writer: anytype, comptime options: Options) !void {
    if (Payload == void) {
        try writer.writeAll("{");
        var obj: Object = .{};
        try obj.field(writer, "type");
        try writeString(writer, "object");
        try obj.field(writer, "additionalProperties");
        try writeJsonValue(bool, writer, false);
        try writer.writeAll("}");
    } else if (defsEnabled(options)) {
        if (comptime directRefType(Payload)) |Def| {
            try refSchema(Def, writer);
        } else {
            try schema(Payload, writer, options, .{});
        }
    } else {
        try schema(Payload, writer, options, .{});
    }
}

fn emitDiscriminatorUnionVariantObject(
    comptime tag_name: []const u8,
    comptime Payload: type,
    comptime discriminator: []const u8,
    writer: anytype,
    comptime options: Options,
) !void {
    comptime validateUnionVariant(Payload, discriminator);

    try writer.writeAll("{");
    var obj: Object = .{};

    try emitTypeMetadata(Payload, writer, &obj, options);

    try obj.field(writer, "type");
    try writeString(writer, "object");

    try obj.field(writer, "required");
    try writer.writeAll("[");
    try writeString(writer, discriminator);
    switch (@typeInfo(Payload)) {
        .void => {},
        .@"struct" => |st| if (!st.is_tuple) {
            inline for (st.fields) |field| {
                if (comptime meta.fieldOmitted(Payload, field.name)) continue;
                if (comptime !meta.fieldRequired(Payload, field.name, options.require_all_fields)) continue;
                try writer.writeAll(",");
                try writeString(writer, comptime meta.schemaFieldName(Payload, field.name, options.field_naming));
            }
        } else {
            try writer.writeAll(",");
            try writeString(writer, "value");
        },
        else => {
            try writer.writeAll(",");
            try writeString(writer, "value");
        },
    }
    try writer.writeAll("]");

    try obj.field(writer, "properties");
    try writer.writeAll("{");
    var props: Object = .{};
    try props.field(writer, discriminator);
    try emitDiscriminatorSchema(tag_name, writer);

    switch (@typeInfo(Payload)) {
        .void => {},
        .@"struct" => |st| if (!st.is_tuple) {
            inline for (st.fields) |field| {
                if (comptime meta.fieldOmitted(Payload, field.name)) continue;
                try props.field(writer, comptime meta.schemaFieldName(Payload, field.name, options.field_naming));
                try fieldSchema(Payload, field, writer, options);
            }
        } else {
            try props.field(writer, "value");
            try schema(Payload, writer, options, .{});
        },
        else => {
            try props.field(writer, "value");
            try schema(Payload, writer, options, .{});
        },
    }
    try writer.writeAll("}");

    try obj.field(writer, "additionalProperties");
    try writeJsonValue(bool, writer, options.additional_properties);

    try writer.writeAll("}");
}

fn emitDiscriminatorSchema(comptime tag_name: []const u8, writer: anytype) !void {
    try writer.writeAll("{");
    var obj: Object = .{};
    try obj.field(writer, "type");
    try writeString(writer, "string");
    try obj.field(writer, "const");
    try writeString(writer, tag_name);
    try writer.writeAll("}");
}

fn validateUnionVariant(comptime Payload: type, comptime discriminator: []const u8) void {
    switch (@typeInfo(Payload)) {
        .void => {},
        .@"struct" => |st| {
            if (st.is_tuple) {
                if (std.mem.eql(u8, discriminator, "value")) {
                    @compileError("jsonschema union discriminator conflicts with generated value field 'value'");
                }
                return;
            }
            meta.validateSchemaFieldNames(Payload, .identity);
            inline for (st.fields) |field| {
                if (comptime meta.fieldOmitted(Payload, field.name)) continue;
                const emitted = meta.schemaFieldName(Payload, field.name, .identity);
                if (std.mem.eql(u8, discriminator, emitted)) {
                    @compileError("jsonschema union discriminator conflicts with payload field '" ++ emitted ++ "'");
                }
            }
        },
        else => if (std.mem.eql(u8, discriminator, "value")) {
            @compileError("jsonschema union discriminator conflicts with generated value field 'value'");
        },
    }
}

fn hasRequiredProperties(comptime T: type, comptime require_all_fields: bool) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (meta.fieldOmitted(T, field.name)) continue;
        if (meta.fieldRequired(T, field.name, require_all_fields)) return true;
    }
    return false;
}

fn fieldSchema(comptime Parent: type, comptime field: std.builtin.Type.StructField, writer: anytype, comptime options: Options) anyerror!void {
    if (comptime meta.hasFieldMetadata(Parent, field.name)) {
        const field_meta = meta.fieldMetadata(Parent, field.name);
        if (defsEnabled(options)) {
            if (comptime directRefType(field.type)) |Def| {
                if (field.defaultValue()) |default_value| {
                    try refSchemaWithZigDefault(Def, writer, options, field_meta, default_value);
                } else {
                    try refSchemaWithMeta(Def, writer, options, field_meta);
                }
                return;
            }
        }

        if (field.defaultValue()) |default_value| {
            try schemaWithZigDefault(field.type, writer, options, field_meta, default_value);
        } else {
            try schema(field.type, writer, options, field_meta);
        }
    } else if (defsEnabled(options)) {
        if (comptime directRefType(field.type)) |Def| {
            if (field.defaultValue()) |default_value| {
                try refSchemaWithZigDefault(Def, writer, options, .{}, default_value);
            } else {
                try refSchema(Def, writer);
            }
            return;
        }

        if (field.defaultValue()) |default_value| {
            try schemaWithZigDefault(field.type, writer, options, .{}, default_value);
        } else {
            try schema(field.type, writer, options, .{});
        }
    } else if (field.defaultValue()) |default_value| {
        try schemaWithZigDefault(field.type, writer, options, .{}, default_value);
    } else {
        try schema(field.type, writer, options, .{});
    }
}

fn emitDefs(comptime T: type, writer: anytype, comptime options: Options, obj: *Object) !void {
    const defs = comptime collectDefs(T);
    comptime validateDefNamesUnique(defs);
    if (defs.len == 0) return;

    try obj.field(writer, "$defs");
    try writer.writeAll("{");
    var defs_obj: Object = .{};

    inline for (defs) |Def| {
        try defs_obj.field(writer, defName(Def));
        const def_options = comptime blk: {
            var opts = options;
            opts.use_defs = .always;
            break :blk opts;
        };
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

fn refSchemaWithMeta(comptime T: type, writer: anytype, comptime options: Options, comptime field_meta: anytype) !void {
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
    comptime options: Options,
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
    try writeJsonPointerSegmentContent(writer, defName(T));
    try writer.writeAll("\"");
}

fn defType(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => if (isDefStruct(T)) T else null,
        .optional => |opt| defType(opt.child),
        .array => |arr| defType(arr.child),
        .pointer => |ptr| switch (ptr.size) {
            .slice => defType(ptr.child),
            .one => directRefType(T),
            else => null,
        },
        else => null,
    };
}

fn directRefType(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => if (isDefStruct(T)) T else null,
        .pointer => |ptr| switch (ptr.size) {
            .one => switch (@typeInfo(ptr.child)) {
                .@"struct" => if (isDefStruct(ptr.child)) ptr.child else null,
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

fn isDefStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| !st.is_tuple and !reflect.isStringMap(T),
        else => false,
    };
}

fn collectDefs(comptime T: type) []const type {
    return collectDefsInSchema(T, &[_]type{}, &[_]type{});
}

fn hasRecursiveSchema(comptime T: type) bool {
    return hasRecursiveSchemaInner(T, &[_]type{});
}

fn hasRecursiveSchemaInner(comptime T: type, comptime stack: []const type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| blk: {
            if (st.is_tuple) break :blk false;
            if (containsType(stack, T)) break :blk true;
            const next_stack = stack ++ [_]type{T};
            inline for (st.fields) |field| {
                if (hasRecursiveSchemaInner(field.type, next_stack)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |un| blk: {
            if (containsType(stack, T)) break :blk true;
            const next_stack = stack ++ [_]type{T};
            inline for (un.fields) |field| {
                if (field.type != void and hasRecursiveSchemaInner(field.type, next_stack)) break :blk true;
            }
            break :blk false;
        },
        .optional => |opt| hasRecursiveSchemaInner(opt.child, stack),
        .array => |arr| hasRecursiveSchemaInner(arr.child, stack),
        .pointer => |ptr| switch (ptr.size) {
            .slice, .one => hasRecursiveSchemaInner(ptr.child, stack),
            else => false,
        },
        else => false,
    };
}

fn collectDefsInSchema(comptime T: type, comptime defs: []const type, comptime stack: []const type) []const type {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| blk: {
            if (containsType(stack, T)) break :blk defs;
            const next_stack = stack ++ [_]type{T};
            var out = defs;
            inline for (st.fields) |field| out = collectDefsFromField(field.type, out, next_stack);
            break :blk out;
        },
        .@"union" => |un| blk: {
            if (containsType(stack, T)) break :blk defs;
            const next_stack = stack ++ [_]type{T};
            var out = defs;
            inline for (un.fields) |field| {
                if (field.type != void) out = collectDefsFromField(field.type, out, next_stack);
            }
            break :blk out;
        },
        else => defs,
    };
}

fn collectDefsFromField(comptime T: type, comptime defs: []const type, comptime stack: []const type) []const type {
    return switch (@typeInfo(T)) {
        .@"struct" => |st| blk: {
            if (comptime reflect.isStringMap(T)) break :blk collectDefsFromField(reflect.mapValueType(T), defs, stack);
            var out = defs;
            if (!st.is_tuple and !containsType(out, T)) out = out ++ [_]type{T};
            out = collectDefsInSchema(T, out, stack);
            break :blk out;
        },
        .@"union" => collectDefsInSchema(T, defs, stack),
        .optional => |opt| collectDefsFromField(opt.child, defs, stack),
        .array => |arr| collectDefsFromField(arr.child, defs, stack),
        .pointer => |ptr| switch (ptr.size) {
            .slice => collectDefsFromField(ptr.child, defs, stack),
            .one => collectDefsFromField(ptr.child, defs, stack),
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
    const last_dot = comptime lastDot(full) orelse return full;
    const name = full[last_dot + 1 ..];
    const before_name = full[0..last_dot];
    const maybe_prev_dot = comptime lastDot(before_name);
    const prev_dot = maybe_prev_dot orelse return name;
    const parent = before_name[prev_dot + 1 ..];
    if (parent.len > 0 and parent[0] == '$') return name;
    return parent ++ "." ++ name;
}

fn lastDot(comptime value: []const u8) ?usize {
    var result: ?usize = null;
    for (value, 0..) |byte, i| {
        if (byte == '.') result = i;
    }
    return result;
}

fn writeJsonPointerSegmentContent(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '~' => try writer.writeAll("~0"),
            '/' => try writer.writeAll("~1"),
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
}

fn emitTypeMetadata(comptime T: type, writer: anytype, obj: *Object, comptime options: Options) !void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {
            if (@hasDecl(T, "jsonschema")) {
                try emitKnownMetadata(writer, obj, T.jsonschema, &meta.type_meta_keys, options);
            }
        },
        else => {},
    }
}

fn emitKnownMetadata(writer: anytype, obj: *Object, comptime metadata: anytype, comptime keys: []const []const u8, comptime options: Options) !void {
    inline for (keys) |key| {
        if (@hasField(@TypeOf(metadata), key)) {
            _ = options;
            try obj.field(writer, key);
            try writeJsonValue(@TypeOf(@field(metadata, key)), writer, @field(metadata, key));
        }
    }
}

fn emitMetadataDefault(writer: anytype, obj: *Object, comptime metadata: anytype, comptime options: Options) !void {
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
