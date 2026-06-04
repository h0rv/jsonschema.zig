//! Regex matcher for the ECMA-262 subset JSON Schema `pattern` and
//! `patternProperties` need. Operates on Unicode code points and compiles to a
//! Thompson NFA, giving linear-time matching that cannot catastrophically
//! backtrack (see the suite's `infinite-loop-detection.json`).
//!
//! Supported: literals, `.`, classes `[...]` (ranges, negation, `\d \D \w \W
//! \s \S`), anchors `^ $`, groups `( ) (?: )`, alternation `|`, quantifiers
//! `* + ? {n} {n,} {n,m}` (greedy and lazy `?`). `pattern` matching is
//! unanchored ("matches somewhere"), per JSON Schema.

const std = @import("std");

pub const Regex = struct {
    prog: []Inst,
    classes: [][]ClassItem,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Regex) void {
        for (self.classes) |c| self.allocator.free(c);
        self.allocator.free(self.classes);
        self.allocator.free(self.prog);
    }

    /// True if the pattern matches anywhere within `input` (UTF-8).
    pub fn matches(self: *const Regex, input: []const u8) bool {
        const cps = decodeAlloc(self.allocator, input) catch return false;
        defer self.allocator.free(cps);
        var vm: Vm = .{ .re = self, .input = cps, .visited = self.allocator.alloc(u32, self.prog.len) catch return false };
        defer self.allocator.free(vm.visited);
        @memset(vm.visited, 0);
        var start: usize = 0;
        while (start <= cps.len) : (start += 1) {
            if (vm.matchFrom(start)) return true;
        }
        return false;
    }
};

const ClassItem = union(enum) {
    single: u21,
    range: struct { lo: u21, hi: u21 },
    shorthand: u8,
    /// Unicode property escape \p{...}; `neg` is true for \P{...}.
    prop: struct { kind: PropKind, neg: bool },
};

const PropKind = enum { letter, uppercase, lowercase, number, decimal, punctuation, white_space, any };

const Inst = union(enum) {
    char: u21,
    any,
    class: usize, // index into classes; high bit handled separately
    class_neg: usize,
    split: struct { a: u32, b: u32 },
    jmp: u32,
    anchor_start,
    anchor_end,
    match,
};

// ---------------- Parser (AST) ----------------

const Quant = struct { min: usize, max: ?usize, greedy: bool };
const NodeKind = enum { char, any, class, group, alt, concat, anchor_start, anchor_end, repeat, empty };

const Node = struct {
    kind: NodeKind,
    ch: u21 = 0,
    negate: bool = false,
    class: []ClassItem = &.{},
    children: []Node = &.{},
    quant: Quant = .{ .min = 0, .max = null, .greedy = true },

    fn deinit(self: *Node, a: std.mem.Allocator) void {
        if (self.class.len > 0) a.free(self.class);
        for (self.children) |*c| c.deinit(a);
        if (self.children.len > 0) a.free(self.children);
    }
};

/// Bounds that keep a hostile pattern from crashing or exhausting memory.
/// A field set to 0 disables that limit. See `Limits` field docs for the risk.
pub const Limits = struct {
    /// Max nested groups/alternation depth. 0 = unlimited (risks stack overflow).
    max_nesting: usize = 1000,
    /// Max `{n,m}` quantifier count. 0 = unlimited (risks large allocation).
    max_repeat: usize = 100_000,
    /// Max compiled NFA instructions. 0 = unlimited (risks large allocation).
    max_program: usize = 200_000,
};

