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
pub fn write(comptime T: type, writer: anytype, options: Options) !void;

pub fn stringifyAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: Options,
) ![]u8;
```

```zig
pub const Options = struct {
    dialect: Dialect = .draft202012,
    include_schema_uri: bool = true,
    additional_properties: bool = false,
    require_all_fields: bool = true,
    emit_defaults: bool = true,
};
```

## Type mapping

| Zig type | JSON Schema |
| --- | --- |
| `struct` | `{ "type": "object" }` |
| `[]const u8`, `[]u8` | `{ "type": "string" }` |
| `bool` | `{ "type": "boolean" }` |
| integer types | `{ "type": "integer" }` |
| float types | `{ "type": "number" }` |
| `?T` | `anyOf: [schema(T), { "type": "null" }]` |
| arrays and slices | `{ "type": "array", "items": schema(child) }` |
| `enum` | `{ "type": "string", "enum": [...] }` |

All struct fields are required by default. Zig field defaults are emitted as JSON Schema `default`, and the field stays in `required`.

## Metadata

Attach metadata with `pub const jsonschema`.

Type metadata:

```zig
pub const jsonschema = .{
    .title = "User",
    .description = "A user profile.",
    .examples = .{.{ .name = "Ada", .age = 42, .email = null }},
};
```

Field metadata:

```zig
pub const jsonschema = .{
    .fields = .{
        .name = .{ .minLength = 1, .maxLength = 128 },
        .age = .{ .minimum = 0, .maximum = 130 },
        .email = .{ .format = "email" },
    },
};
```

Unknown metadata keys, metadata for missing fields, invalid metadata types, invalid defaults, and constraints on the wrong field type are compile errors.

## Scope

This package emits schemas only. It does not validate JSON, deserialize values, generate OpenAPI, or wrap schemas for LLM providers.
