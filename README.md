# jsonschema.zig

[![Zig Version](https://img.shields.io/badge/zig-0.16.0%2B-orange.svg)](https://ziglang.org/download/)

Generate JSON Schema Draft 2020-12 from Zig structs.

## Install

Add the package from GitHub:

```sh
zig fetch --save=jsonschema git+https://github.com/h0rv/jsonschema.zig.git
```

Then add the module in your `build.zig`:

```zig
const dep = b.dependency("jsonschema", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("jsonschema", dep.module("jsonschema"));
```

This repository is named `jsonschema.zig`, and the root source file is `src/jsonschema.zig`. The Zig package and module name is `jsonschema`.

## Example

```zig
const std = @import("std");
const jsonschema = @import("jsonschema");

const User = struct {
    name: []const u8,
    age: u8 = 18,
    email: ?[]const u8 = null,

    pub const jsonschema = .{
        .title = "User",
        .description = "A user profile.",
        .fields = .{
            .name = .{
                .description = "The user's full name.",
                .minLength = 1,
            },
            .age = .{
                .description = "Age in years.",
                .minimum = 0,
                .maximum = 130,
            },
            .email = .{
                .format = "email",
            },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);

    try jsonschema.write(User, &out.interface, .{});
    try out.interface.writeAll("\n");
    try out.interface.flush();
}
```

Output:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "User",
  "description": "A user profile.",
  "type": "object",
  "required": [
    "name",
    "age",
    "email"
  ],
  "properties": {
    "name": {
      "type": "string",
      "description": "The user's full name.",
      "minLength": 1
    },
    "age": {
      "type": "integer",
      "description": "Age in years.",
      "minimum": 0,
      "maximum": 130,
      "default": 18
    },
    "email": {
      "anyOf": [
        {
          "type": "string"
        },
        {
          "type": "null"
        }
      ],
      "format": "email",
      "default": null
    }
  },
  "additionalProperties": false
}
```

## API

```zig
pub fn write(comptime T: type, writer: anytype, comptime options: Options) !void;

pub fn stringifyAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    comptime options: Options,
) ![]u8;

pub fn toolSchemaAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    comptime options: Options,
) !ToolSchema;

pub fn validateValue(
    comptime T: type,
    value: T,
    writer: anytype,
    comptime options: Options,
) !bool;

pub fn schemaName(comptime T: type, comptime options: Options) []const u8;
pub fn schemaDescription(comptime T: type) ?[]const u8;
```

```zig
pub const DefMode = enum { never, always, auto };

pub const Options = struct {
    dialect: Dialect = .draft202012,
    name: ?[]const u8 = null,
    include_schema_uri: bool = true,
    additional_properties: bool = false,
    require_all_fields: bool = true,
    emit_defaults: bool = true,
    use_defs: DefMode = .auto,
    whitespace: Whitespace = .minified,
    infer_fixed_array_bounds: bool = false,
    infer_integer_bounds: bool = false,
    root_wrapper: RootWrapper = .none,
    field_naming: FieldNaming = .identity,
};
```

## Type mapping

| Zig type | JSON Schema |
| --- | --- |
| `struct` | `{ "type": "object" }` |
| `[]const u8`, `[]u8`, sentinel string slices, string literals | `{ "type": "string" }` |
| `bool` | `{ "type": "boolean" }` |
| integer types | `{ "type": "integer" }` |
| float types | `{ "type": "number" }` |
| `?T` | `anyOf: [schema(T), { "type": "null" }]` |
| arrays and slices | `{ "type": "array", "items": schema(child) }` |
| tuple structs | fixed array with `prefixItems`, `minItems`, and `maxItems` |
| string-key maps | `{ "type": "object", "additionalProperties": schema(value) }` |
| `enum` | `{ "type": "string", "enum": [...] }` |
| `union(enum)` | object `oneOf` variants using Zig's externally tagged JSON shape |

All struct fields are required by default. Zig field defaults are emitted as JSON Schema `default`, and the field stays in `required`.

## Draft 2020-12 support

This package targets JSON Schema Draft 2020-12.

Spec links:

- <https://json-schema.org/draft/2020-12>
- <https://json-schema.org/draft/2020-12/json-schema-core>
- <https://json-schema.org/draft/2020-12/json-schema-validation>
- <https://json-schema.org/draft/2020-12/schema>

This package emits schemas from Zig types. It is not a general JSON Schema validator.

### Core

| Keyword | Emit | Validate | Notes |
| --- | --- | --- | --- |
| `$schema` | ✓ |  | Draft URI by default. |
| `$ref` | ✓ |  | Local `#/$defs` refs only. |
| `$defs` | ✓ |  | Enabled by `use_defs`. |
| Boolean schemas |  |  | No bare `true`/`false` schemas. |
| `$id` | ✓ |  | Metadata. |
| `$anchor` | ✓ |  | Metadata; anchor name checked. |
| `$dynamicAnchor` | ✓ |  | Metadata; anchor name checked. |
| `$dynamicRef` | ✓ |  | Metadata. |
| `$vocabulary` | ✓ |  | Metadata object with boolean values. |
| `$comment` | ✓ |  | Metadata. |

