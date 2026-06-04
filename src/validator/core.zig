//! Draft 2020-12 JSON Schema validation engine over `std.json.Value`.

const std = @import("std");
const uri = @import("uri.zig");
const jv = @import("jsonval.zig");
const reg = @import("registry.zig");
const regex = @import("regex.zig");
const fmt = @import("format.zig");

const Value = std.json.Value;
const Registry = reg.Registry;

pub const Options = struct {
    /// When true, `format` is an assertion (invalid formats fail validation).
    /// Default false: `format` is annotation-only, per draft 2020-12.
    assert_format: bool = false,
    /// Base URI assigned to the root document if it declares no `$id`.
    default_base_uri: []const u8 = "",
    /// Max schema/instance recursion depth before `error.RecursionLimit`. Guards
    /// against deeply nested instances and pathological `$ref` self-cycles.
    /// 0 disables the limit (risks a native stack overflow on hostile input).
    max_depth: usize = 2000,
    /// Limits for the `pattern`/`patternProperties` regex engine. Each field set
    /// to 0 disables that bound (risks large allocation on hostile patterns).
    regex_limits: regex.Limits = .{},
};

pub const ValidationError = struct {
    /// JSON Pointer to the failing instance location.
    instance_path: []const u8,
    /// Human-readable message.
    message: []const u8,
};