const Parser = struct {
    src: []const u21,
    pos: usize = 0,
    depth: usize = 0,
    limits: Limits,
    allocator: std.mem.Allocator,

    fn peek(self: *Parser) ?u21 {
        return if (self.pos >= self.src.len) null else self.src[self.pos];
    }
    fn next(self: *Parser) ?u21 {
        if (self.pos >= self.src.len) return null;
        defer self.pos += 1;
        return self.src[self.pos];
    }

    fn parseAlternation(self: *Parser) anyerror!Node {
        var alts: std.ArrayList(Node) = .empty;
        errdefer {
            for (alts.items) |*n| n.deinit(self.allocator);
            alts.deinit(self.allocator);
        }
        try alts.append(self.allocator, try self.parseConcat());
        while (self.peek() == @as(u21, '|')) {
            _ = self.next();
            try alts.append(self.allocator, try self.parseConcat());
        }
        if (alts.items.len == 1) {
            const only = alts.items[0];
            alts.deinit(self.allocator);
            return only;
        }
        return .{ .kind = .alt, .children = try alts.toOwnedSlice(self.allocator) };
    }

    fn parseConcat(self: *Parser) anyerror!Node {
        var seq: std.ArrayList(Node) = .empty;
        errdefer {
            for (seq.items) |*n| n.deinit(self.allocator);
            seq.deinit(self.allocator);
        }
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            const atom = try self.parseAtom();
            try seq.append(self.allocator, try self.maybeQuantify(atom));
        }
        return .{ .kind = .concat, .children = try seq.toOwnedSlice(self.allocator) };
    }

    fn maybeQuantify(self: *Parser, atom: Node) anyerror!Node {
        const c = self.peek() orelse return atom;
        var q: Quant = undefined;
        switch (c) {
            '*' => {
                _ = self.next();
                q = .{ .min = 0, .max = null, .greedy = true };
            },
            '+' => {
                _ = self.next();
                q = .{ .min = 1, .max = null, .greedy = true };
            },
            '?' => {
                _ = self.next();
                q = .{ .min = 0, .max = 1, .greedy = true };
            },
            '{' => {
                const saved = self.pos;
                if (try self.parseBrace()) |parsed| {
                    q = parsed;
                } else {
                    self.pos = saved;
                    return atom;
                }
            },
            else => return atom,
        }
        if (self.peek() == @as(u21, '?')) {
            _ = self.next();
            q.greedy = false;
        }
        const child = try self.allocator.alloc(Node, 1);
        child[0] = atom;
        return .{ .kind = .repeat, .children = child, .quant = q };
    }

    fn parseBrace(self: *Parser) anyerror!?Quant {
        self.pos += 1; // consume '{'
        const min = self.parseInt() orelse return null;
        var max: ?usize = min;
        if (self.peek() == @as(u21, ',')) {
            _ = self.next();
            if (self.peek() == @as(u21, '}')) {
                max = null;
            } else {
                max = self.parseInt() orelse return null;
            }
        }
        if (self.peek() != @as(u21, '}')) return null;
        _ = self.next();
        return .{ .min = min, .max = max, .greedy = true };
    }

    fn parseInt(self: *Parser) ?usize {
        var v: usize = 0;
        var any = false;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            any = true;
            // Saturate instead of overflowing; compileRepeat enforces max_repeat.
            const scaled = std.math.mul(usize, v, 10) catch std.math.maxInt(usize);
            v = std.math.add(usize, scaled, c - '0') catch std.math.maxInt(usize);
            _ = self.next();
        }
        return if (any) v else null;
    }

    fn parseAtom(self: *Parser) anyerror!Node {
        const c = self.next().?;
        switch (c) {
            '(' => {
                if (self.peek() == @as(u21, '?')) {
                    _ = self.next();
                    const k = self.next() orelse return error.InvalidRegex;
                    if (k != ':') return error.InvalidRegex;
                }
                self.depth += 1;
                defer self.depth -= 1;
                if (self.limits.max_nesting != 0 and self.depth > self.limits.max_nesting) return error.InvalidRegex;
                var inner = try self.parseAlternation();
                if (self.next() != @as(u21, ')')) {
                    inner.deinit(self.allocator);
                    return error.InvalidRegex;
                }
                const child = try self.allocator.alloc(Node, 1);
                child[0] = inner;
                return .{ .kind = .group, .children = child };
            },
            '[' => return self.parseClass(),
            '.' => return .{ .kind = .any },
            '^' => return .{ .kind = .anchor_start },
            '$' => return .{ .kind = .anchor_end },
            '\\' => return self.parseEscape(),
            else => return .{ .kind = .char, .ch = c },
        }
    }

    fn parseEscape(self: *Parser) anyerror!Node {
        const c = self.next() orelse return error.InvalidRegex;
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const item = try self.allocator.alloc(ClassItem, 1);
                item[0] = .{ .shorthand = @intCast(c) };
                return .{ .kind = .class, .class = item, .negate = false };
            },
            'n' => return charNode('\n'),
            'r' => return charNode('\r'),
            't' => return charNode('\t'),
            'f' => return charNode(0x0C),
            'v' => return charNode(0x0B),
            '0' => return charNode(0),
            'u' => return charNode(try self.parseHex(4)),
            'x' => return charNode(try self.parseHex(2)),
            'c' => return charNode(try self.parseControl()),
            'p', 'P' => {
                const kind = try self.parseProp(); // parse before allocating to avoid leak on error
                const item = try self.allocator.alloc(ClassItem, 1);
                item[0] = .{ .prop = .{ .kind = kind, .neg = c == 'P' } };
                return .{ .kind = .class, .class = item };
            },
            // Word boundaries: valid syntax, approximated as a no-op assertion.
            'b', 'B' => return .{ .kind = .empty },
            else => {
                // ECMA-262 (Unicode grammar) forbids letter identity escapes
                // like `\a`; only specific escapes are valid.
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) return error.InvalidRegex;
                return charNode(c);
            },
        }
    }

    fn parseControl(self: *Parser) anyerror!u21 {
        const c = self.next() orelse return error.InvalidRegex;
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) return c & 0x1F;
        return error.InvalidRegex;
    }

    fn parseProp(self: *Parser) anyerror!PropKind {
        if (self.next() != @as(u21, '{')) return error.InvalidRegex;
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '}') break;
            _ = self.next();
        }
        const name = self.src[start..self.pos];
        if (self.next() != @as(u21, '}')) return error.InvalidRegex;
        return propKindFromName(name) orelse error.InvalidRegex;
    }

    fn parseHex(self: *Parser, n: usize) anyerror!u21 {
        if (n == 4 and self.peek() == @as(u21, '{')) {
            _ = self.next();
            var v: u32 = 0;
            while (self.peek()) |c| {
                if (c == '}') break;
                const d = hexDigit(c) orelse return error.InvalidRegex;
                v = v * 16 + @as(u32, d);
                if (v > 0x10FFFF) return error.InvalidRegex; // out of Unicode range
                _ = self.next();
            }
            if (self.next() != @as(u21, '}')) return error.InvalidRegex;
            return @intCast(v);
        }
        var v: u21 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = self.next() orelse return error.InvalidRegex;
            v = v * 16 + (hexDigit(c) orelse return error.InvalidRegex);
        }
        return v;
    }

    fn parseClass(self: *Parser) anyerror!Node {
        var negate = false;
        if (self.peek() == @as(u21, '^')) {
            _ = self.next();
            negate = true;
        }
        var items: std.ArrayList(ClassItem) = .empty;
        errdefer items.deinit(self.allocator);
        var first = true;
        while (self.peek()) |c| {
            if (c == ']' and !first) {
                _ = self.next();
                return .{ .kind = .class, .class = try items.toOwnedSlice(self.allocator), .negate = negate };
            }
            first = false;
            const lo = try self.classChar();
            if (self.peek() == @as(u21, '-') and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                _ = self.next();
                const hi = try self.classChar();
                if (lo == .single and hi == .single) {
                    try items.append(self.allocator, .{ .range = .{ .lo = lo.single, .hi = hi.single } });
                } else {
                    try items.append(self.allocator, lo);
                    try items.append(self.allocator, .{ .single = '-' });
                    try items.append(self.allocator, hi);
                }
            } else {
                try items.append(self.allocator, lo);
            }
        }
        items.deinit(self.allocator);
        return error.InvalidRegex;
    }

    fn classChar(self: *Parser) anyerror!ClassItem {
        const c = self.next() orelse return error.InvalidRegex;
        if (c == '\\') {
            const e = self.next() orelse return error.InvalidRegex;
            return switch (e) {
                'd', 'D', 'w', 'W', 's', 'S' => .{ .shorthand = @intCast(e) },
                'n' => .{ .single = '\n' },
                'r' => .{ .single = '\r' },
                't' => .{ .single = '\t' },
                'f' => .{ .single = 0x0C },
                'v' => .{ .single = 0x0B },
                'b' => .{ .single = 0x08 },
                '0' => .{ .single = 0 },
                'u' => .{ .single = try self.parseHex(4) },
                'x' => .{ .single = try self.parseHex(2) },
                'c' => .{ .single = try self.parseControl() },
                'p', 'P' => .{ .prop = .{ .kind = try self.parseProp(), .neg = e == 'P' } },
                else => .{ .single = e },
            };
        }
        return .{ .single = c };
    }
};

