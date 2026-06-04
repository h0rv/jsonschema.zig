//! `format` assertion checks. Returns true (valid) for unrecognized formats,
//! per the spec: unknown formats must not cause validation to fail.
//!
//! ASCII-defined formats (date/time/duration/uri/email/hostname/ip/uuid/pointer)
//! are validated strictly against their RFCs. The internationalized formats
//! (`idn-hostname`, `idn-email`, `iri`, `iri-reference`) require full
//! IDNA2008/Punycode and RFC 3987 machinery; they are validated leniently.

const std = @import("std");
const idna = @import("idna.zig");

pub fn check(name: []const u8, value: []const u8) bool {
    const K = std.StaticStringMap(Fn).initComptime(.{
        .{ "date-time", checkDateTime },
        .{ "date", checkDate },
        .{ "time", checkTime },
        .{ "duration", checkDuration },
        .{ "email", checkEmail },
        .{ "idn-email", checkIdnEmail },
        .{ "hostname", checkHostname },
        .{ "idn-hostname", checkIdnHostname },
        .{ "ipv4", checkIpv4 },
        .{ "ipv6", checkIpv6 },
        .{ "uuid", checkUuid },
        .{ "json-pointer", checkJsonPointer },
        .{ "relative-json-pointer", checkRelativeJsonPointer },
        .{ "uri", checkUri },
        .{ "uri-reference", checkUriReference },
        .{ "iri", checkIri },
        .{ "iri-reference", checkIriReference },
        .{ "uri-template", checkUriTemplate },
        .{ "regex", checkRegex },
    });
    const f = K.get(name) orelse return true;
    return f(value);
}

const Fn = *const fn ([]const u8) bool;

// ---------------- date / time ----------------

fn checkDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    const y = parseDigits(s[0..4]) orelse return false;
    const m = parseDigits(s[5..7]) orelse return false;
    const d = parseDigits(s[8..10]) orelse return false;
    if (m < 1 or m > 12) return false;
    if (d < 1 or d > daysInMonth(y, m)) return false;
    return true;
}

const Time = struct { h: u32, mi: u32, se: u32, off_min: i32, has_offset: bool };

fn parseTime(s: []const u8) ?Time {
    if (s.len < 8) return null;
    if (s[2] != ':' or s[5] != ':') return null;
    const h = parseDigits(s[0..2]) orelse return null;
    const mi = parseDigits(s[3..5]) orelse return null;
    const se = parseDigits(s[6..8]) orelse return null;
    if (h > 23 or mi > 59 or se > 60) return null;

    var rest = s[8..];
    if (rest.len > 0 and rest[0] == '.') {
        rest = rest[1..];
        var n: usize = 0;
        while (n < rest.len and isDigit(rest[n])) n += 1;
        if (n == 0) return null;
        rest = rest[n..];
    }
    if (rest.len == 0) return null; // RFC 3339 requires an offset
    if (rest[0] == 'Z' or rest[0] == 'z') {
        if (rest.len != 1) return null;
        return .{ .h = h, .mi = mi, .se = se, .off_min = 0, .has_offset = true };
    }
    if (rest[0] == '+' or rest[0] == '-') {
        if (rest.len != 6 or rest[3] != ':') return null;
        const oh = parseDigits(rest[1..3]) orelse return null;
        const om = parseDigits(rest[4..6]) orelse return null;
        if (oh > 23 or om > 59) return null;
        const mag: i32 = @intCast(oh * 60 + om);
        return .{ .h = h, .mi = mi, .se = se, .off_min = if (rest[0] == '-') -mag else mag, .has_offset = true };
    }
    return null;
}

fn checkTime(s: []const u8) bool {
    const t = parseTime(s) orelse return false;
    if (t.se == 60) return isLeapSecondInstant(t);
    return true;
}

/// A leap second (`:60`) is only valid at 23:59:60 UTC.
fn isLeapSecondInstant(t: Time) bool {
    const local_min: i32 = @as(i32, @intCast(t.h * 60 + t.mi));
    var utc = @mod(local_min - t.off_min, 1440);
    if (utc < 0) utc += 1440;
    return utc == 23 * 60 + 59;
}

fn checkDateTime(s: []const u8) bool {
    const t = std.mem.indexOfAny(u8, s, "Tt") orelse return false;
    return checkDate(s[0..t]) and checkTime(s[t + 1 ..]);
}

// ---------------- duration (RFC 3339 appendix A) ----------------

