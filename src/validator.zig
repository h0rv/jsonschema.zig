//! Runtime JSON Schema validator (Draft 2020-12): validates arbitrary JSON
//! instances against arbitrary JSON Schema documents.

const std = @import("std");
const core = @import("validator/core.zig");

pub const Validator = core.Validator;
/// A compiled schema is a `Validator` that has been set up (via `compile` or
/// `setRootSchema`) and is then only read. Validate it concurrently from many
/// threads with `validateScratch`, each passing its own scratch allocator.
pub const CompiledSchema = core.Validator;
/// Compile a schema once for repeated/concurrent validation. Equivalent to
/// `Validator.init` followed by `setRootSchema`.
pub const compile = core.Validator.compile;
pub const Options = core.Options;
pub const ValidationError = core.ValidationError;

/// Convenience: validate `instance` against `schema` (both `std.json.Value`).
/// Both values must outlive the call. Returns true if valid.
pub fn isValid(
    gpa: std.mem.Allocator,
    schema: *const std.json.Value,
    instance: *const std.json.Value,
    opts: Options,
) !bool {
    var v = try Validator.init(gpa, opts);
    defer v.deinit();
    try v.setRootSchema(schema);
    return v.validate(instance, null);
}

test {
    _ = @import("validator/uri.zig");
    _ = @import("validator/regex.zig");
    _ = @import("validator/jsonval.zig");
}

fn expectValidate(schema_json: []const u8, instance_json: []const u8, want: bool) !void {
    const a = std.testing.allocator;
    const schema = try std.json.parseFromSlice(std.json.Value, a, schema_json, .{});
    defer schema.deinit();
    const instance = try std.json.parseFromSlice(std.json.Value, a, instance_json, .{});
    defer instance.deinit();
    const got = try isValid(a, &schema.value, &instance.value, .{});
    try std.testing.expectEqual(want, got);
}

test "public API: basic object validation" {
    const schema =
        \\{"type":"object","properties":{"name":{"type":"string","minLength":1},
        \\ "age":{"type":"integer","minimum":0}},"required":["name"]}
    ;
    try expectValidate(schema, "{\"name\":\"Ada\",\"age\":42}", true);
    try expectValidate(schema, "{\"name\":\"\"}", false); // minLength
    try expectValidate(schema, "{\"age\":42}", false); // missing required
    try expectValidate(schema, "{\"name\":\"Ada\",\"age\":-1}", false); // minimum
}

test "public API: $ref and $defs" {
    const schema =
        \\{"$defs":{"pos":{"type":"integer","minimum":1}},
        \\ "type":"array","items":{"$ref":"#/$defs/pos"}}
    ;
    try expectValidate(schema, "[1,2,3]", true);
    try expectValidate(schema, "[1,0,3]", false);
}

test "public API: errors are reported" {
    const a = std.testing.allocator;
    const schema = try std.json.parseFromSlice(std.json.Value, a, "{\"type\":\"string\"}", .{});
    defer schema.deinit();
    const instance = try std.json.parseFromSlice(std.json.Value, a, "123", .{});
    defer instance.deinit();

    var v = try Validator.init(a, .{});
    defer v.deinit();
    try v.setRootSchema(&schema.value);

    var errors: std.ArrayListUnmanaged(ValidationError) = .empty;
    const ok = try v.validate(&instance.value, &errors);
    try std.testing.expect(!ok);
    try std.testing.expect(errors.items.len >= 1);
}

test "public API: unevaluatedProperties" {
    const schema =
        \\{"type":"object","properties":{"a":{"type":"integer"}},
        \\ "unevaluatedProperties":false}
    ;
    try expectValidate(schema, "{\"a\":1}", true);
    try expectValidate(schema, "{\"a\":1,\"b\":2}", false);
}

test "public API: oneOf and const" {
    const schema =
        \\{"oneOf":[{"const":"yes"},{"const":"no"}]}
    ;
    try expectValidate(schema, "\"yes\"", true);
    try expectValidate(schema, "\"maybe\"", false);
}

test "public API: format assertion opt-in" {
    const a = std.testing.allocator;
    const schema = try std.json.parseFromSlice(std.json.Value, a, "{\"format\":\"ipv4\"}", .{});
    defer schema.deinit();
    const bad = try std.json.parseFromSlice(std.json.Value, a, "\"999.1.1.1\"", .{});
    defer bad.deinit();

    // Annotation-only by default: invalid format still validates.
    try std.testing.expect(try isValid(a, &schema.value, &bad.value, .{}));
    // As an assertion, it fails.
    try std.testing.expect(!try isValid(a, &schema.value, &bad.value, .{ .assert_format = true }));
}

