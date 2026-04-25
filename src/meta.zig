const std = @import("std");
const reflect = @import("reflect.zig");

pub const type_meta_keys = [_][]const u8{
    "title",
    "description",
    "examples",
    "deprecated",
    "readOnly",
    "writeOnly",
};

const type_meta_keys_with_fields = type_meta_keys ++ [_][]const u8{"fields"};

pub const field_annotation_keys = [_][]const u8{
    "title",
    "description",
    "examples",
    "deprecated",
    "readOnly",
    "writeOnly",
};

pub const field_default_key = [_][]const u8{"default"};

pub const field_constraint_keys = [_][]const u8{
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "multipleOf",
    "minLength",
    "maxLength",
    "pattern",
    "format",
    "minItems",
    "maxItems",
    "uniqueItems",
};

pub fn validateTypeMetadata(comptime T: type) void {
    if (!@hasDecl(T, "jsonschema")) return;

    const schema_meta = T.jsonschema;
    ensureStruct(@TypeOf(schema_meta), "type metadata");
    validateKnownKeys(@TypeOf(schema_meta), &type_meta_keys_with_fields, "type metadata");
    validateMetadataValueTypes(schema_meta, &type_meta_keys, "type metadata");
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
        validateKnownKeys(@TypeOf(field_meta), &(field_annotation_keys ++ field_default_key ++ field_constraint_keys), "field metadata");
        validateMetadataValueTypes(field_meta, &field_annotation_keys, "field metadata");
        validateMetadataValueTypes(field_meta, &field_default_key, "field metadata");
        validateMetadataValueTypes(field_meta, &field_constraint_keys, "field metadata");
        const field_path = @typeName(T) ++ "." ++ field_name;
        validateFieldConstraintCompatibility(FieldType, field_meta, field_path);
        validateFieldDefaultCompatibility(FieldType, field_meta, field_path);
        validateExamplesCompatibility(FieldType, field_meta, "field metadata at '" ++ field_path ++ "'");
    }
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
            if (std.mem.eql(u8, key, "title") or
                std.mem.eql(u8, key, "description") or
                std.mem.eql(u8, key, "pattern") or
                std.mem.eql(u8, key, "format"))
            {
                if (!reflect.isString(Value)) @compileError("jsonschema " ++ where ++ " key '" ++ key ++ "' must be a string");
            } else if (std.mem.eql(u8, key, "deprecated") or
                std.mem.eql(u8, key, "readOnly") or
                std.mem.eql(u8, key, "writeOnly") or
                std.mem.eql(u8, key, "uniqueItems"))
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
            } else if (std.mem.eql(u8, key, "default")) {
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

fn validateExamplesCompatibility(comptime SchemaType: type, comptime metadata: anytype, comptime where: []const u8) void {
    if (@hasField(@TypeOf(metadata), "examples")) {
        reflect.validateExamplesCompatible(SchemaType, metadata.examples, where);
    }
}