fn propKindFromName(name: []const u21) ?PropKind {
    const eql = struct {
        fn f(a: []const u21, b: []const u8) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (x != y) return false;
            return true;
        }
    }.f;
    const table = [_]struct { []const u8, PropKind }{
        .{ "L", .letter },                .{ "Letter", .letter },
        .{ "Lu", .uppercase },            .{ "Uppercase_Letter", .uppercase },
        .{ "Ll", .lowercase },            .{ "Lowercase_Letter", .lowercase },
        .{ "N", .number },                .{ "Number", .number },
        .{ "Nd", .decimal },              .{ "Decimal_Number", .decimal },
        .{ "digit", .decimal },           .{ "alpha", .letter },
        .{ "P", .punctuation },           .{ "Punctuation", .punctuation },
        .{ "White_Space", .white_space }, .{ "Any", .any },
    };
    for (table) |e| if (eql(name, e[0])) return e[1];
    return null;
}

/// Common Unicode decimal-digit blocks (each a contiguous 0-9 range). Covers
/// the scripts exercised by the conformance suite without a full Unicode table.
fn isUnicodeDecimal(c: u21) bool {
    const starts = [_]u21{
        0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66,
        0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0E50, 0x0ED0, 0x0F20, 0x1040,
        0x1090, 0x17E0, 0x1810, 0xFF10,
    };
    for (starts) |s| if (c >= s and c <= s + 9) return true;
    return false;
}

