const std = @import("std");
const FieldNaming = @import("options.zig").FieldNaming;
const reflect = @import("reflect.zig");
const vocab = @import("vocab.zig");

pub const type_meta_keys = vocab.annotation_keys;
const type_meta_keys_with_fields = vocab.annotation_keys ++ vocab.emitter_type_keys;
pub const field_annotation_keys = vocab.annotation_keys;
pub const field_default_key = vocab.default_key;
pub const field_const_key = vocab.const_key;
pub const field_shape_keys = [_][]const u8{ "required", "omit" };
pub const field_constraint_keys = vocab.validation_keys;

pub fn validateTypeMetadata(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return,
    }
    if (!@hasDecl(T, "jsonschema")) return;

    const schema_meta = T.jsonschema;
    ensureStruct(@TypeOf(schema_meta), "type metadata");
    validateKnownKeys(@TypeOf(schema_meta), &type_meta_keys_with_fields, "type metadata");
    validateMetadataValueTypes(schema_meta, &type_meta_keys, "type metadata");
    validateMetadataValueTypes(schema_meta, &[_][]const u8{ "name", "discriminator" }, "type metadata");
    validateExamplesCompatibility(T, schema_meta, "type metadata");

    if (@hasField(@TypeOf(schema_meta), "fields")) {
        ensureStruct(@TypeOf(schema_meta.fields), "fields metadata");
        validateFieldsMetadata(T, schema_meta.fields);
    }
}

pub fn hasFieldMetadata(comptime Parent: type, comptime field_name: []const u8) bool {
    return @hasDecl(Parent, "jsonschema") and
        @hasField(@TypeOf(Parent.jsonschema), "fields") and
        @hasField(@TypeOf(Parent.jsonschema.fields), field_name);
}

pub fn fieldMetadata(comptime Parent: type, comptime field_name: []const u8) @TypeOf(@field(Parent.jsonschema.fields, field_name)) {
    return @field(Parent.jsonschema.fields, field_name);
}

pub fn schemaFieldName(comptime Parent: type, comptime field_name: []const u8, comptime naming: FieldNaming) []const u8 {
    if (comptime hasFieldMetadata(Parent, field_name)) {
        const field_meta = fieldMetadata(Parent, field_name);
        if (comptime @hasField(@TypeOf(field_meta), "name")) {
            return validateSchemaFieldName(stringValue(field_meta.name));
        }
    }
    return validateSchemaFieldName(applyFieldNaming(field_name, naming));
}

pub fn hasUnionDiscriminator(comptime T: type) bool {
    return @hasDecl(T, "jsonschema") and @hasField(@TypeOf(T.jsonschema), "discriminator");
}

pub fn unionDiscriminator(comptime T: type) []const u8 {
    if (comptime hasUnionDiscriminator(T)) {
        return validateJsonPropertyName(stringValue(T.jsonschema.discriminator), "union discriminator");
    }
    return "type";
}

pub fn fieldOmitted(comptime Parent: type, comptime field_name: []const u8) bool {
    if (comptime hasFieldMetadata(Parent, field_name)) {
        const field_meta = fieldMetadata(Parent, field_name);
        if (comptime @hasField(@TypeOf(field_meta), "omit")) return field_meta.omit;
    }
    return false;
}

pub fn fieldRequired(comptime Parent: type, comptime field_name: []const u8, comptime require_all_fields: bool) bool {
    if (comptime hasFieldMetadata(Parent, field_name)) {
        const field_meta = fieldMetadata(Parent, field_name);
        if (comptime @hasField(@TypeOf(field_meta), "required")) return field_meta.required;
    }
    return require_all_fields;
}

fn applyFieldNaming(comptime field_name: []const u8, comptime naming: FieldNaming) []const u8 {
    return switch (naming) {
        .identity => field_name,
        .camelCase => snakeToCase(field_name, false),
        .PascalCase => snakeToCase(field_name, true),
    };
}

fn snakeToCase(comptime value: []const u8, comptime upper_first: bool) []const u8 {
    if (value.len == 0) return value;
    comptime var out: []const u8 = "";
    comptime var upper_next = upper_first;
    inline for (value) |byte| {
        if (byte == '_') {
            upper_next = true;
        } else if (upper_next) {
            out = out ++ [_]u8{asciiUpper(byte)};
            upper_next = false;
        } else {
            out = out ++ [_]u8{byte};
        }
    }
    return out;
}

fn asciiUpper(comptime byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - ('a' - 'A') else byte;
}

