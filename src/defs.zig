const std = @import("std");
const reflect = @import("reflect.zig");
const write_json = @import("write_json.zig");

const Object = write_json.Object;

pub fn refSchema(comptime T: type, writer: anytype) !void {
    try writer.writeAll("{");
    var obj: Object = .{};
    try emitRefField(T, writer, &obj);
    try writer.writeAll("}");
}

pub fn emitRefField(comptime T: type, writer: anytype, obj: *Object) !void {
    try obj.field(writer, "$ref");
    try writer.writeAll("\"#/$defs/");
    try writeJsonPointerSegmentContent(writer, defName(T));
    try writer.writeAll("\"");
}

pub fn directRefType(comptime T: type) ?type {
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

pub fn collectDefs(comptime T: type) []const type {
    return collectDefsInSchema(T, &[_]type{}, &[_]type{});
}

pub fn hasRecursiveSchema(comptime T: type) bool {
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

pub fn validateDefNamesUnique(comptime defs: []const type) void {
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

pub fn defName(comptime T: type) []const u8 {
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
