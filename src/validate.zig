const std = @import("std");
const Options = @import("options.zig").Options;
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");

pub fn value(comptime T: type, input: T, writer: anytype, comptime options: Options) !bool {
    comptime reflect.validateType(T);
    if (comptime @hasDecl(T, "jsonschema")) {
        return validateInner(T, input, writer, options, "$", T.jsonschema);
    }
    return validateInner(T, input, writer, options, "$", .{});
}

fn validateInner(comptime T: type, input: T, writer: anytype, comptime options: Options, comptime path: []const u8, comptime field_meta: anytype) !bool {
    var ok = true;

    if (comptime @hasField(@TypeOf(field_meta), "const")) {
        if (!reflect.isDefaultValueCompatible(T, @field(field_meta, "const"))) {
            @compileError("jsonschema const at '" ++ path ++ "' does not match field type");
        }
        if (!valueEquals(T, input, @field(field_meta, "const"))) {
            try writer.print("{s}: expected const ", .{path});
            try writeValue(@TypeOf(@field(field_meta, "const")), writer, @field(field_meta, "const"));
            try writer.writeAll("\n");
            ok = false;
        }
    }

    switch (@typeInfo(T)) {
        .bool, .@"enum" => {},
        .int, .comptime_int, .float, .comptime_float => {
            ok = try validateNumeric(T, input, writer, path, field_meta) and ok;
        },
        .optional => |opt| {
            if (input) |child| ok = try validateInner(opt.child, child, writer, options, path, field_meta) and ok;
        },
        .pointer => |ptr| {
            if (comptime reflect.isString(T)) {
                ok = try validateString(input, writer, path, field_meta) and ok;
            } else switch (ptr.size) {
                .slice => {
                    ok = try validateArray(ptr.child, input, writer, path, field_meta) and ok;
                    for (input, 0..) |item, i| {
                        try writer.print("", .{});
                        _ = i;
                        ok = try validateInner(ptr.child, item, writer, options, path ++ "[]", .{}) and ok;
                    }
                },
                .one => switch (@typeInfo(ptr.child)) {
                    .@"struct", .@"union" => ok = try validateInner(ptr.child, input.*, writer, options, path, field_meta) and ok,
                    else => {},
                },
                else => {},
            }
        },
        .array => |arr| {
            ok = try validateArray(arr.child, input, writer, path, field_meta) and ok;
            for (input) |item| ok = try validateInner(arr.child, item, writer, options, path ++ "[]", .{}) and ok;
        },
        .@"struct" => |st| {
            ok = try validateObject(T, input, writer, path, field_meta) and ok;
            if (comptime reflect.isStringMap(T)) return ok;
            if (st.is_tuple) {
                inline for (st.fields, 0..) |field, i| {
                    ok = try validateInner(field.type, @field(input, field.name), writer, options, path ++ "[" ++ std.fmt.comptimePrint("{}", .{i}) ++ "]", .{}) and ok;
                }
            } else {
                inline for (st.fields) |field| {
                    if (comptime meta.fieldOmitted(T, field.name)) continue;
                    const field_path = comptime path ++ "." ++ meta.schemaFieldName(T, field.name, options.field_naming);
                    if (comptime meta.hasFieldMetadata(T, field.name)) {
                        ok = try validateInner(field.type, @field(input, field.name), writer, options, field_path, meta.fieldMetadata(T, field.name)) and ok;
                    } else {
                        ok = try validateInner(field.type, @field(input, field.name), writer, options, field_path, .{}) and ok;
                    }
                }
            }
        },
        .@"union" => |un| {
            const tag_name = @tagName(input);
            inline for (un.fields) |field| {
                if (std.mem.eql(u8, field.name, tag_name) and field.type != void) {
                    ok = try validateInner(field.type, @field(input, field.name), writer, options, path ++ "." ++ field.name, .{}) and ok;
                }
            }
        },
        else => {},
    }

    return ok;
}

