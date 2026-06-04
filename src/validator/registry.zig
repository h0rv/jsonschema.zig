//! Resource registry: indexes schema documents by base URI, records `$anchor`
//! and `$dynamicAnchor` locations, and resolves `$ref`/`$dynamicRef` targets.

const std = @import("std");
const uri = @import("uri.zig");
const Value = std.json.Value;

pub const Resolved = struct {
    schema: *const Value,
    base: []const u8,
};

pub const Registry = struct {
    arena: std.mem.Allocator,
    /// Absolute base URI (no fragment) -> schema node that declared it.
    bases: std.StringHashMapUnmanaged(*const Value) = .{},
    /// "base#anchorName" -> schema node.
    anchors: std.StringHashMapUnmanaged(*const Value) = .{},
    /// "base#anchorName" -> schema node for $dynamicAnchor.
    dynamic_anchors: std.StringHashMapUnmanaged(*const Value) = .{},
    /// base#anchorName -> owning resource base, for $dynamicRef scope checks.
    dynamic_anchor_bases: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Schema node identity -> its canonical base URI (with `$id` applied),
    /// precomputed so evaluation never re-resolves a node's own `$id`.
    node_bases: std.AutoHashMapUnmanaged(*const Value, []const u8) = .{},

    pub fn init(arena: std.mem.Allocator) Registry {
        return .{ .arena = arena };
    }

    /// Index a document `root` retrievable at `retrieval_uri`. The canonical base
    /// is the root `$id` (resolved against the retrieval URI) if present.
    pub fn addResource(self: *Registry, retrieval_uri: []const u8, root: *const Value) !void {
        var base = retrieval_uri;
        if (root.* == .object) {
            if (root.object.getPtr("$id")) |idv| {
                if (idv.* == .string) {
                    const resolved = try uri.resolve(self.arena, retrieval_uri, idv.string);
                    base = uri.withoutFragment(resolved);
                }
            }
        }
        // Register the retrieval URI too, so refs to it resolve.
        try self.bases.put(self.arena, retrieval_uri, root);
        try self.index(root, base);
    }

    /// Walk `node` registering $id bases, anchors, and dynamic anchors. Only
    /// descends through schema-valued keyword positions so identifiers inside
    /// `const`/`enum`/`default` are not mistaken for real ones.
    fn index(self: *Registry, node: *const Value, parent_base: []const u8) std.mem.Allocator.Error!void {
        if (node.* != .object) {
            // boolean schema or non-schema; nothing to index, but arrays of
            // schemas are handled by the caller via subschema descent below.
            return;
        }
        const obj = node.object;
        var base = parent_base;
        if (obj.getPtr("$id")) |idv| {
            if (idv.* == .string) {
                const resolved = try uri.resolve(self.arena, parent_base, idv.string);
                base = uri.withoutFragment(resolved);
                try self.bases.put(self.arena, base, node);
            }
        }
        try self.node_bases.put(self.arena, node, base);

        if (obj.getPtr("$anchor")) |av| {
            if (av.* == .string) {
                const key = try std.mem.concat(self.arena, u8, &.{ base, "#", av.string });
                try self.anchors.put(self.arena, key, node);
            }
        }
        if (obj.getPtr("$dynamicAnchor")) |av| {
            if (av.* == .string) {
                const key = try std.mem.concat(self.arena, u8, &.{ base, "#", av.string });
                try self.dynamic_anchors.put(self.arena, key, node);
                try self.dynamic_anchor_bases.put(self.arena, key, base);
                // A $dynamicAnchor is also a plain anchor for $ref.
                if (!self.anchors.contains(key)) try self.anchors.put(self.arena, key, node);
            }
        }

        try self.descendSubschemas(node, base);
    }

    /// Recurse into all schema-position children of `node`.
    fn descendSubschemas(self: *Registry, node: *const Value, base: []const u8) std.mem.Allocator.Error!void {
        if (node.* != .object) return;
        const obj = node.object;
        var it = obj.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const v = e.value_ptr;
            const kind = subschemaKind(key);
            switch (kind) {
                .none => {},
                .single => try self.index(v, base),
                .array => if (v.* == .array) {
                    for (v.array.items) |*child| try self.index(child, base);
                },
                .map => if (v.* == .object) {
                    var mit = v.object.iterator();
                    while (mit.next()) |me| try self.index(me.value_ptr, base);
                },
            }
        }
    }

    const SubschemaKind = enum { none, single, array, map };

    fn subschemaKind(key: []const u8) SubschemaKind {
        const single = [_][]const u8{
            "additionalProperties", "contains",         "contentSchema",         "else",
            "if",                   "items",            "not",                   "propertyNames",
            "then",                 "unevaluatedItems", "unevaluatedProperties",
        };
        const arrays = [_][]const u8{ "allOf", "anyOf", "oneOf", "prefixItems" };
        const maps = [_][]const u8{ "$defs", "definitions", "dependentSchemas", "patternProperties", "properties" };
        for (single) |k| if (std.mem.eql(u8, key, k)) return .single;
        for (arrays) |k| if (std.mem.eql(u8, key, k)) return .array;
        for (maps) |k| if (std.mem.eql(u8, key, k)) return .map;
        return .none;
    }

    /// Resolve an absolute reference URI to a target schema node and its base.
    pub fn resolveAbsolute(self: *Registry, abs: []const u8) ?Resolved {
        const base = uri.withoutFragment(abs);
        const frag = uri.fragment(abs);

        if (frag == null or frag.?.len == 0) {
            const node = self.bases.get(base) orelse return null;
            return .{ .schema = node, .base = base };
        }
        const f = frag.?;
        if (f.len > 0 and f[0] == '/') {
            // JSON pointer fragment, relative to the resource at `base`.
            const root = self.bases.get(base) orelse return null;
            const decoded = uri.percentDecode(self.arena, f) catch return null;
            const target = navigatePointer(self.arena, root, decoded) orelse return null;
            return .{ .schema = target, .base = base };
        }
        // Plain-name anchor.
        const decoded = uri.percentDecode(self.arena, f) catch return null;
        const key = std.mem.concat(self.arena, u8, &.{ base, "#", decoded }) catch return null;
        if (self.anchors.get(key)) |node| return .{ .schema = node, .base = base };
        return null;
    }

    /// Canonical base URI for a schema node, if it was indexed.
    pub fn nodeBase(self: *Registry, node: *const Value) ?[]const u8 {
        return self.node_bases.get(node);
    }

    /// Look up a $dynamicAnchor named `name` within resource `base`.
    pub fn dynamicAnchor(self: *Registry, base: []const u8, name: []const u8) ?*const Value {
        const key = std.mem.concat(self.arena, u8, &.{ base, "#", name }) catch return null;
        return self.dynamic_anchors.get(key);
    }
};

