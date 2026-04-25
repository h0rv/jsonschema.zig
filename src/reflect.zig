const std = @import("std");

pub fn validateType(comptime T: type) void {
    validateTypeInner(T, &[_]type{});
}

fn validateTypeInner(comptime T: type, comptime stack: []const type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => {},
        .pointer => |ptr| {
            if (comptime isString(T)) return;
            switch (ptr.size) {
                .slice => validateTypeInner(ptr.child, stack),
                else => unsupported(T),
            }
        },
        .array => |arr| validateTypeInner(arr.child, stack),
        .optional => |opt| validateTypeInner(opt.child, stack),
        .@"enum" => {},
        .@"struct" => |st| {
            if (st.is_tuple) unsupported(T);
            if (containsType(stack, T)) return;
            const next_stack = stack ++ [_]type{T};
            inline for (st.fields) |field| {
                validateTypeInner(field.type, next_stack);
                if (field.defaultValue()) |default_value| {
                    validateDefaultCompatible(field.type, default_value, field.name);
                }
            }
        },
        else => unsupported(T),
    }
}

pub fn validateJsonValue(comptime T: type) void {
    validateJsonValueInner(T, &[_]type{});
}

fn validateJsonValueInner(comptime T: type, comptime stack: []const type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .null => {},
        .pointer => |ptr| {
            if (comptime isString(T)) return;
            switch (ptr.size) {
                .slice => validateJsonValueInner(ptr.child, stack),
                .one => switch (@typeInfo(ptr.child)) {
                    .array => |arr| validateJsonValueInner(arr.child, stack),
                    else => unsupportedJsonValue(T),
                },
                else => unsupportedJsonValue(T),
            }
        },
        .array => |arr| validateJsonValueInner(arr.child, stack),
        .optional => |opt| validateJsonValueInner(opt.child, stack),
        .@"enum" => {},
        .@"struct" => |st| {
            if (containsType(stack, T)) return;
            const next_stack = stack ++ [_]type{T};
            inline for (st.fields) |field| validateJsonValueInner(field.type, next_stack);
        },
        else => unsupportedJsonValue(T),
    }
}

pub fn validateExamples(comptime T: type) void {
    switch (@typeInfo(T)) {
        .array => |arr| validateJsonValue(arr.child),
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (isString(T)) @compileError("jsonschema metadata key 'examples' must be an array");
                validateJsonValue(ptr.child);
            },
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| {
                    if (arr.child == u8) @compileError("jsonschema metadata key 'examples' must be an array");
                    validateJsonValue(arr.child);
                },
                else => @compileError("jsonschema metadata key 'examples' must be an array"),
            },
            else => @compileError("jsonschema metadata key 'examples' must be an array"),
        },
        .@"struct" => |st| {
            if (!st.is_tuple) @compileError("jsonschema metadata key 'examples' must be an array");
            inline for (st.fields) |field| validateJsonValue(field.type);
        },
        else => @compileError("jsonschema metadata key 'examples' must be an array"),
    }
}

pub fn validateDefaultCompatible(comptime FieldType: type, comptime default_value: anytype, comptime field_name: []const u8) void {
    validateJsonValue(@TypeOf(default_value));
    if (!isDefaultValueCompatible(FieldType, default_value)) {
        @compileError("jsonschema default for field '" ++ field_name ++ "' does not match field type");
    }
}

pub fn validateExamplesCompatible(comptime SchemaType: type, comptime examples: anytype, comptime where: []const u8) void {
    validateExamples(@TypeOf(examples));
    const Examples = @TypeOf(examples);
    switch (@typeInfo(Examples)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => switch (@typeInfo(ptr.child)) {
                .array => inline for (examples.*) |example| validateExampleCompatible(SchemaType, example, where),
                else => unreachable,
            },
            .slice => inline for (examples) |example| validateExampleCompatible(SchemaType, example, where),
            else => unreachable,
        },
        else => inline for (examples) |example| validateExampleCompatible(SchemaType, example, where),
    }
}

fn validateExampleCompatible(comptime SchemaType: type, comptime example: anytype, comptime where: []const u8) void {
    if (!isDefaultValueCompatible(SchemaType, example)) {
        @compileError("jsonschema " ++ where ++ " key 'examples' contains value that does not match " ++ @typeName(SchemaType));
    }
}

