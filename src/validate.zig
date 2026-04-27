const std = @import("std");
const Options = @import("options.zig").Options;
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");

pub fn value(comptime T: type, input: T, writer: anytype, comptime options: Options) !bool {
    comptime reflect.validateType(T);
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
                    ok = try validateArrayBounds(input.len, writer, path, field_meta) and ok;
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
            ok = try validateArrayBounds(input.len, writer, path, field_meta) and ok;
            for (input) |item| ok = try validateInner(arr.child, item, writer, options, path ++ "[]", .{}) and ok;
        },
        .@"struct" => |st| {
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

fn validateArrayBounds(len: usize, writer: anytype, comptime path: []const u8, comptime field_meta: anytype) !bool {
    var ok = true;
    if (comptime @hasField(@TypeOf(field_meta), "minItems")) {
        if (len < field_meta.minItems) {
            try writer.print("{s}: failed minItems {}\n", .{ path, field_meta.minItems });
            ok = false;
        }
    }
    if (comptime @hasField(@TypeOf(field_meta), "maxItems")) {
        if (len > field_meta.maxItems) {
            try writer.print("{s}: failed maxItems {}\n", .{ path, field_meta.maxItems });
            ok = false;
        }
    }
    return ok;
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