test "public API: prefixItems and unevaluatedItems" {
    const schema =
        \\{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],
        \\ "unevaluatedItems":false}
    ;
    try expectValidate(schema, "[\"a\",1]", true);
    try expectValidate(schema, "[\"a\",1,2]", false); // extra item not evaluated
    try expectValidate(schema, "[1,1]", false); // first not string
}

test "public API: contains with minContains" {
    const schema =
        \\{"type":"array","contains":{"const":"x"},"minContains":2}
    ;
    try expectValidate(schema, "[\"x\",\"x\"]", true);
    try expectValidate(schema, "[\"x\"]", false);
    try expectValidate(schema, "[\"x\",\"x\",\"y\"]", true);
}

test "public API: allOf annotations feed unevaluatedProperties" {
    const schema =
        \\{"allOf":[{"properties":{"a":{"type":"integer"}}}],
        \\ "properties":{"b":{"type":"integer"}},
        \\ "unevaluatedProperties":false}
    ;
    // `a` is evaluated inside allOf, `b` locally; both are allowed.
    try expectValidate(schema, "{\"a\":1,\"b\":2}", true);
    try expectValidate(schema, "{\"a\":1,\"b\":2,\"c\":3}", false);
}

test "public API: not and propertyNames" {
    try expectValidate("{\"not\":{\"type\":\"string\"}}", "42", true);
    try expectValidate("{\"not\":{\"type\":\"string\"}}", "\"s\"", false);
    try expectValidate(
        \\{"propertyNames":{"pattern":"^[a-z]+$"}}
    , "{\"ok\":1}", true);
    try expectValidate(
        \\{"propertyNames":{"pattern":"^[a-z]+$"}}
    , "{\"Bad\":1}", false);
}

test "public API: recursive $ref terminates" {
    const schema =
        \\{"$id":"https://ex/tree","type":"object",
        \\ "properties":{"value":{"type":"integer"},
        \\               "next":{"$ref":"#"}},
        \\ "required":["value"]}
    ;
    try expectValidate(schema, "{\"value\":1,\"next\":{\"value\":2,\"next\":{\"value\":3}}}", true);
    try expectValidate(schema, "{\"value\":1,\"next\":{\"value\":\"bad\"}}", false);
}

test "public API: remote resource via addResource" {
    const a = std.testing.allocator;
    const remote = try std.json.parseFromSlice(std.json.Value, a,
        \\{"$id":"https://ex/defs","type":"integer","minimum":0}
    , .{});
    defer remote.deinit();
    const schema = try std.json.parseFromSlice(std.json.Value, a,
        \\{"$ref":"https://ex/defs"}
    , .{});
    defer schema.deinit();

    var v = try Validator.init(a, .{});
    defer v.deinit();
    try v.addResource("https://ex/defs", &remote.value);
    try v.setRootSchema(&schema.value);

    const good = try std.json.parseFromSlice(std.json.Value, a, "5", .{});
    defer good.deinit();
    const bad = try std.json.parseFromSlice(std.json.Value, a, "-1", .{});
    defer bad.deinit();
    try std.testing.expect(try v.validate(&good.value, null));
    try std.testing.expect(!try v.validate(&bad.value, null));
}

test "public API: $dynamicRef / $dynamicAnchor" {
    // The list schema constrains items via a $dynamicRef that the caller's
    // resource overrides with a stricter $dynamicAnchor.
    const schema =
        \\{"$id":"https://ex/main","$ref":"https://ex/list",
        \\ "$defs":{"item":{"$dynamicAnchor":"T","type":"integer"}},
        \\ "$dynamicAnchor":"T"}
    ;
    const a = std.testing.allocator;
    const list = try std.json.parseFromSlice(std.json.Value, a,
        \\{"$id":"https://ex/list","type":"array",
        \\ "items":{"$dynamicRef":"#T"},
        \\ "$defs":{"default":{"$dynamicAnchor":"T"}}}
    , .{});
    defer list.deinit();
    const root = try std.json.parseFromSlice(std.json.Value, a, schema, .{});
    defer root.deinit();

    var v = try Validator.init(a, .{});
    defer v.deinit();
    try v.addResource("https://ex/list", &list.value);
    try v.setRootSchema(&root.value);

    const ints = try std.json.parseFromSlice(std.json.Value, a, "[1,2,3]", .{});
    defer ints.deinit();
    const mixed = try std.json.parseFromSlice(std.json.Value, a, "[1,\"x\"]", .{});
    defer mixed.deinit();
    try std.testing.expect(try v.validate(&ints.value, null));
    try std.testing.expect(!try v.validate(&mixed.value, null));
}