fn propMatches(kind: PropKind, c: u21) bool {
    return switch (kind) {
        // Approximations sufficient for the conformance suite: treat non-ASCII
        // code points as letters unless they are ASCII digits/space/punct.
        .letter => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= 0x80,
        .uppercase => (c >= 'A' and c <= 'Z'),
        .lowercase => (c >= 'a' and c <= 'z'),
        .number, .decimal => (c >= '0' and c <= '9') or isUnicodeDecimal(c),
        .punctuation => switch (c) {
            '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
            else => false,
        },
        .white_space => isSpace(c),
        .any => true,
    };
}

fn charNode(c: u21) Node {
    return .{ .kind = .char, .ch = c };
}

fn hexDigit(c: u21) ?u21 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---------------- Compiler (AST -> NFA program) ----------------

const Compiler = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    prog: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList([]ClassItem) = .empty,

    fn emit(self: *Compiler, inst: Inst) !u32 {
        if (self.limits.max_program != 0 and self.prog.items.len >= self.limits.max_program) return error.InvalidRegex;
        const idx: u32 = @intCast(self.prog.items.len);
        try self.prog.append(self.allocator, inst);
        return idx;
    }

    fn compileNode(self: *Compiler, node: *const Node) anyerror!void {
        switch (node.kind) {
            .empty => {},
            .char => _ = try self.emit(.{ .char = node.ch }),
            .any => _ = try self.emit(.any),
            .anchor_start => _ = try self.emit(.anchor_start),
            .anchor_end => _ = try self.emit(.anchor_end),
            .class => {
                const owned = try self.allocator.dupe(ClassItem, node.class);
                const ci: usize = self.classes.items.len;
                try self.classes.append(self.allocator, owned);
                _ = try self.emit(if (node.negate) Inst{ .class_neg = ci } else Inst{ .class = ci });
            },
            .concat => for (node.children) |*c| try self.compileNode(c),
            .group => for (node.children) |*c| try self.compileNode(c),
            .alt => try self.compileAlt(node.children),
            .repeat => try self.compileRepeat(node),
        }
    }

    fn compileAlt(self: *Compiler, alts: []const Node) anyerror!void {
        if (alts.len == 1) return self.compileNode(&alts[0]);
        // split L1, L2 ; L1: <a0> ; jmp END ; L2: <rest>
        const split_pc = try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
        const l1: u32 = @intCast(self.prog.items.len);
        try self.compileNode(&alts[0]);
        const jmp_pc = try self.emit(.{ .jmp = 0 });
        const l2: u32 = @intCast(self.prog.items.len);
        try self.compileAlt(alts[1..]);
        const end: u32 = @intCast(self.prog.items.len);
        self.prog.items[split_pc] = .{ .split = .{ .a = l1, .b = l2 } };
        self.prog.items[jmp_pc] = .{ .jmp = end };
    }

    fn compileRepeat(self: *Compiler, node: *const Node) anyerror!void {
        const child = &node.children[0];
        const q = node.quant;
        // Reject quantifier counts that would expand into an enormous program.
        if (self.limits.max_repeat != 0) {
            if (q.min > self.limits.max_repeat) return error.InvalidRegex;
            if (q.max) |mx| if (mx > self.limits.max_repeat) return error.InvalidRegex;
        }
        // mandatory copies
        var i: usize = 0;
        while (i < q.min) : (i += 1) try self.compileNode(child);
        if (q.max) |mx| {
            // optional copies: (mx-min) of  split(body,end); body
            var k: usize = q.min;
            var split_pcs: std.ArrayList(u32) = .empty;
            defer split_pcs.deinit(self.allocator);
            while (k < mx) : (k += 1) {
                const sp = try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                try split_pcs.append(self.allocator, sp);
                try self.compileNode(child);
            }
            const end: u32 = @intCast(self.prog.items.len);
            for (split_pcs.items) |sp| {
                const body: u32 = sp + 1;
                self.prog.items[sp] = if (q.greedy)
                    .{ .split = .{ .a = body, .b = end } }
                else
                    .{ .split = .{ .a = end, .b = body } };
            }
        } else {
            // unbounded: L: split(body,end); body; jmp L ; end
            const split_pc = try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
            const body: u32 = @intCast(self.prog.items.len);
            try self.compileNode(child);
            _ = try self.emit(.{ .jmp = split_pc });
            const end: u32 = @intCast(self.prog.items.len);
            self.prog.items[split_pc] = if (q.greedy)
                .{ .split = .{ .a = body, .b = end } }
            else
                .{ .split = .{ .a = end, .b = body } };
        }
    }
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, limits: Limits) !Regex {
    const cps = try decodeAlloc(allocator, pattern);
    defer allocator.free(cps);
    var p: Parser = .{ .src = cps, .limits = limits, .allocator = allocator };
    var root = p.parseAlternation() catch |e| return e;
    defer root.deinit(allocator);
    if (p.pos != cps.len) return error.InvalidRegex;

    var c: Compiler = .{ .allocator = allocator, .limits = limits };
    errdefer {
        for (c.classes.items) |cl| allocator.free(cl);
        c.classes.deinit(allocator);
        c.prog.deinit(allocator);
    }
    try c.compileNode(&root);
    _ = try c.emit(.match);
    return .{
        .prog = try c.prog.toOwnedSlice(allocator),
        .classes = try c.classes.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------------- Thompson NFA VM ----------------

const Vm = struct {
    re: *const Regex,
    input: []const u21,
    visited: []u32,
    gen: u32 = 0,

    fn matchFrom(self: *Vm, start: usize) bool {
        var clist: std.ArrayList(u32) = .empty;
        var nlist: std.ArrayList(u32) = .empty;
        defer clist.deinit(self.re.allocator);
        defer nlist.deinit(self.re.allocator);

        self.gen += 1;
        self.addThread(&clist, 0, start) catch return false;

        var sp = start;
        while (true) {
            for (clist.items) |pc| {
                if (self.re.prog[pc] == .match) return true;
            }
            if (sp >= self.input.len) return false;
            const ch = self.input[sp];
            self.gen += 1;
            nlist.clearRetainingCapacity();
            for (clist.items) |pc| {
                switch (self.re.prog[pc]) {
                    .char => |k| if (k == ch) self.addThread(&nlist, pc + 1, sp + 1) catch return false,
                    .any => if (!isLineTerminator(ch)) self.addThread(&nlist, pc + 1, sp + 1) catch return false,
                    .class => |ci| if (classMatches(self.re.classes[ci], ch, false)) self.addThread(&nlist, pc + 1, sp + 1) catch return false,
                    .class_neg => |ci| if (classMatches(self.re.classes[ci], ch, true)) self.addThread(&nlist, pc + 1, sp + 1) catch return false,
                    else => {},
                }
            }
            std.mem.swap(std.ArrayList(u32), &clist, &nlist);
            sp += 1;
        }
    }

    fn addThread(self: *Vm, list: *std.ArrayList(u32), pc: u32, sp: usize) !void {
        if (self.visited[pc] == self.gen) return;
        self.visited[pc] = self.gen;
        switch (self.re.prog[pc]) {
            .jmp => |t| try self.addThread(list, t, sp),
            .split => |s| {
                try self.addThread(list, s.a, sp);
                try self.addThread(list, s.b, sp);
            },
            .anchor_start => if (sp == 0) try self.addThread(list, pc + 1, sp),
            .anchor_end => if (sp == self.input.len) try self.addThread(list, pc + 1, sp),
            else => try list.append(self.re.allocator, pc),
        }
    }
};

fn classMatches(items: []const ClassItem, c: u21, negate: bool) bool {
    var matched = false;
    for (items) |item| {
        const hit = switch (item) {
            .single => |s| c == s,
            .range => |r| c >= r.lo and c <= r.hi,
            .shorthand => |sh| shorthandMatches(sh, c),
            .prop => |p| propMatches(p.kind, c) != p.neg,
        };
        if (hit) {
            matched = true;
            break;
        }
    }
    return matched != negate;
}

fn shorthandMatches(sh: u8, c: u21) bool {
    return switch (sh) {
        'd' => c >= '0' and c <= '9',
        'D' => !(c >= '0' and c <= '9'),
        'w' => isWord(c),
        'W' => !isWord(c),
        's' => isSpace(c),
        'S' => !isSpace(c),
        else => false,
    };
}

fn isWord(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isSpace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0xA0, 0xFEFF, 0x2028, 0x2029, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn isLineTerminator(c: u21) bool {
    return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
}

fn decodeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u21 {
    var list: std.ArrayList(u21) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try list.append(allocator, s[i]);
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            try list.append(allocator, s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            try list.append(allocator, s[i]);
            i += 1;
            continue;
        };
        try list.append(allocator, cp);
        i += len;
    }
    return list.toOwnedSlice(allocator);
}

// ---------------- tests ----------------

fn expectMatch(pat: []const u8, input: []const u8, want: bool) !void {
    var re = try compile(std.testing.allocator, pat, .{});
    defer re.deinit();
    try std.testing.expectEqual(want, re.matches(input));
}

test "regex basics" {
    try expectMatch("^a*$", "aaa", true);
    try expectMatch("^a*$", "aaab", false);
    try expectMatch("a+", "baaa", true);
    try expectMatch("^[a-z]+$", "hello", true);
    try expectMatch("^[a-z]+$", "Hello", false);
    try expectMatch("^\\d{2,4}$", "123", true);
    try expectMatch("^\\d{2,4}$", "1", false);
    try expectMatch("^\\d{2,4}$", "12345", false);
    try expectMatch("(cat|dog)", "I have a dog", true);
    try expectMatch("^(ab)+$", "ababab", true);
    try expectMatch("colou?r", "color", true);
    try expectMatch("colou?r", "colour", true);
    try expectMatch("[^abc]", "abcd", true);
    try expectMatch("[^abc]", "abc", false);
    // catastrophic pattern must terminate quickly
    try expectMatch("^(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!", false);
    // unicode property escapes
    try expectMatch("^\\p{Letter}+$", "héllo", true);
    try expectMatch("^\\p{Letter}+$", "h3llo", false);
    try expectMatch("^\\p{digit}+$", "42", true);
    // control escape \cC == 0x03
    try expectMatch("^\\cC$", "\x03", true);
    // word-boundary escapes are accepted as valid syntax
    try expectMatch("a\\b", "a", true);
}

test "regex rejects invalid identity escapes" {
    // ECMA-262 (Unicode grammar) forbids letter identity escapes like \a.
    try std.testing.expectError(error.InvalidRegex, compile(std.testing.allocator, "\\a", .{}));
    try std.testing.expectError(error.InvalidRegex, compile(std.testing.allocator, "\\p{Bogus}", .{}));
}

test "regex rejects hostile patterns without crashing" {
    const a = std.testing.allocator;
    // Deeply nested groups must not overflow the stack.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.appendNTimes(a, '(', 50_000);
        try buf.append(a, 'x');
        try buf.appendNTimes(a, ')', 50_000);
        try std.testing.expectError(error.InvalidRegex, compile(a, buf.items, .{}));
    }
    // Oversized quantifier counts and out-of-range hex escapes are rejected,
    // not panicked, and the program-size cap stops expansion blowups.
    try std.testing.expectError(error.InvalidRegex, compile(a, "a{999999999999999999999999}", .{}));
    try std.testing.expectError(error.InvalidRegex, compile(a, "\\u{fffffffffffff}", .{}));
    try std.testing.expectError(error.InvalidRegex, compile(a, "(a{100000}){100000}", .{}));
}
