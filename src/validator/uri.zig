//! RFC 3986 URI-reference resolution and helpers for JSON Schema identifiers.
//!
//! JSON Schema uses URI-references loosely (relative refs, plain-name anchors,
//! URNs, empty fragments). `std.Uri` re-escapes components on recomposition,
//! which corrupts these identifiers, so we operate on raw strings here.

const std = @import("std");

/// Parsed URI-reference components (RFC 3986 Appendix B). Slices borrow `input`.
pub const Parts = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

/// Split a URI-reference into its components without decoding.
pub fn split(input: []const u8) Parts {
    var rest = input;
    var parts: Parts = .{};

    // fragment
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| {
        parts.fragment = rest[h + 1 ..];
        rest = rest[0..h];
    }
    // query
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        parts.query = rest[q + 1 ..];
        rest = rest[0..q];
    }
    // scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":" before any "/"
    if (schemeEnd(rest)) |c| {
        parts.scheme = rest[0..c];
        rest = rest[c + 1 ..];
    }
    // authority
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const end = indexOfAny(after, "/?#") orelse after.len;
        parts.authority = after[0..end];
        rest = after[end..];
    }
    parts.path = rest;
    return parts;
}

fn schemeEnd(s: []const u8) ?usize {
    if (s.len == 0 or !isAlpha(s[0])) return null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ':') return if (i == 0) null else i;
        if (!(isAlpha(c) or isDigit(c) or c == '+' or c == '-' or c == '.')) return null;
        if (c == '/') return null;
    }
    return null;
}

fn indexOfAny(s: []const u8, set: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (std.mem.indexOfScalar(u8, set, c) != null) return i;
    }
    return null;
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Resolve `ref` against absolute `base` per RFC 3986 §5.3. Caller owns result.
pub fn resolve(allocator: std.mem.Allocator, base: []const u8, ref: []const u8) ![]u8 {
    const b = split(base);
    const r = split(ref);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var t_scheme: ?[]const u8 = null;
    var t_authority: ?[]const u8 = null;
    var t_query: ?[]const u8 = null;
    // path computed into a buffer we may allocate
    var merged: ?[]u8 = null;
    defer if (merged) |m| allocator.free(m);
    var t_path: []const u8 = "";

    if (r.scheme) |s| {
        t_scheme = s;
        t_authority = r.authority;
        merged = try removeDotSegments(allocator, r.path);
        t_path = merged.?;
        t_query = r.query;
    } else {
        if (r.authority) |a| {
            t_authority = a;
            merged = try removeDotSegments(allocator, r.path);
            t_path = merged.?;
            t_query = r.query;
        } else {
            if (r.path.len == 0) {
                t_path = b.path;
                t_query = if (r.query != null) r.query else b.query;
            } else if (r.path[0] == '/') {
                merged = try removeDotSegments(allocator, r.path);
                t_path = merged.?;
                t_query = r.query;
            } else {
                const m = try mergePaths(allocator, b, r.path);
                defer allocator.free(m);
                merged = try removeDotSegments(allocator, m);
                t_path = merged.?;
                t_query = r.query;
            }
            t_authority = b.authority;
        }
        t_scheme = b.scheme;
    }

    if (t_scheme) |s| {
        try out.appendSlice(allocator, s);
        try out.append(allocator, ':');
    }
    if (t_authority) |a| {
        try out.appendSlice(allocator, "//");
        try out.appendSlice(allocator, a);
    }
    try out.appendSlice(allocator, t_path);
    if (t_query) |q| {
        try out.append(allocator, '?');
        try out.appendSlice(allocator, q);
    }
    if (r.fragment) |f| {
        try out.append(allocator, '#');
        try out.appendSlice(allocator, f);
    }
    return out.toOwnedSlice(allocator);
}

fn mergePaths(allocator: std.mem.Allocator, base: Parts, ref_path: []const u8) ![]u8 {
    if (base.authority != null and base.path.len == 0) {
        return std.mem.concat(allocator, u8, &.{ "/", ref_path });
    }
    const last_slash = std.mem.lastIndexOfScalar(u8, base.path, '/');
    const prefix = if (last_slash) |i| base.path[0 .. i + 1] else "";
    return std.mem.concat(allocator, u8, &.{ prefix, ref_path });
}