fn checkDuration(s: []const u8) bool {
    if (s.len < 2 or s[0] != 'P') return false;
    var rest = s[1..];
    if (rest.len == 0) return false;

    // Week form: nW
    if (std.mem.indexOfScalar(u8, rest, 'W')) |_| {
        const digits = takeDigits(&rest);
        if (digits == 0) return false;
        if (rest.len != 1 or rest[0] != 'W') return false;
        return true;
    }

    var consumed_any = false;
    // Date part: Y? M? D? in order. The RFC 3339 ABNF nests these, so a day may
    // not appear without a month when a year is present (e.g. "P1Y2D").
    var has: [3]bool = .{ false, false, false };
    inline for ([_]u8{ 'Y', 'M', 'D' }, 0..) |unit, idx| {
        if (rest.len > 0 and rest[0] != 'T') {
            const save = rest;
            const n = takeDigits(&rest);
            if (n > 0 and rest.len > 0 and rest[0] == unit) {
                rest = rest[1..];
                consumed_any = true;
                has[idx] = true;
            } else {
                rest = save; // this unit not present
            }
        }
    }
    if (has[0] and has[2] and !has[1]) return false; // year + day without month

    // Optional time part.
    if (rest.len > 0 and rest[0] == 'T') {
        rest = rest[1..];
        var thas: [3]bool = .{ false, false, false };
        inline for ([_]u8{ 'H', 'M', 'S' }, 0..) |unit, idx| {
            if (rest.len > 0) {
                const save = rest;
                const n = takeDigits(&rest);
                if (n > 0 and rest.len > 0 and rest[0] == unit) {
                    rest = rest[1..];
                    thas[idx] = true;
                } else {
                    rest = save;
                }
            }
        }
        if (!(thas[0] or thas[1] or thas[2])) return false; // "T" with no elements
        if (thas[0] and thas[2] and !thas[1]) return false; // hour + second without minute
        consumed_any = true;
    }

    return consumed_any and rest.len == 0;
}

fn takeDigits(rest: *[]const u8) usize {
    var n: usize = 0;
    while (n < rest.*.len and isDigit(rest.*[n])) n += 1;
    rest.* = rest.*[n..];
    return n;
}

// ---------------- email / hostname ----------------

fn checkEmail(s: []const u8) bool {
    const at = std.mem.lastIndexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    if (!checkLocalPart(s[0..at])) return false;
    const host = s[at + 1 ..];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        const lit = host[1 .. host.len - 1];
        if (std.mem.startsWith(u8, lit, "IPv6:")) return checkIpv6(lit[5..]);
        return checkIpv4(lit);
    }
    return checkHostname(host);
}

fn checkIdnEmail(s: []const u8) bool {
    const at = std.mem.lastIndexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    return true; // internationalized local/host parts accepted leniently
}

fn checkLocalPart(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (s[0] == '"' and s[s.len - 1] == '"' and s.len >= 2) return true; // quoted string
    // dot-atom: atoms separated by single dots, no leading/trailing dot.
    if (s[0] == '.' or s[s.len - 1] == '.') return false;
    var prev_dot = false;
    for (s) |c| {
        if (c == '.') {
            if (prev_dot) return false;
            prev_dot = true;
        } else {
            if (!isAtext(c)) return false;
            prev_dot = false;
        }
    }
    return true;
}

fn isAtext(c: u8) bool {
    return isAlnum(c) or switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn checkHostname(s: []const u8) bool {
    return idna.validHostname(s);
}

fn checkIdnHostname(s: []const u8) bool {
    return idna.validIdnHostname(s);
}

// ---------------- ip ----------------

fn checkIpv4(s: []const u8) bool {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        count += 1;
        if (part.len == 0 or part.len > 3) return false;
        if (part.len > 1 and part[0] == '0') return false;
        const v = parseDigits(part) orelse return false;
        if (v > 255) return false;
    }
    return count == 4;
}

fn checkIpv6(s: []const u8) bool {
    if (s.len == 0) return false;
    var groups: usize = 0;
    var double_colon = false;
    var i: usize = 0;

    if (std.mem.startsWith(u8, s, "::")) {
        double_colon = true;
        i = 2;
        if (i == s.len) return true;
    } else if (s[0] == ':') {
        return false;
    }

    while (i < s.len) {
        const start = i;
        var hexlen: usize = 0;
        while (i < s.len and isHex(s[i])) : (i += 1) hexlen += 1;
        if (i < s.len and s[i] == '.') {
            if (!checkIpv4(s[start..])) return false;
            groups += 2;
            i = s.len;
            break;
        }
        if (hexlen == 0 or hexlen > 4) return false;
        groups += 1;
        if (i == s.len) break;
        if (s[i] != ':') return false;
        i += 1;
        if (i < s.len and s[i] == ':') {
            if (double_colon) return false;
            double_colon = true;
            i += 1;
            if (i == s.len) break;
        } else if (i == s.len) {
            return false;
        }
    }

    if (double_colon) return groups <= 7;
    return groups == 8;
}

// ---------------- uuid / pointers ----------------

fn checkUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!isHex(c)) return false;
    }
    return true;
}

fn checkJsonPointer(s: []const u8) bool {
    if (s.len == 0) return true;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '/') return false; // each token must start with '/'
        i += 1;
        while (i < s.len and s[i] != '/') : (i += 1) {
            if (s[i] == '~') {
                if (i + 1 >= s.len or (s[i + 1] != '0' and s[i + 1] != '1')) return false;
                i += 1;
            }
        }
        i -= 1; // outer loop re-increments
    }
    return true;
}

fn checkRelativeJsonPointer(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (!isDigit(s[i])) return false;
    if (s[i] == '0') {
        i += 1;
    } else {
        while (i < s.len and isDigit(s[i])) i += 1;
    }
    if (i == s.len) return true;
    if (s[i] == '#') return i + 1 == s.len;
    return checkJsonPointer(s[i..]);
}