pub fn validateSchemaFieldNames(comptime T: type, comptime naming: FieldNaming) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    const fields = info.@"struct".fields;
    inline for (fields, 0..) |field, i| {
        if (comptime fieldOmitted(T, field.name)) continue;
        const name = schemaFieldName(T, field.name, naming);
        inline for (fields[i + 1 ..]) |other| {
            if (comptime fieldOmitted(T, other.name)) continue;
            const other_name = schemaFieldName(T, other.name, naming);
            if (std.mem.eql(u8, name, other_name)) {
                @compileError("jsonschema duplicate emitted field name '" ++ name ++ "' on " ++ @typeName(T));
            }
        }
    }
}

fn validateFieldsMetadata(comptime T: type, comptime fields_meta: anytype) void {
    const FieldsMeta = @TypeOf(fields_meta);
    inline for (@typeInfo(FieldsMeta).@"struct".fields) |meta_field| {
        const field_name = meta_field.name;
        if (!reflect.hasStructField(T, field_name)) {
            @compileError("jsonschema metadata references unknown field '" ++ field_name ++ "' on " ++ @typeName(T));
        }

        const FieldType = reflect.structFieldType(T, field_name);
        const field_meta = @field(fields_meta, field_name);
        ensureStruct(@TypeOf(field_meta), "field metadata");
        validateKnownKeys(@TypeOf(field_meta), &(field_annotation_keys ++ field_default_key ++ field_const_key ++ field_shape_keys ++ field_constraint_keys ++ [_][]const u8{"name"}), "field metadata");
        validateMetadataValueTypes(field_meta, &field_annotation_keys, "field metadata");
        validateMetadataValueTypes(field_meta, &[_][]const u8{"name"}, "field metadata");
        validateMetadataValueTypes(field_meta, &field_default_key, "field metadata");
        validateMetadataValueTypes(field_meta, &field_const_key, "field metadata");
        validateMetadataValueTypes(field_meta, &field_shape_keys, "field metadata");
        validateMetadataValueTypes(field_meta, &field_constraint_keys, "field metadata");
        const field_path = @typeName(T) ++ "." ++ field_name;
        validateFieldConstraintCompatibility(FieldType, field_meta, field_path);
        validateFieldDefaultCompatibility(FieldType, field_meta, field_path);
        validateFieldConstCompatibility(FieldType, field_meta, field_path);
        validateFieldShapeCompatibility(field_meta, field_path);
        validateExamplesCompatibility(FieldType, field_meta, "field metadata at '" ++ field_path ++ "'");
    }
}

pub fn validateSchemaFieldName(comptime name: []const u8) []const u8 {
    return validateJsonPropertyName(name, "field metadata key 'name'");
}

pub fn validateJsonPropertyName(comptime name: []const u8, comptime where: []const u8) []const u8 {
    if (name.len == 0) @compileError("jsonschema " ++ where ++ " must not be empty");
    inline for (name) |byte| {
        if (byte < 0x20) @compileError("jsonschema " ++ where ++ " must not contain control characters");
    }
    return name;
}

fn stringValue(comptime value: anytype) []const u8 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => value,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| value[0..arr.len],
                else => @compileError("jsonschema metadata key 'name' must be a string"),
            },
            else => @compileError("jsonschema metadata key 'name' must be a string"),
        },
        else => @compileError("jsonschema metadata key 'name' must be a string"),
    };
}

fn ensureStruct(comptime T: type, comptime where: []const u8) void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => @compileError("jsonschema " ++ where ++ " must be a struct literal"),
    }
}

fn validateKnownKeys(comptime Meta: type, comptime allowed: []const []const u8, comptime where: []const u8) void {
    inline for (@typeInfo(Meta).@"struct".fields) |field| {
        if (!reflect.contains(allowed, field.name)) {
            @compileError("unknown jsonschema " ++ where ++ " key '" ++ field.name ++ "'");
        }
    }
}