pub fn isDefaultValueCompatible(comptime SchemaType: type, comptime value: anytype) bool {
    const ValueType = @TypeOf(value);
    return switch (@typeInfo(SchemaType)) {
        .bool => ValueType == bool,
        .int, .comptime_int => isInteger(ValueType),
        .float, .comptime_float => isNumber(ValueType) and isFinite(value),
        .pointer => |ptr| blk: {
            if (isString(SchemaType)) break :blk isString(ValueType);
            if (ptr.size == .slice and isArrayValue(ValueType)) {
                break :blk arrayValueCompatible(ptr.child, value);
            }
            break :blk false;
        },
        .array => |arr| if (isArrayValue(ValueType)) arrayValueCompatible(arr.child, value) else false,
        .optional => |opt| switch (@typeInfo(ValueType)) {
            .null => true,
            .optional => if (value) |child| isDefaultValueCompatible(opt.child, child) else true,
            else => isDefaultValueCompatible(opt.child, value),
        },
        .@"enum" => blk: {
            if (ValueType == SchemaType) break :blk true;
            if (!isString(ValueType)) break :blk false;
            break :blk enumHasName(SchemaType, stringValue(value));
        },
        .@"struct" => |schema_struct| objectValueCompatible(SchemaType, schema_struct, value),
        else => false,
    };
}

pub fn hasStructField(comptime T: type, comptime name: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

pub fn structFieldType(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type;
    }
    unreachable;
}

pub fn optionalChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

pub fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| arr.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

pub fn isArrayLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => true,
        .pointer => |ptr| switch (ptr.size) {
            .slice => !isString(T),
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| arr.child != u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

pub fn isInteger(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => true,
        else => false,
    };
}

pub fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => true,
        else => false,
    };
}

pub fn isArrayValue(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => true,
        .pointer => |ptr| switch (ptr.size) {
            .slice => !isString(T),
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| arr.child != u8,
                else => false,
            },
            else => false,
        },
        .@"struct" => |st| st.is_tuple,
        else => false,
    };
}

fn arrayValueCompatible(comptime Child: type, comptime value: anytype) bool {
    if (!isArrayValue(@TypeOf(value))) return false;
    const Value = @TypeOf(value);
    switch (@typeInfo(Value)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => switch (@typeInfo(ptr.child)) {
                .array => inline for (value.*) |item| {
                    if (!isDefaultValueCompatible(Child, item)) return false;
                },
                else => return false,
            },
            .slice => inline for (value) |item| {
                if (!isDefaultValueCompatible(Child, item)) return false;
            },
            else => return false,
        },
        else => inline for (value) |item| {
            if (!isDefaultValueCompatible(Child, item)) return false;
        },
    }
    return true;
}

fn isFinite(comptime value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .float => std.math.isFinite(value),
        .comptime_float => std.math.isFinite(@as(f128, value)),
        else => true,
    };
}

fn objectValueCompatible(comptime SchemaType: type, comptime schema_struct: std.builtin.Type.Struct, comptime value: anytype) bool {
    const ValueType = @TypeOf(value);
    if (ValueType == SchemaType) return true;

    const value_info = @typeInfo(ValueType);
    if (value_info != .@"struct" or value_info.@"struct".is_tuple) return false;

    inline for (schema_struct.fields) |schema_field| {
        if (!@hasField(ValueType, schema_field.name)) return false;
        if (!isDefaultValueCompatible(schema_field.type, @field(value, schema_field.name))) return false;
    }
    inline for (value_info.@"struct".fields) |value_field| {
        if (!hasStructField(SchemaType, value_field.name)) return false;
    }
    return true;
}

fn enumHasName(comptime EnumType: type, comptime name: []const u8) bool {
    inline for (@typeInfo(EnumType).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn stringValue(comptime value: anytype) []const u8 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => value,
            .one => switch (@typeInfo(ptr.child)) {
                .array => value,
                else => unreachable,
            },
            else => unreachable,
        },
        else => unreachable,
    };
}

pub fn contains(comptime haystack: []const []const u8, comptime needle: []const u8) bool {
    inline for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn containsType(comptime haystack: []const type, comptime needle: type) bool {
    inline for (haystack) |item| {
        if (item == needle) return true;
    }
    return false;
}

pub fn unsupported(comptime T: type) noreturn {
    @compileError("unsupported jsonschema Zig type: " ++ @typeName(T));
}

pub fn unsupportedJsonValue(comptime T: type) noreturn {
    @compileError("unsupported jsonschema JSON value type: " ++ @typeName(T));
}
