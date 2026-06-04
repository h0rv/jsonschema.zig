//! Helpers over `std.json.Value` for JSON Schema validation: type tests,
//! numeric coercion, and JSON-equality (used by `const`, `enum`, `uniqueItems`).

const std = @import("std");
pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;

/// JSON Schema primitive type names.
pub const TypeName = enum { null, boolean, object, array, number, integer, string };

/// Numeric view of a JSON value.
pub const Num = struct {
    f: f64,
    /// Whether the value represents a mathematical integer.
    is_integer: bool,
    /// Original integer value when it fit i64 (for exact comparisons).
    int: ?i64 = null,
};

/// Return the JSON type of `v` as used by the `type` keyword (integer is a
/// refinement of number, handled separately by `typeMatches`).
pub fn baseType(v: *const Value) TypeName {
    return switch (v.*) {
        .null => .null,
        .bool => .boolean,
        .object => .object,
        .array => .array,
        .string => .string,
        .integer, .float, .number_string => .number,
    };
}

/// True when `v` matches the schema `type` token `name`.
pub fn typeMatches(v: *const Value, name: []const u8) bool {
    if (std.mem.eql(u8, name, "integer")) {
        const n = asNumber(v) orelse return false;
        return n.is_integer;
    }
    if (std.mem.eql(u8, name, "number")) return asNumber(v) != null;
    const bt = baseType(v);
    return std.mem.eql(u8, name, @tagName(bt));
}

/// Coerce a numeric JSON value to `Num`, or null if not numeric.
pub fn asNumber(v: *const Value) ?Num {
    switch (v.*) {
        .integer => |i| return .{ .f = @floatFromInt(i), .is_integer = true, .int = i },
        .float => |f| return .{ .f = f, .is_integer = isIntegralFloat(f) },
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |i| {
                return .{ .f = @floatFromInt(i), .is_integer = true, .int = i };
            } else |_| {}
            const f = std.fmt.parseFloat(f64, s) catch return null;
            // A `number_string` is produced for integers too large for i64; such
            // strings carry no '.' or exponent. Classify integer-ness from the
            // text so values that overflow f64 are still recognized as integers.
            const is_int = std.mem.indexOfScalar(u8, s, '.') == null and
                std.mem.indexOfAny(u8, s, "eE") == null;
            return .{ .f = f, .is_integer = is_int };
        },
        else => return null,
    }
}

fn isIntegralFloat(f: f64) bool {
    if (std.math.isNan(f) or std.math.isInf(f)) return false;
    return @floor(f) == f;
}

/// JSON deep equality, treating numbers numerically (`1 == 1.0`).
pub fn equal(a: *const Value, b: *const Value) bool {
    const an = asNumber(a);
    const bn = asNumber(b);
    if (an != null and bn != null) return numEqual(an.?, bn.?);
    if (an != null or bn != null) return false; // one numeric, one not

    switch (a.*) {
        .null => return b.* == .null,
        .bool => |x| return b.* == .bool and b.bool == x,
        .string => |x| return b.* == .string and std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (b.* != .array) return false;
            const y = b.array;
            if (x.items.len != y.items.len) return false;
            for (x.items, y.items) |*ia, *ib| {
                if (!equal(ia, ib)) return false;
            }
            return true;
        },
        .object => |x| {
            if (b.* != .object) return false;
            const y = b.object;
            if (x.count() != y.count()) return false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = y.getPtr(e.key_ptr.*) orelse return false;
                if (!equal(e.value_ptr, other)) return false;
            }
            return true;
        },
        else => unreachable, // numbers handled above
    }
}

fn numEqual(a: Num, b: Num) bool {
    if (a.int) |ai| {
        if (b.int) |bi| return ai == bi;
    }
    return a.f == b.f;
}

/// Count of unicode code points in a UTF-8 string (for length keywords).
pub fn utf8Len(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Write a canonical decimal string for a numeric value into `buf`.
pub fn decimalString(buf: []u8, v: *const Value) ?[]const u8 {
    return switch (v.*) {
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch null,
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch null,
        .number_string => |s| s,
        else => null,
    };
}

const Decimal = struct { mant: std.math.big.int.Managed, scale: i64 };

/// Parse a JSON number string into mantissa * 10^(-scale). Caller deinits mant.
fn parseDecimal(allocator: std.mem.Allocator, s: []const u8) !?Decimal {
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(allocator);
    var i: usize = 0;
    var negative = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        negative = s[i] == '-';
        i += 1;
    }
    var scale: i64 = 0;
    var seen_dot = false;
    var exp: i64 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '.') {
            if (seen_dot) return null;
            seen_dot = true;
        } else if (c == 'e' or c == 'E') {
            exp = std.fmt.parseInt(i64, s[i + 1 ..], 10) catch return null;
            break;
        } else if (c >= '0' and c <= '9') {
            try digits.append(allocator, c);
            if (seen_dot) scale += 1;
        } else return null;
    }
    if (digits.items.len == 0) return null;
    scale -= exp;
    var mant = try std.math.big.int.Managed.init(allocator);
    errdefer mant.deinit();
    mant.setString(10, digits.items) catch {
        mant.deinit();
        return null;
    };
    if (negative) mant.negate();
    return .{ .mant = mant, .scale = scale };
}