### Applicator

| Keyword | Emit | Validate | Notes |
| --- | --- | --- | --- |
| `properties` | ✓ |  | Struct fields. |
| `required` | ✓ |  | Parsed Zig values cannot represent missing fields. |
| `additionalProperties` | ✓ |  | Boolean for structs; schema for string-key maps. |
| `items` | ✓ | ◐ | Arrays and slices. Validation recurses into items. |
| `prefixItems` | ✓ | ◐ | Tuple structs. |
| `anyOf` | ✓ | ◐ | Optionals only. |
| `oneOf` | ✓ | ◐ | Tagged unions only. |
| `contains` |  |  |  |
| `patternProperties` |  |  |  |
| `dependentSchemas` |  |  |  |
| `propertyNames` |  |  |  |
| `if` / `then` / `else` |  |  |  |
| `allOf` |  |  |  |
| `not` |  |  |  |
| `unevaluatedItems` |  |  |  |
| `unevaluatedProperties` |  |  |  |

### Validation

| Keyword | Emit | Validate | Notes |
| --- | --- | --- | --- |
| `type` | ✓ |  | String form only; nullable uses `anyOf`. |
| `enum` | ✓ |  | Zig enum tags. Parsing handles validity. |
| `const` | ✓ | ✓ | Field metadata `.@"const"`. |
| `minimum` / `maximum` | ✓ | ✓ | Metadata; optional inferred integer bounds. |
| `exclusiveMinimum` / `exclusiveMaximum` | ✓ | ✓ | Metadata. |
| `minLength` / `maxLength` | ✓ | ◐ | Validation uses byte length. |
| `minItems` / `maxItems` | ✓ | ✓ | Metadata; optional fixed-array inference. |
| `multipleOf` | ✓ |  | Emit only. |
| `pattern` | ✓ |  | Emit only. |
| `uniqueItems` | ✓ |  | Emit only. |
| `maxContains` / `minContains` |  |  |  |
| `maxProperties` / `minProperties` |  |  |  |
| `dependentRequired` |  |  |  |

### Format, annotation, content

| Keyword | Emit | Validate | Notes |
| --- | --- | --- | --- |
| `format` | ✓ |  | Annotation only. |
| `title` | ✓ |  |  |
| `description` | ✓ |  |  |
| `default` | ✓ |  | Annotation only. |
| `deprecated` | ✓ |  |  |
| `readOnly` / `writeOnly` | ✓ |  |  |
| `examples` | ✓ |  |  |
| `contentEncoding` |  |  |  |
| `contentMediaType` |  |  |  |
| `contentSchema` |  |  |  |

## Metadata

Attach metadata with `pub const jsonschema`.

Type metadata:

```zig
pub const jsonschema = .{
    .name = "UserProfile",
    .title = "User",
    .@"$id" = "https://example.com/schemas/user",
    .@"$anchor" = "User",
    .description = "A user profile.",
    .discriminator = "kind", // opt into flattened discriminated-object union schema
    .examples = .{.{ .name = "Ada", .age = 42, .email = null }},
};
```

Field metadata:

```zig
pub const jsonschema = .{
    .fields = .{
        .name = .{ .name = "fullName", .@"$comment" = "Display name.", .minLength = 1, .maxLength = 128 },
        .age = .{ .minimum = 0, .maximum = 130 },
        .email = .{ .format = "email" },
        .kind = .{ .@"const" = "user" },
        .nickname = .{ .required = false },
        .internal_id = .{ .omit = true },
    },
};
```

