# jsonschema.zig

[![Zig](https://img.shields.io/badge/zig-0.16.0%2B-orange.svg)](https://ziglang.org/download/)
[![Draft 2020-12](https://img.shields.io/badge/JSON%20Schema-Draft%202020--12-blue.svg)](https://json-schema.org/draft/2020-12)
[![Conformance](https://img.shields.io/badge/test--suite-100%25-brightgreen.svg)](#conformance)

A JSON Schema **Draft 2020-12** toolkit for Zig:

- **[Validator](docs/validator.md)**: validate any JSON instance against any JSON
  Schema document at runtime. Passes the entire official test suite (see
  [conformance](#conformance)).
- **[Emitter](docs/emitter.md)**: generate a JSON Schema document from a Zig type
  at comptime.

The two are independent; use either or both.

## Install

```sh
zig fetch --save=jsonschema git+https://github.com/h0rv/jsonschema.zig.git
```

Then wire the module into your `build.zig`:

```zig
const dep = b.dependency("jsonschema", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("jsonschema", dep.module("jsonschema"));
```

The module name is `jsonschema`; the root source file is `src/jsonschema.zig`.
Requires Zig 0.16.0+.

## Validate JSON against a schema

```zig
const std = @import("std");
const jsonschema = @import("jsonschema");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const schema = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"object","required":["name"],
        \\ "properties":{"name":{"type":"string","minLength":1},
        \\               "age":{"type":"integer","minimum":0}}}
    , .{});
    defer schema.deinit();

    const instance = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"name":"Ada","age":42}
    , .{});
    defer instance.deinit();

    const ok = try jsonschema.isValid(gpa, &schema.value, &instance.value, .{});
    std.debug.print("valid: {}\n", .{ok});
}
```

For reusable schemas, remote `$ref` resolution, error details, and `format`
assertion, see the **[validator guide](docs/validator.md)**.

## Generate a schema from a Zig type

```zig
const User = struct {
    name: []const u8,
    age: u8 = 18,

    pub const jsonschema = .{
        .title = "User",
        .fields = .{ .name = .{ .minLength = 1 } },
    };
};

const schema = try jsonschema.stringifyAlloc(User, allocator, .{ .whitespace = .indent_2 });
defer allocator.free(schema);
```

Type mapping, metadata, tagged unions, `$defs`, and the strict preset are
covered in the **[emitter guide](docs/emitter.md)**.

## Conformance

The validator passes the entire official
[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
for Draft 2020-12, vendored under `tests/suite/`:

| Run | Result |
| --- | --- |
| `zig build suite` (required) | **1299 / 1299** |
| `zig build suite -- --optional` (all optional groups) | **1461 / 1461** |
| `zig build suite -- --format` (`format` as an assertion) | **2086 / 2086** |

It implements every Draft 2020-12 keyword, including `$ref`/`$dynamicRef`/`$id`/
`$anchor`/`$dynamicAnchor` resolution, `unevaluatedItems`/`unevaluatedProperties`
with full annotation tracking, `$vocabulary` gating, a Thompson-NFA ECMA-262
regex engine (no catastrophic backtracking) for `pattern`, exact big-integer
`multipleOf`, and the `format` vocabulary with RFC 3492 Punycode / IDNA2008
hostname validation.

## Develop

```sh
zig build test                  # unit tests + emitter tests + required suite
zig build suite -- --format     # full conformance incl. optional + format
zig build run                   # run the emitter demo
```

(Or via mise: `mise run test`, `mise run suite-all`, `mise run check`.)

## Scope

This package validates JSON against Draft 2020-12 schemas and emits schemas from
Zig types. It does not deserialize values, generate OpenAPI, or build provider
request payloads. The validator performs no network or filesystem I/O; register
remote `$ref` documents with `Validator.addResource`.

## License

[MIT](LICENSE)