fn validateNumeric(comptime T: type, input: T, writer: anytype, comptime path: []const u8, comptime field_meta: anytype) !bool {
    var ok = true;
    inline for (.{ "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum" }) |key| {
        if (comptime @hasField(@TypeOf(field_meta), key)) {
            const bound = @field(field_meta, key);
            const failed = if (comptime std.mem.eql(u8, key, "minimum"))
                input < bound
            else if (comptime std.mem.eql(u8, key, "maximum"))
                input > bound
            else if (comptime std.mem.eql(u8, key, "exclusiveMinimum"))
                input <= bound
            else
                input >= bound;
            if (failed) {
                try writer.print("{s}: failed {s} ", .{ path, key });
                try writeValue(@TypeOf(bound), writer, bound);
                try writer.writeAll("\n");
                ok = false;
            }
        }
    }
    if (comptime @hasField(@TypeOf(field_meta), "multipleOf")) {
        if (!isMultipleOf(input, field_meta.multipleOf)) {
            try writer.print("{s}: failed multipleOf ", .{path});
            try writeValue(@TypeOf(field_meta.multipleOf), writer, field_meta.multipleOf);
            try writer.writeAll("\n");
            ok = false;
        }
    }
    return ok;
}

fn isMultipleOf(input: anytype, multiple: anytype) bool {
    const quotient = numberToF128(input) / numberToF128(multiple);
    return std.math.approxEqAbs(f128, quotient, @round(quotient), 1e-9);
}

fn numberToF128(input: anytype) f128 {
    return switch (@typeInfo(@TypeOf(input))) {
        .int, .comptime_int => @floatFromInt(input),
        .float, .comptime_float => @as(f128, input),
        else => unreachable,
    };
}

fn validateString(input: anytype, writer: anytype, comptime path: []const u8, comptime field_meta: anytype) !bool {
    var ok = true;
    if (comptime @hasField(@TypeOf(field_meta), "minLength")) {
        if (input.len < field_meta.minLength) {
            try writer.print("{s}: failed minLength {}\n", .{ path, field_meta.minLength });
            ok = false;
        }
    }
    if (comptime @hasField(@TypeOf(field_meta), "maxLength")) {
        if (input.len > field_meta.maxLength) {
            try writer.print("{s}: failed maxLength {}\n", .{ path, field_meta.maxLength });
            ok = false;
        }
    }
    return ok;
}

fn validateObject(comptime T: type, input: T, writer: anytype, comptime path: []const u8, comptime field_meta: anytype) !bool {
    var ok = true;
    const count = objectPropertyCount(T, input);
    if (comptime @hasField(@TypeOf(field_meta), "minProperties")) {
        if (count < field_meta.minProperties) {
            try writer.print("{s}: failed minProperties {}\n", .{ path, field_meta.minProperties });
            ok = false;
        }
    }
    if (comptime @hasField(@TypeOf(field_meta), "maxProperties")) {
        if (count > field_meta.maxProperties) {
            try writer.print("{s}: failed maxProperties {}\n", .{ path, field_meta.maxProperties });
            ok = false;
        }
    }
    return ok;
}

fn objectPropertyCount(comptime T: type, input: T) usize {
    if (comptime reflect.isStringMap(T)) return input.count();
    comptime var count: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime !meta.fieldOmitted(T, field.name)) count += 1;
    }
    return count;
}

fn validateArray(comptime Child: type, input: anytype, writer: anytype, comptime path: []const u8, comptime field_meta: anytype) !bool {
    var ok = true;
    if (comptime @hasField(@TypeOf(field_meta), "minItems")) {
        if (input.len < field_meta.minItems) {
            try writer.print("{s}: failed minItems {}\n", .{ path, field_meta.minItems });
            ok = false;
        }
    }
    if (comptime @hasField(@TypeOf(field_meta), "maxItems")) {
        if (input.len > field_meta.maxItems) {
            try writer.print("{s}: failed maxItems {}\n", .{ path, field_meta.maxItems });
            ok = false;
        }
    }
    if (comptime @hasField(@TypeOf(field_meta), "uniqueItems") and field_meta.uniqueItems) {
        if (!itemsUnique(Child, input)) {
            try writer.print("{s}: failed uniqueItems\n", .{path});
            ok = false;
        }
    }
    if (comptime @hasField(@TypeOf(field_meta), "contains")) {
        const count = containsMatchCount(Child, input, field_meta.contains);
        const min = comptime if (@hasField(@TypeOf(field_meta), "minContains")) field_meta.minContains else 1;
        if (count < min) {
            if (comptime @hasField(@TypeOf(field_meta), "minContains")) {
                try writer.print("{s}: failed minContains {}\n", .{ path, min });
            } else {
                try writer.print("{s}: failed contains\n", .{path});
            }
            ok = false;
        }
        if (comptime @hasField(@TypeOf(field_meta), "maxContains")) {
            if (count > field_meta.maxContains) {
                try writer.print("{s}: failed maxContains {}\n", .{ path, field_meta.maxContains });
                ok = false;
            }
        }
    }
    return ok;
}

