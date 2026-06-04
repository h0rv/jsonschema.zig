# Runtime validator

The validator checks an arbitrary JSON instance against an arbitrary JSON Schema
document (Draft 2020-12). Both the schema and the instance are
`std.json.Value`s, and both must outlive the validation call.

- [Quick start](#quick-start)
- [API](#api)
- [Options](#options)
- [Errors](#errors)
- [References and remote resources](#references-and-remote-resources)
- [Formats](#formats)
- [Vocabularies](#vocabularies)
- [Resource limits](#resource-limits)
- [Conformance](#conformance)
- [Limitations](#limitations)

## Quick start

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

## API

```zig
/// One-shot validation. Returns true when `instance` satisfies `schema`.
pub fn isValid(
    gpa: std.mem.Allocator,
    schema: *const std.json.Value,
    instance: *const std.json.Value,
    opts: ValidatorOptions,
) !bool;

pub const Validator = struct {
    pub fn init(gpa: std.mem.Allocator, opts: ValidatorOptions) !Validator;
    pub fn deinit(self: *Validator) void;

    /// Register a document that `$ref` may point to, by absolute URI.
    pub fn addResource(self: *Validator, uri: []const u8, root: *const std.json.Value) !void;

    /// Set the schema to validate against. Call after any `addResource`.
    pub fn setRootSchema(self: *Validator, root: *const std.json.Value) !void;

    /// Validate `instance`. When `errors_out` is non-null, failure details are
    /// appended to it (allocated in the validator's arena).
    pub fn validate(
        self: *Validator,
        instance: *const std.json.Value,
        errors_out: ?*std.ArrayListUnmanaged(ValidationError),
    ) !bool;
};
```

Use `Validator` directly when you validate many instances against one schema,
need remote `$ref` resolution, or want error details. A single `Validator` can
validate any number of instances after `setRootSchema`; all schema and instance
`Value`s must remain alive for as long as you call `validate`.

```zig
var v = try jsonschema.Validator.init(gpa, .{});
defer v.deinit();

try v.addResource("https://example.com/defs.json", &defs.value); // optional
try v.setRootSchema(&schema.value);

var errors: std.ArrayListUnmanaged(jsonschema.ValidationError) = .empty;
const ok = try v.validate(&instance.value, &errors);
for (errors.items) |e| std.debug.print("{s}: {s}\n", .{ e.instance_path, e.message });
```

## Options

```zig
pub const ValidatorOptions = struct {
    /// When true, `format` is an assertion (invalid formats fail validation).
    /// Default false: `format` is annotation-only, per Draft 2020-12. A custom
    /// meta-schema that includes the `format-assertion` vocabulary also enables
    /// assertion regardless of this flag.
    assert_format: bool = false,
    /// Base URI assigned to the root document when it declares no `$id`.
    default_base_uri: []const u8 = "",
    /// Max schema/instance recursion depth before `error.RecursionLimit`.
    /// 0 disables the limit. See [Resource limits](#resource-limits).
    max_depth: usize = 2000,
    /// Limits for the `pattern`/`patternProperties` regex engine.
    regex_limits: RegexLimits = .{},
};

pub const RegexLimits = struct {
    /// Max nested groups/alternation depth.   0 = unlimited.
    max_nesting: usize = 1000,
    /// Max `{n,m}` quantifier count.          0 = unlimited.
    max_repeat: usize = 100_000,
    /// Max compiled NFA instructions.         0 = unlimited.
    max_program: usize = 200_000,
};
```

## Errors

`validate` returns a `bool`. When you pass an `errors_out` list, each failed
assertion is appended as:

```zig
pub const ValidationError = struct {
    /// JSON Pointer to the failing location in the instance.
    instance_path: []const u8,
    /// Human-readable message.
    message: []const u8,
};
```

Error strings are owned by the `Validator`'s internal arena and are freed by
`Validator.deinit`. (`isValid` discards errors.)

## References and remote resources

`$ref`, `$dynamicRef`, `$id`, `$anchor`, `$dynamicAnchor`, and `$defs` are fully
supported, including JSON-pointer fragments, plain-name anchors, nested `$id`
base changes, and the dynamic-scope resolution of `$dynamicRef`/`$dynamicAnchor`.

The validator never performs network or filesystem I/O. To resolve a `$ref` to a
URI outside the root document, register that document first:

```zig
try v.addResource("https://example.com/other.json", &other.value);
```

The root document is registered automatically by `setRootSchema`; if it declares
no `$id`, it is keyed under `default_base_uri` (the empty string by default).

## Formats

`format` is annotation-only by default. Enable assertion with
`assert_format = true` (or a meta-schema carrying the `format-assertion`
vocabulary). When asserted, these formats are validated against their RFCs:

`date`, `time`, `date-time` (including leap seconds), `duration`, `email`,
`idn-email`, `hostname`, `idn-hostname`, `ipv4`, `ipv6`, `uuid`, `json-pointer`,
`relative-json-pointer`, `uri`, `uri-reference`, `iri`, `iri-reference`,
`uri-template`, and `regex`.

`hostname` and `idn-hostname` include RFC 3492 Punycode decoding of `xn--`
labels and the IDNA2008 label rules (leading combining marks, the CONTEXTJ and
CONTEXTO contextual rules, and bidi mixing). Any format name the validator does
not recognize always passes, as the spec requires.

## Vocabularies

A `$schema` declaration selects the active vocabularies for its resource. The
validator reads `$vocabulary` from a registered meta-schema and gates keyword
groups accordingly: disabling the validation vocabulary turns `type`, `minimum`,
`pattern`, etc. into no-ops; disabling the applicator or unevaluated vocabularies
likewise. Unknown meta-schemas default to the full standard dialect.

`pattern` and `patternProperties` use a self-contained ECMA-262 regex engine
compiled to a Thompson NFA, so a malicious pattern cannot cause catastrophic
backtracking. `multipleOf` uses exact big-integer arithmetic for values that
overflow `f64`. The Draft-07 `dependencies` keyword is accepted for backward
compatibility.

## Resource limits

JSON Schema Draft 2020-12 defines no resource limits. Its security
considerations note the risks (regex denial of service, deeply nested
instances, oversized `multipleOf`) but prescribe no values, so the limits below
are this library's own defaults, chosen to stop a hostile schema or instance
from crashing or exhausting memory. Every one is configurable, and setting a
limit to `0` disables it.

| Option | Default | Guards against |
| --- | --- | --- |
| `max_depth` | 2000 | deep instances, `$ref` self-cycles (returns `error.RecursionLimit`) |
| `regex_limits.max_nesting` | 1000 | deeply nested regex groups (stack overflow) |
| `regex_limits.max_repeat` | 100000 | huge `{n,m}` quantifier counts |
| `regex_limits.max_program` | 200000 | regex compile-time memory blowup |

```zig
// Raise the recursion limit for legitimately deep data; disable the regex
// program cap (only safe for trusted schemas).
var v = try jsonschema.Validator.init(gpa, .{
    .max_depth = 100_000,
    .regex_limits = .{ .max_program = 0 },
});
```

This mirrors how other implementations behave. Validators built on a linear
regex engine (Go's `regexp`/RE2, Rust's `regex` crate) apply a compiled-size cap
just like `regex_limits`; Rust exposes it as a configurable `size_limit`, Go
hard-codes it. Validators on a backtracking engine (ajv, Python `jsonschema`)
have no cap and instead warn against running untrusted schemas. Disabling a
limit here puts you in that second category: a hostile pattern can then exhaust
memory, and an unbounded `max_depth` can overflow the native stack.

A regex the engine refuses to compile (syntactically invalid, or beyond these
limits) is not enforced: validation does not error, and the `pattern` keyword
passes rather than crashing on a pathological input.

## Conformance

The validator passes the entire official
[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
for Draft 2020-12, vendored under `tests/suite/`:

| Run | Result |
| --- | --- |
| `zig build suite` (required) | 1299 / 1299 |
| `zig build suite -- --optional` (all optional groups) | 1461 / 1461 |
| `zig build suite -- --format` (format as assertion) | 2086 / 2086 |

## Limitations

- No network or filesystem `$ref` fetching. Register remote documents with
  `addResource`.
- Cross-draft `$ref` (into Draft-07 / 2019-09 resources) is supported only to the
  extent of ignoring keywords absent from the referenced dialect; it does not
  re-interpret keywords with their older semantics.
- Full Unicode NFC normalization is not bundled (no conformance case requires a
  normalization transform).