/// RFC 3986 §5.2.4 remove_dot_segments. Caller owns result.
pub fn removeDotSegments(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var input = path;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (input.len > 0) {
        if (std.mem.startsWith(u8, input, "../")) {
            input = input[3..];
        } else if (std.mem.startsWith(u8, input, "./")) {
            input = input[2..];
        } else if (std.mem.startsWith(u8, input, "/./")) {
            input = input[2..]; // "/./x" -> "/x"
        } else if (std.mem.eql(u8, input, "/.")) {
            input = "/";
        } else if (std.mem.startsWith(u8, input, "/../")) {
            input = input[3..]; // "/../x" -> "/x"
            removeLastSegment(allocator, &out);
        } else if (std.mem.eql(u8, input, "/..")) {
            input = "/";
            removeLastSegment(allocator, &out);
        } else if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..")) {
            input = "";
        } else {
            // move first path segment (including leading '/') to output
            var i: usize = 0;
            if (input[0] == '/') i = 1;
            while (i < input.len and input[i] != '/') : (i += 1) {}
            try out.appendSlice(allocator, input[0..i]);
            input = input[i..];
        }
    }
    return out.toOwnedSlice(allocator);
}

fn removeLastSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    _ = allocator;
    if (out.items.len == 0) return;
    var i = out.items.len;
    while (i > 0) {
        i -= 1;
        if (out.items[i] == '/') {
            out.items.len = i;
            return;
        }
    }
    out.items.len = 0;
}

/// Strip a trailing empty fragment ("#") and return base portion (before '#').
pub fn withoutFragment(uri: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, uri, '#')) |h| return uri[0..h];
    return uri;
}

/// Return the fragment (after '#'), or null if none present.
pub fn fragment(uri: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, uri, '#')) |h| return uri[h + 1 ..];
    return null;
}

/// Percent-decode `s` (for JSON-pointer fragments). Caller owns result.
pub fn percentDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(allocator, hi.? * 16 + lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "resolve relative ref" {
    const a = std.testing.allocator;
    {
        const r = try resolve(a, "http://x/a/b", "c");
        defer a.free(r);
        try std.testing.expectEqualStrings("http://x/a/c", r);
    }
    {
        const r = try resolve(a, "http://x/a/b", "/c/d");
        defer a.free(r);
        try std.testing.expectEqualStrings("http://x/c/d", r);
    }
    {
        const r = try resolve(a, "http://x/a/b", "#/$defs/y");
        defer a.free(r);
        try std.testing.expectEqualStrings("http://x/a/b#/$defs/y", r);
    }
    {
        const r = try resolve(a, "http://x/a/b/", "../e");
        defer a.free(r);
        try std.testing.expectEqualStrings("http://x/a/e", r);
    }
    {
        const r = try resolve(a, "urn:uuid:deadbeef", "#/$defs/y");
        defer a.free(r);
        try std.testing.expectEqualStrings("urn:uuid:deadbeef#/$defs/y", r);
    }
    {
        // Replacing the whole reference with an absolute URI.
        const r = try resolve(a, "http://x/a/b", "https://y/z");
        defer a.free(r);
        try std.testing.expectEqualStrings("https://y/z", r);
    }
    {
        // Nested dot segments collapse.
        const r = try resolve(a, "http://x/a/b/c", "../../g");
        defer a.free(r);
        try std.testing.expectEqualStrings("http://x/g", r);
    }
}

test "removeDotSegments" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "/a/b/c/./../../g", .out = "/a/g" },
        .{ .in = "mid/content=5/../6", .out = "mid/6" },
        .{ .in = "/../g", .out = "/g" },
        .{ .in = "a/./b", .out = "a/b" },
    };
    for (cases) |c| {
        const r = try removeDotSegments(a, c.in);
        defer a.free(r);
        try std.testing.expectEqualStrings(c.out, r);
    }
}

test "fragment helpers and percent decode" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("http://x/a", withoutFragment("http://x/a#/y"));
    try std.testing.expectEqualStrings("http://x/a", withoutFragment("http://x/a"));
    try std.testing.expectEqualStrings("/y", fragment("http://x/a#/y").?);
    try std.testing.expect(fragment("http://x/a") == null);

    const d = try percentDecode(a, "/foo%20bar%2Fbaz");
    defer a.free(d);
    try std.testing.expectEqualStrings("/foo bar/baz", d);
}