fn containsMatchCount(comptime Child: type, input: anytype, comptime contains_schema: anytype) usize {
    var count: usize = 0;
    for (input) |item| {
        if (schemaLiteralMatches(Child, item, contains_schema)) count += 1;
    }
    return count;
}

fn schemaLiteralMatches(comptime T: type, input: T, comptime schema_literal: anytype) bool {
    if (comptime @hasField(@TypeOf(schema_literal), "const")) {
        return valueEquals(T, input, @field(schema_literal, "const"));
    }
    return true;
}

fn itemsUnique(comptime Child: type, input: anytype) bool {
    for (input, 0..) |left, i| {
        for (input[i + 1 ..]) |right| {
            if (jsonValueEquals(Child, left, right)) return false;
        }
    }
    return true;
}

fn jsonValueEquals(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => a == b,
        .@"enum" => a == b,
        .optional => |opt| blk: {
            if (a == null and b == null) break :blk true;
            if (a == null or b == null) break :blk false;
            break :blk jsonValueEquals(opt.child, a.?, b.?);
        },
        .pointer => |ptr| blk: {
            if (comptime reflect.isString(T)) break :blk std.mem.eql(u8, a, b);
            switch (ptr.size) {
                .slice => {
                    if (a.len != b.len) break :blk false;
                    for (a, b) |left, right| {
                        if (!jsonValueEquals(ptr.child, left, right)) break :blk false;
                    }
                    break :blk true;
                },
                .one => switch (@typeInfo(ptr.child)) {
                    .array, .@"struct", .@"union" => break :blk jsonValueEquals(ptr.child, a.*, b.*),
                    else => break :blk false,
                },
                else => break :blk false,
            }
        },
        .array => |arr| blk: {
            for (a, b) |left, right| {
                if (!jsonValueEquals(arr.child, left, right)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |st| blk: {
            if (comptime reflect.isStringMap(T)) break :blk false;
            inline for (st.fields) |field| {
                if (comptime !st.is_tuple and meta.fieldOmitted(T, field.name)) continue;
                if (!jsonValueEquals(field.type, @field(a, field.name), @field(b, field.name))) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |un| blk: {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) break :blk false;
            const tag_name = @tagName(a);
            inline for (un.fields) |field| {
                if (std.mem.eql(u8, field.name, tag_name)) {
                    if (field.type == void) break :blk true;
                    break :blk jsonValueEquals(field.type, @field(a, field.name), @field(b, field.name));
                }
            }
            break :blk false;
        },
        else => false,
    };
}

fn valueEquals(comptime T: type, a: T, b: anytype) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => a == b,
        .@"enum" => blk: {
            if (@TypeOf(b) == T) break :blk a == b;
            if (reflect.isString(@TypeOf(b))) break :blk std.mem.eql(u8, @tagName(a), stringValue(b));
            break :blk false;
        },
        .pointer => if (comptime reflect.isString(T)) std.mem.eql(u8, a, stringValue(b)) else false,
        else => false,
    };
}

fn writeValue(comptime T: type, writer: anytype, input: T) !void {
    switch (@typeInfo(T)) {
        .pointer => if (comptime reflect.isString(T)) {
            try writer.print("\"{s}\"", .{input});
        } else {
            try writer.print("{any}", .{input});
        },
        .@"enum" => try writer.print("\"{s}\"", .{@tagName(input)}),
        else => try writer.print("{}", .{input}),
    }
}

fn stringValue(comptime input: anytype) []const u8 {
    const T = @TypeOf(input);
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => input,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| input[0..arr.len],
                else => unreachable,
            },
            else => unreachable,
        },
        else => unreachable,
    };
}