`Options.field_naming` can transform Zig field names globally, for example `.camelCase` or `.PascalCase`. Field metadata `.name` renames one emitted JSON property and overrides the global naming policy. Use `.@"const"` for JSON Schema `const`, `.required` to override requiredness, and `.omit` to exclude a field from the schema. Core keywords use escaped field names such as `.@"$id"`, `.@"$anchor"`, and `.@"$comment"`. Type metadata `.discriminator` sets the discriminator field for `union(enum)` schemas. Unknown metadata keys, metadata for missing fields, duplicate emitted field names, invalid metadata types, invalid defaults, and constraints on the wrong field type are compile errors.

## Maps

String-key maps emit dictionary schemas with `additionalProperties` as the value schema.

Supported map shapes include `std.StringHashMap(T)`, `std.StringHashMapUnmanaged(T)`, and `std.StringArrayHashMapUnmanaged(T)`.

## Tagged unions

`union(enum)` emits an object schema with `oneOf`. By default it matches Zig's JSON encoding: an externally tagged object such as `{ "search": { "query": "zig" } }`.

Add type metadata `.discriminator` to emit a flattened discriminated-object schema instead. Each variant then gets a discriminator field with a string `const` matching the tag. Struct payload variants are flattened into the variant object. Scalar and tuple payload variants use a generated `value` field.

`.discriminator` changes the schema/stringify shape. It is not the native `std.json` union parse shape. Use the default externally tagged union shape when parsing directly with `std.json`.

```zig
const Search = struct { query: []const u8 };
const Finish = struct { answer: []const u8 };

const Action = union(enum) {
    search: Search,
    finish: Finish,
    wait: void,

    pub const jsonschema = .{ .discriminator = "kind" };
};
```

## `$defs` and recursion

`use_defs = .auto` is the default. Recursive schemas automatically use `$defs` and `$ref`. Use `.always` to force `$defs` for nested structs or `.never` to reject recursion.

```zig
const Node = struct {
    name: []const u8,
    children: []const @This(),
};

const schema = try jsonschema.stringifyAlloc(Node, allocator, .{});
```

## Strict preset

Use `jsonschema.strict_options` for a provider-neutral strict schema shape: no top-level `$schema`, no defaults, required fields, closed objects, `$defs` auto mode, and inferred numeric/array bounds.

```zig
const schema = try jsonschema.stringifyAlloc(User, allocator, jsonschema.strict_options);
const name = jsonschema.schemaName(User, jsonschema.strict_options);
```

## Typed value validation

`validateValue` checks a parsed Zig value against supported metadata constraints and writes path errors. It is not a full JSON Schema validator.

```zig
var errors: std.Io.Writer.Allocating = .init(allocator);
defer errors.deinit();

if (!try jsonschema.validateValue(User, user, &errors.writer, .{})) {
    std.debug.print("{s}", .{errors.written()});
}
```

## Tool schema descriptor

`toolSchemaAlloc` returns a provider-neutral descriptor with name, description, and schema JSON. Provider request payloads stay outside this package.

```zig
var tool = try jsonschema.toolSchemaAlloc(User, allocator, jsonschema.strict_options);
defer tool.deinit(allocator);
```

## Root object wrapper

Some consumers require the root schema to be an object. `root_wrapper` wraps any schema in an object property. This changes the expected JSON shape; callers must parse the wrapper object and unwrap the field.

```zig
const schema = try jsonschema.stringifyAlloc([]const Item, allocator, .{
    .root_wrapper = .{ .object = .{ .field_name = "items" } },
});
```

Emitted root shape:

```json
{
  "type": "object",
  "required": ["items"],
  "properties": {
    "items": { "type": "array" }
  },
  "additionalProperties": false
}
```

## Pretty output

Use `.whitespace = .indent_2` for readable output:

```zig
const schema = try jsonschema.stringifyAlloc(User, allocator, .{
    .whitespace = .indent_2,
});
```

## Scope

This package emits schemas and can validate parsed Zig values against supported metadata constraints. It does not validate arbitrary JSON Schema documents, deserialize values, generate OpenAPI, or build provider request payloads.