test "public API: boolean schemas" {
    try expectValidate("true", "{\"anything\":1}", true);
    try expectValidate("false", "1", false);
    try expectValidate("{\"properties\":{\"a\":false}}", "{\"a\":1}", false);
    try expectValidate("{\"properties\":{\"a\":false}}", "{\"b\":1}", true);
}

test "public API: additionalProperties ignores $ref-derived properties" {
    // `a` is matched only by the $ref'd subschema, so it is still "additional"
    // with respect to this object (which declares no `properties`).
    const schema =
        \\{"$ref":"#/$defs/r","additionalProperties":false,
        \\ "$defs":{"r":{"properties":{"a":{}}}}}
    ;
    try expectValidate(schema, "{\"a\":1}", false);
    // unevaluatedProperties, by contrast, does honor the $ref annotation.
    const schema2 =
        \\{"$ref":"#/$defs/r","unevaluatedProperties":false,
        \\ "$defs":{"r":{"properties":{"a":{}}}}}
    ;
    try expectValidate(schema2, "{\"a\":1}", true);
}

test "public API: out-of-range numeric keyword does not panic" {
    // `minItems` as a huge float must clamp, not crash.
    try expectValidate("{\"minItems\":1e30}", "[1,2,3]", false);
    try expectValidate("{\"maxLength\":1e30}", "\"abc\"", true);
}

test "public API: max_depth is configurable" {
    const a = std.testing.allocator;
    const schema = try std.json.parseFromSlice(std.json.Value, a,
        \\{"$id":"https://ex/self","$ref":"#"}
    , .{});
    defer schema.deinit();
    const instance = try std.json.parseFromSlice(std.json.Value, a, "1", .{});
    defer instance.deinit();

    var v = try Validator.init(a, .{ .max_depth = 64 });
    defer v.deinit();
    try v.setRootSchema(&schema.value);
    // A self-`$ref` on an unchanging instance exhausts the configured depth.
    try std.testing.expectError(error.RecursionLimit, v.validate(&instance.value, null));
}

test "CompiledSchema: compile once, validate many instances" {
    const a = std.testing.allocator;
    const schema = try std.json.parseFromSlice(std.json.Value, a,
        \\{"type":"object","required":["name"],
        \\ "properties":{"name":{"type":"string","pattern":"^[a-z]+$"}}}
    , .{});
    defer schema.deinit();

    var cs = try compile(a, &schema.value, .{});
    defer cs.deinit();

    const ok = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"ada\"}", .{});
    defer ok.deinit();
    const bad = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"Ada1\"}", .{});
    defer bad.deinit();

    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    try std.testing.expect(try cs.validateScratch(&ok.value, scratch.allocator(), null));
    _ = scratch.reset(.retain_capacity);
    try std.testing.expect(!try cs.validateScratch(&bad.value, scratch.allocator(), null));
}

test "CompiledSchema: concurrent validateScratch on one shared schema" {
    const a = std.testing.allocator;
    const schema = try std.json.parseFromSlice(std.json.Value, a,
        \\{"type":"object","required":["id"],
        \\ "properties":{"id":{"type":"integer","minimum":0},
        \\               "tag":{"type":"string","pattern":"^[a-z0-9_]+$"}}}
    , .{});
    defer schema.deinit();

    var cs = try compile(a, &schema.value, .{});
    defer cs.deinit();

    const Worker = struct {
        fn run(compiled: *const CompiledSchema, gpa: std.mem.Allocator, ok_out: *bool) void {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const good = std.json.parseFromSlice(std.json.Value, gpa, "{\"id\":1,\"tag\":\"abc_9\"}", .{}) catch {
                ok_out.* = false;
                return;
            };
            defer good.deinit();
            const bad = std.json.parseFromSlice(std.json.Value, gpa, "{\"id\":-1,\"tag\":\"BAD\"}", .{}) catch {
                ok_out.* = false;
                return;
            };
            defer bad.deinit();
            var all = true;
            var i: usize = 0;
            while (i < 500) : (i += 1) {
                _ = arena.reset(.retain_capacity);
                const v1 = compiled.validateScratch(&good.value, arena.allocator(), null) catch break;
                const v2 = compiled.validateScratch(&bad.value, arena.allocator(), null) catch break;
                if (!v1 or v2) {
                    all = false;
                    break;
                }
            }
            ok_out.* = all;
        }
    };

    var ok1 = false;
    var ok2 = false;
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ &cs, a, &ok1 });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ &cs, a, &ok2 });
    t1.join();
    t2.join();
    try std.testing.expect(ok1);
    try std.testing.expect(ok2);
}