/// Navigate a JSON Pointer (already percent-decoded, leading '/') from `root`.
/// `arena` is used only when a reference token contains a `~` escape.
pub fn navigatePointer(arena: std.mem.Allocator, root: *const Value, pointer: []const u8) ?*const Value {
    if (pointer.len == 0) return root;
    var current = root;
    var rest = pointer;
    while (rest.len > 0) {
        std.debug.assert(rest[0] == '/');
        rest = rest[1..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const raw = rest[0..end];
        rest = rest[end..];
        const token = unescapeToken(arena, raw) orelse return null;
        switch (current.*) {
            .object => |o| current = o.getPtr(token) orelse return null,
            .array => |arr| {
                const idx = std.fmt.parseInt(usize, token, 10) catch return null;
                if (idx >= arr.items.len) return null;
                current = &arr.items[idx];
            },
            else => return null,
        }
    }
    return current;
}

/// Unescape a JSON-pointer reference token: `~1` -> `/`, `~0` -> `~`.
fn unescapeToken(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '~') == null) return raw;
    var out = arena.alloc(u8, raw.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '~' and i + 1 < raw.len) {
            out[n] = if (raw[i + 1] == '1') '/' else if (raw[i + 1] == '0') '~' else raw[i + 1];
            i += 1;
        } else {
            out[n] = raw[i];
        }
        n += 1;
    }
    return out[0..n];
}