pub const Validator = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    arena: std.mem.Allocator,
    registry: Registry,
    opts: Options,
    root: ?*const Value = null,
    root_base: []const u8 = "",
    /// Compiled-regex cache keyed by pattern text (values owned via gpa).
    regex_cache: std.StringHashMapUnmanaged(*regex.Regex) = .{},

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Validator {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        const arena = arena_state.allocator();
        return .{
            .gpa = gpa,
            .arena_state = arena_state,
            .arena = arena,
            .registry = Registry.init(arena),
            .opts = opts,
        };
    }

    pub fn deinit(self: *Validator) void {
        var it = self.regex_cache.valueIterator();
        while (it.next()) |re| {
            re.*.deinit();
            self.gpa.destroy(re.*);
        }
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
    }

    /// Register an external schema document (for `$ref` to remote URIs).
    pub fn addResource(self: *Validator, retrieval_uri: []const u8, root: *const Value) !void {
        try self.registry.addResource(retrieval_uri, root);
    }

    /// Set the root schema to validate against. Must outlive the validator.
    pub fn setRootSchema(self: *Validator, root: *const Value) !void {
        var base = self.opts.default_base_uri;
        if (root.* == .object) {
            if (root.object.getPtr("$id")) |idv| {
                if (idv.* == .string) {
                    const resolved = try uri.resolve(self.arena, base, idv.string);
                    base = uri.withoutFragment(resolved);
                }
            }
        }
        self.root = root;
        self.root_base = base;
        try self.registry.addResource(self.opts.default_base_uri, root);
    }

    /// Validate `instance`; returns true if valid. Errors are written into
    /// `errors_out` (in the validator arena) when provided.
    pub fn validate(
        self: *Validator,
        instance: *const Value,
        errors_out: ?*std.ArrayListUnmanaged(ValidationError),
    ) !bool {
        var ctx: Ctx = .{
            .v = self,
            .errors = errors_out,
            .path = .empty,
            .vocab = .{ .format_assertion = self.opts.assert_format },
        };
        defer ctx.scope.deinit(self.gpa);
        defer ctx.path.deinit(self.gpa);
        const root = self.root orelse return error.NoRootSchema;
        return self.evalSchema(root, self.root_base, instance, &ctx, null);
    }

    // ---- evaluation context ----

    /// Active vocabularies for the current resource (derived from `$schema`).
    const Vocab = struct {
        validation: bool = true,
        applicator: bool = true,
        unevaluated: bool = true,
        format_assertion: bool = false,
        /// Whether the resource's dialect is draft 2020-12. Older dialects do
        /// not define `prefixItems`, which must then be ignored as unknown.
        dialect_2020: bool = true,
    };

    const Ctx = struct {
        v: *Validator,
        errors: ?*std.ArrayListUnmanaged(ValidationError),
        path: std.ArrayListUnmanaged(u8),
        scope: std.ArrayListUnmanaged([]const u8) = .empty,
        silent: usize = 0,
        depth: usize = 0,
        vocab: Vocab = .{},

        fn fail(self: *Ctx, comptime fmts: []const u8, args: anytype) !void {
            if (self.silent > 0) return;
            const sink = self.errors orelse return;
            const msg = try std.fmt.allocPrint(self.v.arena, fmts, args);
            const p = try self.v.arena.dupe(u8, self.path.items);
            try sink.append(self.v.arena, .{ .instance_path = p, .message = msg });
        }

        /// Append "/<index>" to the instance path; returns the prior length.
        fn enterIndex(self: *Ctx, gpa: std.mem.Allocator, i: usize) !usize {
            const saved = self.path.items.len;
            try self.path.append(gpa, '/');
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            try self.path.appendSlice(gpa, s);
            return saved;
        }

        /// Append "/<key>" (JSON-pointer escaped) to the path; returns prior length.
        fn enterKey(self: *Ctx, gpa: std.mem.Allocator, key: []const u8) !usize {
            const saved = self.path.items.len;
            try self.path.append(gpa, '/');
            for (key) |c| {
                switch (c) {
                    '~' => try self.path.appendSlice(gpa, "~0"),
                    '/' => try self.path.appendSlice(gpa, "~1"),
                    else => try self.path.append(gpa, c),
                }
            }
            return saved;
        }

        fn restore(self: *Ctx, saved: usize) void {
            self.path.items.len = saved;
        }
    };

    /// Tracks which properties/items of the *current* instance were evaluated,
    /// for `unevaluatedProperties`/`unevaluatedItems`.
    const Eval = struct {
        props: std.StringHashMapUnmanaged(void) = .{},
        item_count: usize = 0, // contiguous items evaluated from index 0
        all_items: bool = false,
        sparse: std.AutoHashMapUnmanaged(usize, void) = .{}, // items evaluated by `contains`

        fn markProp(self: *Eval, gpa: std.mem.Allocator, name: []const u8) !void {
            try self.props.put(gpa, name, {});
        }
        fn markItemsUpto(self: *Eval, n: usize) void {
            if (n > self.item_count) self.item_count = n;
        }
        fn markItem(self: *Eval, gpa: std.mem.Allocator, i: usize) !void {
            try self.sparse.put(gpa, i, {});
        }
        fn itemEvaluated(self: *const Eval, i: usize) bool {
            if (self.all_items or i < self.item_count) return true;
            return self.sparse.contains(i);
        }
        fn merge(self: *Eval, gpa: std.mem.Allocator, other: *const Eval) !void {
            if (other.all_items) self.all_items = true;
            if (other.item_count > self.item_count) self.item_count = other.item_count;
            var pit = other.props.keyIterator();
            while (pit.next()) |k| try self.props.put(gpa, k.*, {});
            var sit = other.sparse.keyIterator();
            while (sit.next()) |k| try self.sparse.put(gpa, k.*, {});
        }
        fn deinit(self: *Eval, gpa: std.mem.Allocator) void {
            self.props.deinit(gpa);
            self.sparse.deinit(gpa);
        }
    };

    pub const Error = error{ OutOfMemory, RecursionLimit };

    /// Evaluate `schema` (object or boolean) against `instance`. When `eval` is
    /// non-null, records annotations for the current instance into it.
    fn evalSchema(
        self: *Validator,
        schema: *const Value,
        parent_base: []const u8,
        instance: *const Value,
        ctx: *Ctx,
        eval: ?*Eval,
    ) Error!bool {
        if (self.opts.max_depth != 0 and ctx.depth > self.opts.max_depth) return error.RecursionLimit;
        ctx.depth += 1;
        defer ctx.depth -= 1;

        switch (schema.*) {
            .bool => |b| {
                if (!b) try ctx.fail("schema is false; no value is valid", .{});
                return b;
            },
            .object => {},
            else => return true, // non-schema (shouldn't happen for valid schemas)
        }

        const obj = schema.object;

        // Effective base for this schema. Prefer the canonical base computed at
        // index time (so a node's own `$id` is never resolved twice); fall back
        // to resolving against the parent base for nodes not in the index.
        var base = parent_base;
        if (self.registry.nodeBase(schema)) |b| {
            base = b;
        } else if (obj.getPtr("$id")) |idv| {
            if (idv.* == .string) {
                const resolved = try uri.resolve(self.arena, parent_base, idv.string);
                base = uri.withoutFragment(resolved);
            }
        }
        // Push a dynamic-scope frame when entering a (possibly new) resource.
        const pushed = ctx.scope.items.len == 0 or
            !std.mem.eql(u8, ctx.scope.items[ctx.scope.items.len - 1], base);
        if (pushed) try ctx.scope.append(self.gpa, base);
        defer if (pushed) {
            _ = ctx.scope.pop();
        };

        // A `$schema` declaration (only valid at a resource root) selects the
        // active vocabularies for this subtree.
        const saved_vocab = ctx.vocab;
        defer ctx.vocab = saved_vocab;
        if (obj.getPtr("$schema")) |sv| {
            if (sv.* == .string) ctx.vocab = self.resolveVocab(sv.string);
        }

        var local: Eval = .{};
        defer local.deinit(self.gpa);

        var ok = true;
        ok = try self.applyKeywords(obj, base, instance, ctx, &local) and ok;

        // unevaluatedItems / unevaluatedProperties run last using collected annotations.
        ok = try self.applyUnevaluated(obj, base, instance, ctx, &local) and ok;

        if (eval) |e| try e.merge(self.gpa, &local);
        return ok;
    }

    const vocab_prefix = "https://json-schema.org/draft/2020-12/vocab/";

    /// Determine active vocabularies from a `$schema` metaschema URI. Unknown or
    /// unregistered metaschemas default to the full standard dialect.
    fn resolveVocab(self: *Validator, schema_uri: []const u8) Vocab {
        const is_2020 = std.mem.indexOf(u8, schema_uri, "draft/2020-12") != null;
        const fallback: Vocab = .{ .format_assertion = self.opts.assert_format, .dialect_2020 = is_2020 };

        const meta_node = self.registry.bases.get(uri.withoutFragment(schema_uri)) orelse return fallback;
        if (meta_node.* != .object) return fallback;
        const vocab_obj = meta_node.object.getPtr("$vocabulary") orelse return fallback;
        if (vocab_obj.* != .object) return fallback;

        var v: Vocab = .{
            .validation = false,
            .applicator = false,
            .unevaluated = false,
            .format_assertion = self.opts.assert_format,
            .dialect_2020 = is_2020,
        };
        var it = vocab_obj.object.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (!std.mem.startsWith(u8, key, vocab_prefix)) continue;
            const name = key[vocab_prefix.len..];
            if (std.mem.eql(u8, name, "validation")) v.validation = true;
            if (std.mem.eql(u8, name, "applicator")) v.applicator = true;
            if (std.mem.eql(u8, name, "unevaluated")) v.unevaluated = true;
            // Presence of the format-assertion vocabulary enables assertion; its
            // boolean only signals whether support is required, not enablement.
            if (std.mem.eql(u8, name, "format-assertion")) v.format_assertion = true;
        }
        return v;
    }

    fn applyKeywords(
        self: *Validator,
        obj: jv.Object,
        base: []const u8,
        instance: *const Value,
        ctx: *Ctx,
        local: *Eval,
    ) !bool {
        var ok = true;

        // $ref
        if (obj.getPtr("$ref")) |refv| {
            if (refv.* == .string) {
                ok = try self.applyRef(refv.string, base, instance, ctx, local) and ok;
            }
        }
        // $dynamicRef
        if (obj.getPtr("$dynamicRef")) |drefv| {
            if (drefv.* == .string) {
                ok = try self.applyDynamicRef(drefv.string, base, instance, ctx, local) and ok;
            }
        }

        if (ctx.vocab.validation) {
            ok = try self.applyType(obj, instance, ctx) and ok;
            ok = try self.applyEnumConst(obj, instance, ctx) and ok;
            ok = try self.applyNumeric(obj, instance, ctx) and ok;
            ok = try self.applyString(obj, instance, ctx) and ok;
        }
        ok = try self.applyArray(obj, base, instance, ctx, local) and ok;
        ok = try self.applyObjectKeywords(obj, base, instance, ctx, local) and ok;
        if (ctx.vocab.applicator) {
            ok = try self.applyInPlace(obj, base, instance, ctx, local) and ok;
        }
        ok = try self.applyFormat(obj, instance, ctx) and ok;
        return ok;
    }

    // ---------- references ----------

    fn applyRef(self: *Validator, ref: []const u8, base: []const u8, instance: *const Value, ctx: *Ctx, local: *Eval) !bool {
        const abs = try uri.resolve(self.arena, base, ref);
        const resolved = self.registry.resolveAbsolute(abs) orelse {
            try ctx.fail("cannot resolve $ref '{s}'", .{ref});
            return false;
        };
        var child: Eval = .{};
        defer child.deinit(self.gpa);
        const valid = try self.evalSchema(resolved.schema, resolved.base, instance, ctx, &child);
        if (valid) try local.merge(self.gpa, &child);
        return valid;
    }

    fn applyDynamicRef(self: *Validator, ref: []const u8, base: []const u8, instance: *const Value, ctx: *Ctx, local: *Eval) !bool {
        const abs = try uri.resolve(self.arena, base, ref);
        const resolved = self.registry.resolveAbsolute(abs) orelse {
            try ctx.fail("cannot resolve $dynamicRef '{s}'", .{ref});
            return false;
        };
        var target = resolved.schema;
        var target_base = resolved.base;

        // If the fragment names a $dynamicAnchor present in the resolved
        // resource, re-resolve against the outermost dynamic scope frame that
        // defines that same $dynamicAnchor.
        if (uri.fragment(abs)) |frag| {
            if (frag.len > 0 and frag[0] != '/') {
                if (self.registry.dynamicAnchor(resolved.base, frag) != null) {
                    for (ctx.scope.items) |frame| {
                        if (self.registry.dynamicAnchor(frame, frag)) |node| {
                            target = node;
                            target_base = frame;
                            break;
                        }
                    }
                }
            }
        }
        var child: Eval = .{};
        defer child.deinit(self.gpa);
        const valid = try self.evalSchema(target, target_base, instance, ctx, &child);
        if (valid) try local.merge(self.gpa, &child);
        return valid;
    }

    // ---------- type / enum / const ----------

    fn applyType(self: *Validator, obj: jv.Object, instance: *const Value, ctx: *Ctx) !bool {
        _ = self;
        const tv = obj.getPtr("type") orelse return true;
        switch (tv.*) {
            .string => |name| {
                if (jv.typeMatches(instance, name)) return true;
                try ctx.fail("expected type '{s}'", .{name});
                return false;
            },
            .array => |arr| {
                for (arr.items) |*t| {
                    if (t.* == .string and jv.typeMatches(instance, t.string)) return true;
                }
                try ctx.fail("value does not match any allowed type", .{});
                return false;
            },
            else => return true,
        }
    }

    fn applyEnumConst(self: *Validator, obj: jv.Object, instance: *const Value, ctx: *Ctx) !bool {
        _ = self;
        var ok = true;
        if (obj.getPtr("const")) |cv| {
            if (!jv.equal(instance, cv)) {
                try ctx.fail("value does not equal const", .{});
                ok = false;
            }
        }
        if (obj.getPtr("enum")) |ev| {
            if (ev.* == .array) {
                var found = false;
                for (ev.array.items) |*opt| {
                    if (jv.equal(instance, opt)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try ctx.fail("value not in enum", .{});
                    ok = false;
                }
            }
        }
        return ok;
    }

    // ---------- numeric ----------

    fn applyNumeric(self: *Validator, obj: jv.Object, instance: *const Value, ctx: *Ctx) !bool {
        const num = jv.asNumber(instance) orelse return true;
        var ok = true;
        if (obj.getPtr("multipleOf")) |mv| {
            if (jv.asNumber(mv)) |m| {
                if (m.f > 0) {
                    const multiple = try self.checkMultipleOf(instance, mv, num.f, m.f);
                    if (!multiple) {
                        try ctx.fail("{d} is not a multiple of {d}", .{ num.f, m.f });
                        ok = false;
                    }
                }
            }
        }
        if (boundOf(obj, "maximum")) |m| if (num.f > m.f) {
            try ctx.fail("{d} exceeds maximum {d}", .{ num.f, m.f });
            ok = false;
        };
        if (boundOf(obj, "minimum")) |m| if (num.f < m.f) {
            try ctx.fail("{d} below minimum {d}", .{ num.f, m.f });
            ok = false;
        };
        if (boundOf(obj, "exclusiveMaximum")) |m| if (num.f >= m.f) {
            try ctx.fail("{d} not below exclusiveMaximum {d}", .{ num.f, m.f });
            ok = false;
        };
        if (boundOf(obj, "exclusiveMinimum")) |m| if (num.f <= m.f) {
            try ctx.fail("{d} not above exclusiveMinimum {d}", .{ num.f, m.f });
            ok = false;
        };
        return ok;
    }

    /// `multipleOf` check, using exact big-integer arithmetic when either operand
    /// is a `number_string` (i.e. it overflowed f64), else fast float math.
    fn checkMultipleOf(self: *Validator, instance: *const Value, mv: *const Value, x: f64, d: f64) Error!bool {
        const overflow = !std.math.isFinite(x / d);
        if (instance.* == .number_string or mv.* == .number_string or overflow) {
            var xbuf: [768]u8 = undefined;
            var dbuf: [64]u8 = undefined;
            const x_str = jv.decimalString(&xbuf, instance);
            const d_str = jv.decimalString(&dbuf, mv);
            if (x_str != null and d_str != null) {
                if (jv.multipleOfBig(self.gpa, x_str.?, d_str.?) catch null) |result| {
                    return result;
                }
            }
        }
        return isMultipleOf(x, d);
    }

    // ---------- string ----------

    fn applyString(self: *Validator, obj: jv.Object, instance: *const Value, ctx: *Ctx) !bool {
        if (instance.* != .string) return true;
        const s = instance.string;
        var ok = true;
        if (intOf(obj, "minLength")) |n| if (jv.utf8Len(s) < n) {
            try ctx.fail("string shorter than minLength {d}", .{n});
            ok = false;
        };
        if (intOf(obj, "maxLength")) |n| if (jv.utf8Len(s) > n) {
            try ctx.fail("string longer than maxLength {d}", .{n});
            ok = false;
        };
        if (obj.getPtr("pattern")) |pv| {
            if (pv.* == .string) {
                if (!self.matchPattern(pv.string, s)) {
                    try ctx.fail("string does not match pattern", .{});
                    ok = false;
                }
            }
        }
        return ok;
    }

    fn matchPattern(self: *Validator, pattern: []const u8, s: []const u8) bool {
        const re = self.getRegex(pattern) orelse return true; // invalid regex: don't assert
        return re.matches(s);
    }

    fn getRegex(self: *Validator, pattern: []const u8) ?*regex.Regex {
        if (self.regex_cache.get(pattern)) |re| return re;
        var compiled = regex.compile(self.gpa, pattern, self.opts.regex_limits) catch return null;
        const ptr = self.gpa.create(regex.Regex) catch {
            compiled.deinit();
            return null;
        };
        ptr.* = compiled;
        const key = self.arena.dupe(u8, pattern) catch {
            ptr.deinit();
            self.gpa.destroy(ptr);
            return null;
        };
        self.regex_cache.put(self.arena, key, ptr) catch {
            ptr.deinit();
            self.gpa.destroy(ptr);
            return null;
        };
        return ptr;
    }

    // ---------- arrays ----------

    fn applyArray(self: *Validator, obj: jv.Object, base: []const u8, instance: *const Value, ctx: *Ctx, local: *Eval) !bool {
        if (instance.* != .array) return true;
        const items = instance.array.items;
        var ok = true;

        const app = ctx.vocab.applicator;
        const val = ctx.vocab.validation;

        var prefix_len: usize = 0;
        if (app and ctx.vocab.dialect_2020) if (obj.getPtr("prefixItems")) |pv| {
            if (pv.* == .array) {
                const schemas = pv.array.items;
                prefix_len = @min(schemas.len, items.len);
                for (0..prefix_len) |i| {
                    const saved = try ctx.enterIndex(self.gpa, i);
                    const v = try self.evalSchema(&schemas[i], base, &items[i], ctx, null);
                    ctx.restore(saved);
                    if (!v) ok = false;
                }
                local.markItemsUpto(prefix_len);
            }
        };

        if (app) if (obj.getPtr("items")) |iv| {
            var i = prefix_len;
            while (i < items.len) : (i += 1) {
                const saved = try ctx.enterIndex(self.gpa, i);
                const v = try self.evalSchema(iv, base, &items[i], ctx, null);
                ctx.restore(saved);
                if (!v) ok = false;
            }
            if (items.len >= prefix_len) local.markItemsUpto(items.len);
        };

        // `contains` is an applicator; its min/maxContains thresholds belong to
        // the validation vocabulary.
        if (app) if (obj.getPtr("contains")) |cv| {
            var matches: usize = 0;
            for (items, 0..) |*it, i| {
                ctx.silent += 1;
                const v = try self.evalSchema(cv, base, it, ctx, null);
                ctx.silent -= 1;
                if (v) {
                    matches += 1;
                    try local.markItem(self.gpa, i);
                }
            }
            if (val) {
                const min_contains: usize = if (intOf(obj, "minContains")) |m| @intCast(@max(m, 0)) else 1;
                if (matches < min_contains) {
                    try ctx.fail("array has {d} matching items, need at least {d}", .{ matches, min_contains });
                    ok = false;
                }
                if (intOf(obj, "maxContains")) |m| {
                    if (matches > @as(usize, @intCast(@max(m, 0)))) {
                        try ctx.fail("array has {d} matching items, more than maxContains {d}", .{ matches, m });
                        ok = false;
                    }
                }
            }
        };

        if (val) {
            if (intOf(obj, "minItems")) |n| if (items.len < @as(usize, @intCast(@max(n, 0)))) {
                try ctx.fail("array shorter than minItems {d}", .{n});
                ok = false;
            };
            if (intOf(obj, "maxItems")) |n| if (items.len > @as(usize, @intCast(@max(n, 0)))) {
                try ctx.fail("array longer than maxItems {d}", .{n});
                ok = false;
            };
            if (obj.getPtr("uniqueItems")) |uv| {
                if (uv.* == .bool and uv.bool) {
                    if (!uniqueItems(items)) {
                        try ctx.fail("array items are not unique", .{});
                        ok = false;
                    }
                }
            }
        }
        return ok;
    }

    // ---------- objects ----------

    fn applyObjectKeywords(self: *Validator, obj: jv.Object, base: []const u8, instance: *const Value, ctx: *Ctx, local: *Eval) !bool {
        if (instance.* != .object) return true;
        const inst = instance.object;
        const app = ctx.vocab.applicator;
        const val = ctx.vocab.validation;
        var ok = true;

        if (val) if (obj.getPtr("required")) |rv| {
            if (rv.* == .array) {
                for (rv.array.items) |*name| {
                    if (name.* == .string and !inst.contains(name.string)) {
                        try ctx.fail("missing required property '{s}'", .{name.string});
                        ok = false;
                    }
                }
            }
        };

        if (val) {
            if (intOf(obj, "minProperties")) |n| if (inst.count() < @as(usize, @intCast(@max(n, 0)))) {
                try ctx.fail("object has fewer than minProperties {d}", .{n});
                ok = false;
            };
            if (intOf(obj, "maxProperties")) |n| if (inst.count() > @as(usize, @intCast(@max(n, 0)))) {
                try ctx.fail("object has more than maxProperties {d}", .{n});
                ok = false;
            };

            // dependentRequired (validation vocabulary)
            if (obj.getPtr("dependentRequired")) |dv| {
                if (dv.* == .object) {
                    var it = dv.object.iterator();
                    while (it.next()) |e| {
                        if (!inst.contains(e.key_ptr.*)) continue;
                        if (e.value_ptr.* == .array) {
                            for (e.value_ptr.array.items) |*req| {
                                if (req.* == .string and !inst.contains(req.string)) {
                                    try ctx.fail("property '{s}' requires '{s}'", .{ e.key_ptr.*, req.string });
                                    ok = false;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (!app) {
            // Remaining object keywords are applicator-vocabulary.
            return ok;
        }

        if (obj.getPtr("propertyNames")) |pnv| {
            for (inst.keys()) |key| {
                const saved = try ctx.enterKey(self.gpa, key);
                var keyval: Value = .{ .string = key };
                const v = try self.evalSchema(pnv, base, &keyval, ctx, null);
                ctx.restore(saved);
                if (!v) ok = false;
            }
        }

        // properties
        if (obj.getPtr("properties")) |pv| {
            if (pv.* == .object) {
                var it = pv.object.iterator();
                while (it.next()) |e| {
                    if (inst.getPtr(e.key_ptr.*)) |child| {
                        const saved = try ctx.enterKey(self.gpa, e.key_ptr.*);
                        const v = try self.evalSchema(e.value_ptr, base, child, ctx, null);
                        ctx.restore(saved);
                        if (!v) ok = false;
                        try local.markProp(self.gpa, e.key_ptr.*);
                    }
                }
            }
        }

        // patternProperties
        if (obj.getPtr("patternProperties")) |pv| {
            if (pv.* == .object) {
                var it = pv.object.iterator();
                while (it.next()) |e| {
                    for (inst.keys()) |key| {
                        if (self.matchPattern(e.key_ptr.*, key)) {
                            const child = inst.getPtr(key).?;
                            const saved = try ctx.enterKey(self.gpa, key);
                            const v = try self.evalSchema(e.value_ptr, base, child, ctx, null);
                            ctx.restore(saved);
                            if (!v) ok = false;
                            try local.markProp(self.gpa, key);
                        }
                    }
                }
            }
        }

        // additionalProperties applies to keys not named in this schema's own
        // `properties` and not matched by its own `patternProperties`. It must
        // NOT consult annotations from `$ref`/`allOf`/etc. (that is what
        // `unevaluatedProperties` is for), so check those keywords directly.
        if (obj.getPtr("additionalProperties")) |apv| {
            const props = obj.getPtr("properties");
            const patterns = obj.getPtr("patternProperties");
            for (inst.keys()) |key| {
                if (props) |p| if (p.* == .object and p.object.contains(key)) continue;
                if (patterns) |pp| if (pp.* == .object) {
                    var matched = false;
                    var it = pp.object.iterator();
                    while (it.next()) |e| {
                        if (self.matchPattern(e.key_ptr.*, key)) {
                            matched = true;
                            break;
                        }
                    }
                    if (matched) continue;
                };
                const child = inst.getPtr(key).?;
                const saved = try ctx.enterKey(self.gpa, key);
                const v = try self.evalSchema(apv, base, child, ctx, null);
                ctx.restore(saved);
                if (!v) ok = false;
                try local.markProp(self.gpa, key);
            }
        }

        // dependentSchemas (in-place applicator)
        if (obj.getPtr("dependentSchemas")) |dv| {
            if (dv.* == .object) {
                var it = dv.object.iterator();
                while (it.next()) |e| {
                    if (!inst.contains(e.key_ptr.*)) continue;
                    var child: Eval = .{};
                    defer child.deinit(self.gpa);
                    const v = try self.evalSchema(e.value_ptr, base, instance, ctx, &child);
                    if (v) try local.merge(self.gpa, &child) else ok = false;
                }
            }
        }

        // `dependencies` (draft-07 compatibility): array form behaves like
        // dependentRequired; schema form behaves like dependentSchemas.
        if (obj.getPtr("dependencies")) |dv| {
            if (dv.* == .object) {
                var it = dv.object.iterator();
                while (it.next()) |e| {
                    if (!inst.contains(e.key_ptr.*)) continue;
                    switch (e.value_ptr.*) {
                        .array => |arr| for (arr.items) |*req| {
                            if (req.* == .string and !inst.contains(req.string)) {
                                try ctx.fail("property '{s}' requires '{s}'", .{ e.key_ptr.*, req.string });
                                ok = false;
                            }
                        },
                        .object, .bool => {
                            var child: Eval = .{};
                            defer child.deinit(self.gpa);
                            const v = try self.evalSchema(e.value_ptr, base, instance, ctx, &child);
                            if (v) try local.merge(self.gpa, &child) else ok = false;
                        },
                        else => {},
                    }
                }
            }
        }

        return ok;
    }

    // ---------- in-place applicators ----------

    fn applyInPlace(self: *Validator, obj: jv.Object, base: []const u8, instance: *const Value, ctx: *Ctx, local: *Eval) !bool {
        var ok = true;

        if (obj.getPtr("allOf")) |av| {
            if (av.* == .array) {
                for (av.array.items) |*sub| {
                    var child: Eval = .{};
                    defer child.deinit(self.gpa);
                    const v = try self.evalSchema(sub, base, instance, ctx, &child);
                    if (v) try local.merge(self.gpa, &child) else ok = false;
                }
            }
        }

        if (obj.getPtr("anyOf")) |av| {
            if (av.* == .array) {
                var any = false;
                for (av.array.items) |*sub| {
                    var child: Eval = .{};
                    defer child.deinit(self.gpa);
                    ctx.silent += 1;
                    const v = try self.evalSchema(sub, base, instance, ctx, &child);
                    ctx.silent -= 1;
                    if (v) {
                        any = true;
                        try local.merge(self.gpa, &child);
                    }
                }
                if (!any) {
                    try ctx.fail("value does not match any of anyOf", .{});
                    ok = false;
                }
            }
        }

        if (obj.getPtr("oneOf")) |av| {
            if (av.* == .array) {
                var count: usize = 0;
                var winner: Eval = .{};
                defer winner.deinit(self.gpa);
                for (av.array.items) |*sub| {
                    var child: Eval = .{};
                    defer child.deinit(self.gpa);
                    ctx.silent += 1;
                    const v = try self.evalSchema(sub, base, instance, ctx, &child);
                    ctx.silent -= 1;
                    if (v) {
                        count += 1;
                        if (count == 1) try winner.merge(self.gpa, &child);
                    }
                }
                if (count == 1) {
                    try local.merge(self.gpa, &winner);
                } else {
                    try ctx.fail("value matches {d} of oneOf, need exactly 1", .{count});
                    ok = false;
                }
            }
        }

        if (obj.getPtr("not")) |nv| {
            ctx.silent += 1;
            const v = try self.evalSchema(nv, base, instance, ctx, null);
            ctx.silent -= 1;
            if (v) {
                try ctx.fail("value must not match 'not' schema", .{});
                ok = false;
            }
        }

        if (obj.getPtr("if")) |ifv| {
            var if_eval: Eval = .{};
            defer if_eval.deinit(self.gpa);
            ctx.silent += 1;
            const cond = try self.evalSchema(ifv, base, instance, ctx, &if_eval);
            ctx.silent -= 1;
            if (cond) {
                try local.merge(self.gpa, &if_eval);
                if (obj.getPtr("then")) |tv| {
                    var child: Eval = .{};
                    defer child.deinit(self.gpa);
                    const v = try self.evalSchema(tv, base, instance, ctx, &child);
                    if (v) try local.merge(self.gpa, &child) else ok = false;
                }
            } else {
                if (obj.getPtr("else")) |ev| {
                    var child: Eval = .{};
                    defer child.deinit(self.gpa);
                    const v = try self.evalSchema(ev, base, instance, ctx, &child);
                    if (v) try local.merge(self.gpa, &child) else ok = false;
                }
            }
        }

        return ok;
    }

    // ---------- unevaluated ----------

    fn applyUnevaluated(self: *Validator, obj: jv.Object, base: []const u8, instance: *const Value, ctx: *Ctx, local: *Eval) !bool {
        if (!ctx.vocab.unevaluated) return true;
        var ok = true;

        if (obj.getPtr("unevaluatedItems")) |uv| {
            if (instance.* == .array) {
                const items = instance.array.items;
                for (items, 0..) |*it, i| {
                    if (local.itemEvaluated(i)) continue;
                    const saved = try ctx.enterIndex(self.gpa, i);
                    const v = try self.evalSchema(uv, base, it, ctx, null);
                    ctx.restore(saved);
                    if (!v) ok = false;
                }
                if (items.len > 0) local.all_items = true;
            }
        }

        if (obj.getPtr("unevaluatedProperties")) |uv| {
            if (instance.* == .object) {
                const inst = instance.object;
                for (inst.keys()) |key| {
                    if (local.props.contains(key)) continue;
                    const child = inst.getPtr(key).?;
                    const saved = try ctx.enterKey(self.gpa, key);
                    const v = try self.evalSchema(uv, base, child, ctx, null);
                    ctx.restore(saved);
                    if (!v) ok = false;
                    try local.markProp(self.gpa, key);
                }
            }
        }

        return ok;
    }

    // ---------- format ----------

    fn applyFormat(self: *Validator, obj: jv.Object, instance: *const Value, ctx: *Ctx) !bool {
        _ = self;
        if (!ctx.vocab.format_assertion) return true;
        const fv = obj.getPtr("format") orelse return true;
        if (fv.* != .string) return true;
        if (instance.* != .string) return true; // format only applies to strings here
        if (fmt.check(fv.string, instance.string)) return true;
        try ctx.fail("string does not match format '{s}'", .{fv.string});
        return false;
    }
};

// ---------- helpers ----------

fn boundOf(obj: jv.Object, key: []const u8) ?jv.Num {
    const v = obj.getPtr(key) orelse return null;
    return jv.asNumber(v);
}

fn intOf(obj: jv.Object, key: []const u8) ?i64 {
    const v = obj.getPtr(key) orelse return null;
    const n = jv.asNumber(v) orelse return null;
    // Saturating cast: a float threshold outside i64 range (e.g. `minItems:1e30`)
    // must clamp, not panic via `@intFromFloat`.
    return n.int orelse std.math.lossyCast(i64, n.f);
}

fn isMultipleOf(x: f64, d: f64) bool {
    if (d == 0) return false;
    const q = x / d;
    const r = q - @round(q);
    const scale = @max(@abs(q), 1.0);
    return @abs(r) <= 1e-9 * scale;
}

fn uniqueItems(items: []const Value) bool {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (jv.equal(&items[i], &items[j])) return false;
        }
    }
    return true;
}