fn validateMetadataValueTypes(comptime metadata: anytype, comptime keys: []const []const u8, comptime where: []const u8) void {
    inline for (keys) |key| {
        if (@hasField(@TypeOf(metadata), key)) {
            const Value = @TypeOf(@field(metadata, key));
            if (std.mem.eql(u8, key, "name") or
                std.mem.eql(u8, key, "title") or
                std.mem.eql(u8, key, "description") or
                std.mem.eql(u8, key, "pattern") or
                std.mem.eql(u8, key, "format"))
            {
                if (!reflect.isString(Value)) @compileError("jsonschema " ++ where ++ " key '" ++ key ++ "' must be a string");
            } else if (std.mem.eql(u8, key, "deprecated") or
                std.mem.eql(u8, key, "readOnly") or
                std.mem.eql(u8, key, "writeOnly") or
                std.mem.eql(u8, key, "uniqueItems") or
                std.mem.eql(u8, key, "required") or
                std.mem.eql(u8, key, "omit"))
            {
                if (Value != bool) @compileError("jsonschema " ++ where ++ " key '" ++ key ++ "' must be bool");
            } else if (std.mem.eql(u8, key, "minLength") or
                std.mem.eql(u8, key, "maxLength") or
                std.mem.eql(u8, key, "minItems") or
                std.mem.eql(u8, key, "maxItems"))
            {
                if (!reflect.isInteger(Value)) @compileError("jsonschema " ++ where ++ " key '" ++ key ++ "' must be integer");
            } else if (std.mem.eql(u8, key, "minimum") or
                std.mem.eql(u8, key, "maximum") or
                std.mem.eql(u8, key, "exclusiveMinimum") or
                std.mem.eql(u8, key, "exclusiveMaximum") or
                std.mem.eql(u8, key, "multipleOf"))
            {
                if (!reflect.isNumber(Value)) @compileError("jsonschema " ++ where ++ " key '" ++ key ++ "' must be number");
            } else if (std.mem.eql(u8, key, "default") or std.mem.eql(u8, key, "const")) {
                reflect.validateJsonValue(Value);
            } else if (std.mem.eql(u8, key, "examples")) {
                reflect.validateExamples(Value);
            }
        }
    }
}

fn validateFieldConstraintCompatibility(comptime FieldType: type, comptime field_meta: anytype, comptime field_path: []const u8) void {
    const Base = reflect.optionalChild(FieldType);

    inline for (&field_constraint_keys) |key| {
        if (@hasField(@TypeOf(field_meta), key)) {
            if (std.mem.eql(u8, key, "minimum") or
                std.mem.eql(u8, key, "maximum") or
                std.mem.eql(u8, key, "exclusiveMinimum") or
                std.mem.eql(u8, key, "exclusiveMaximum") or
                std.mem.eql(u8, key, "multipleOf"))
            {
                if (!reflect.isNumber(Base)) @compileError("jsonschema numeric constraint '" ++ key ++ "' on non-numeric field '" ++ field_path ++ "'");
            } else if (std.mem.eql(u8, key, "minLength") or
                std.mem.eql(u8, key, "maxLength") or
                std.mem.eql(u8, key, "pattern") or
                std.mem.eql(u8, key, "format"))
            {
                if (!reflect.isString(Base)) @compileError("jsonschema string constraint '" ++ key ++ "' on non-string field '" ++ field_path ++ "'");
            } else if (std.mem.eql(u8, key, "minItems") or
                std.mem.eql(u8, key, "maxItems") or
                std.mem.eql(u8, key, "uniqueItems"))
            {
                if (!reflect.isArrayLike(Base)) @compileError("jsonschema array constraint '" ++ key ++ "' on non-array field '" ++ field_path ++ "'");
            }
        }
    }
}

fn validateFieldDefaultCompatibility(comptime FieldType: type, comptime field_meta: anytype, comptime field_path: []const u8) void {
    if (@hasField(@TypeOf(field_meta), "default")) {
        reflect.validateDefaultCompatible(FieldType, field_meta.default, field_path);
    }
}

fn validateFieldConstCompatibility(comptime FieldType: type, comptime field_meta: anytype, comptime field_path: []const u8) void {
    if (@hasField(@TypeOf(field_meta), "const")) {
        const value = @field(field_meta, "const");
        reflect.validateJsonValue(@TypeOf(value));
        if (!reflect.isDefaultValueCompatible(FieldType, value)) {
            @compileError("jsonschema const at '" ++ field_path ++ "' does not match field type");
        }
    }
}

fn validateFieldShapeCompatibility(comptime field_meta: anytype, comptime field_path: []const u8) void {
    if (@hasField(@TypeOf(field_meta), "omit") and @field(field_meta, "omit") and
        @hasField(@TypeOf(field_meta), "required") and @field(field_meta, "required"))
    {
        @compileError("jsonschema field '" ++ field_path ++ "' cannot be both omitted and required");
    }
}

fn validateExamplesCompatibility(comptime SchemaType: type, comptime metadata: anytype, comptime where: []const u8) void {
    if (@hasField(@TypeOf(metadata), "examples")) {
        reflect.validateExamplesCompatible(SchemaType, metadata.examples, where);
    }
}