// ---------------- uri / iri ----------------

fn checkUri(s: []const u8) bool {
    return validateUri(s, true, false);
}
fn checkUriReference(s: []const u8) bool {
    return validateUri(s, false, false);
}
fn checkIri(s: []const u8) bool {
    return validateUri(s, true, true);
}
fn checkIriReference(s: []const u8) bool {
    return validateUri(s, false, true);
}

/// Validate a URI (RFC 3986) or IRI reference. `require_scheme` distinguishes
/// absolute URIs from references; `allow_unicode` permits IRI ucschar.
fn validateUri(s: []const u8, require_scheme: bool, allow_unicode: bool) bool {
    if (s.len == 0) return !require_scheme;

    // Split off fragment and query, then scheme and authority, validating the
    // allowed character set and percent-encoding of the rest.
    var rest = s;
    var fragment: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| {
        fragment = rest[h + 1 ..];
        rest = rest[0..h];
    }
    var query: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }

    // scheme
    var has_scheme = false;
    if (schemeEnd(rest)) |c| {
        has_scheme = true;
        rest = rest[c + 1 ..];
    }
    if (require_scheme and !has_scheme) return false;

    // authority
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const end = indexOfAny(after, "/?#") orelse after.len;
        if (!validateAuthority(after[0..end], allow_unicode)) return false;
        rest = after[end..];
    }
    // path
    if (!validateChars(rest, "/:@-._~!$&'()*+,;=%", allow_unicode)) return false;
    if (query) |q| if (!validateChars(q, "/:@-._~!$&'()*+,;=%?", allow_unicode)) return false;
    if (fragment) |f| if (!validateChars(f, "/:@-._~!$&'()*+,;=%?", allow_unicode)) return false;
    return true;
}

fn validateAuthority(auth: []const u8, allow_unicode: bool) bool {
    var host = auth;
    if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| {
        if (!validateChars(auth[0..at], ":-._~!$&'()*+,;=%", allow_unicode)) return false;
        host = auth[at + 1 ..];
    }
    // port
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        // Only treat as port if everything after is digits (avoid IPv6 colons).
        const maybe_port = host[colon + 1 ..];
        var all_digits = maybe_port.len > 0;
        for (maybe_port) |c| {
            if (!isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) host = host[0..colon];
    }
    // IP-literal must be bracketed correctly.
    if (host.len > 0 and host[0] == '[') {
        if (host[host.len - 1] != ']') return false;
        return validateChars(host[1 .. host.len - 1], ":.%abcdefABCDEF0123456789", false);
    }
    if (std.mem.indexOfScalar(u8, host, '[') != null or std.mem.indexOfScalar(u8, host, ']') != null) return false;
    return validateChars(host, "-._~!$&'()*+,;=%", allow_unicode);
}

/// Every char must be unreserved-alnum, in `extra`, or a valid `%HH`. With
/// `allow_unicode`, code points >= 0x80 are also permitted (IRI ucschar).
fn validateChars(s: []const u8, extra: []const u8, allow_unicode: bool) bool {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%') {
            if (i + 2 >= s.len or !isHex(s[i + 1]) or !isHex(s[i + 2])) return false;
            i += 3;
            continue;
        }
        if (isAlnum(c) or std.mem.indexOfScalar(u8, extra, c) != null) {
            i += 1;
            continue;
        }
        if (allow_unicode and c >= 0x80) {
            i += 1;
            continue;
        }
        return false;
    }
    return true;
}

fn checkUriTemplate(s: []const u8) bool {
    // RFC 6570: literals plus { expression } groups. Reject unbalanced braces
    // and disallowed literal characters.
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '{') {
            if (depth != 0) return false;
            depth = 1;
        } else if (c == '}') {
            if (depth != 1) return false;
            depth = 0;
        } else if (depth == 0) {
            if (c == '%') {
                if (i + 2 >= s.len or !isHex(s[i + 1]) or !isHex(s[i + 2])) return false;
                i += 2;
            } else if (c == ' ' or c == '"' or c == '<' or c == '>' or c == '\\' or c == '^' or c == '`' or c == '|') {
                return false;
            }
        }
    }
    return depth == 0;
}

fn checkRegex(s: []const u8) bool {
    const regex = @import("regex.zig");
    var re = regex.compile(std.heap.page_allocator, s, .{}) catch return false;
    re.deinit();
    return true;
}

// ---------------- helpers ----------------

fn schemeEnd(s: []const u8) ?usize {
    if (s.len == 0 or !isAlpha(s[0])) return null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ':') return if (i == 0) null else i;
        if (!(isAlnum(c) or c == '+' or c == '-' or c == '.')) return null;
    }
    return null;
}

fn indexOfAny(s: []const u8, set: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (std.mem.indexOfScalar(u8, set, c) != null) return i;
    }
    return null;
}

fn parseDigits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (!isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysInMonth(y: u32, m: u32) u32 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) @as(u32, 29) else 28,
        else => 0,
    };
}

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}
fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