/// Exact `multipleOf`: returns whether `x_str` is an integer multiple of
/// `d_str`, using big-integer arithmetic (handles values that overflow f64).
pub fn multipleOfBig(allocator: std.mem.Allocator, x_str: []const u8, d_str: []const u8) !?bool {
    const Managed = std.math.big.int.Managed;
    var xd = (try parseDecimal(allocator, x_str)) orelse return null;
    defer xd.mant.deinit();
    var dd = (try parseDecimal(allocator, d_str)) orelse return null;
    defer dd.mant.deinit();

    const s = @max(xd.scale, dd.scale);
    var ten = try Managed.initSet(allocator, 10);
    defer ten.deinit();

    // X = mant_x * 10^(s - scale_x); D = mant_d * 10^(s - scale_d)
    var X = try scaleBy(allocator, &xd.mant, &ten, @intCast(s - xd.scale));
    defer X.deinit();
    var D = try scaleBy(allocator, &dd.mant, &ten, @intCast(s - dd.scale));
    defer D.deinit();

    if (D.eqlZero()) return false;
    var q = try Managed.init(allocator);
    defer q.deinit();
    var r = try Managed.init(allocator);
    defer r.deinit();
    try Managed.divFloor(&q, &r, &X, &D);
    return r.eqlZero();
}

fn scaleBy(allocator: std.mem.Allocator, m: *std.math.big.int.Managed, ten: *std.math.big.int.Managed, power: u64) !std.math.big.int.Managed {
    const Managed = std.math.big.int.Managed;
    var result = try Managed.init(allocator);
    errdefer result.deinit();
    try result.copy(m.toConst());
    var k: u64 = 0;
    while (k < power) : (k += 1) {
        try result.mul(&result, ten);
    }
    return result;
}

test "equal: numbers compare numerically" {
    const a = std.testing.allocator;
    const one_int = try std.json.parseFromSlice(Value, a, "1", .{});
    defer one_int.deinit();
    const one_float = try std.json.parseFromSlice(Value, a, "1.0", .{});
    defer one_float.deinit();
    const two = try std.json.parseFromSlice(Value, a, "2", .{});
    defer two.deinit();
    try std.testing.expect(equal(&one_int.value, &one_float.value));
    try std.testing.expect(!equal(&one_int.value, &two.value));
}

test "equal: arrays and objects deep" {
    const a = std.testing.allocator;
    const x = try std.json.parseFromSlice(Value, a, "{\"a\":[1,2],\"b\":true}", .{});
    defer x.deinit();
    const y = try std.json.parseFromSlice(Value, a, "{\"b\":true,\"a\":[1,2]}", .{});
    defer y.deinit();
    const z = try std.json.parseFromSlice(Value, a, "{\"b\":true,\"a\":[1,3]}", .{});
    defer z.deinit();
    try std.testing.expect(equal(&x.value, &y.value)); // key order irrelevant
    try std.testing.expect(!equal(&x.value, &z.value));
}

test "typeMatches integer vs number" {
    const a = std.testing.allocator;
    const f = try std.json.parseFromSlice(Value, a, "1.0", .{});
    defer f.deinit();
    const g = try std.json.parseFromSlice(Value, a, "1.5", .{});
    defer g.deinit();
    try std.testing.expect(typeMatches(&f.value, "integer"));
    try std.testing.expect(!typeMatches(&g.value, "integer"));
    try std.testing.expect(typeMatches(&g.value, "number"));

    // A huge integer overflows i64 -> number_string, but is still an integer.
    const big = try std.json.parseFromSlice(Value, a, "1" ++ "0" ** 40, .{});
    defer big.deinit();
    try std.testing.expect(big.value == .number_string);
    try std.testing.expect(typeMatches(&big.value, "integer"));
}

test "multipleOfBig exact" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?bool, true), try multipleOfBig(a, "1" ++ "0" ** 30, "0.5"));
    try std.testing.expectEqual(@as(?bool, true), try multipleOfBig(a, "100", "0.0001"));
    try std.testing.expectEqual(@as(?bool, false), try multipleOfBig(a, "7", "2"));
    try std.testing.expectEqual(@as(?bool, true), try multipleOfBig(a, "1e3", "10"));
}
