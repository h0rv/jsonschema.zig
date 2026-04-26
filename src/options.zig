/// JSON Schema dialect to emit.
pub const Dialect = enum {
    /// JSON Schema Draft 2020-12.
    draft202012,
};

/// Output formatting.
pub const Whitespace = enum {
    /// Emit schema without extra whitespace.
    minified,
    /// Emit schema with two-space indentation.
    indent_2,
};

/// `$defs` emission policy.
pub const DefMode = enum {
    /// Inline nested schemas. Recursive schemas are rejected at comptime.
    never,
    /// Emit nested struct schemas under `$defs` and refer to them with `$ref`.
    always,
    /// Use `$defs` only when recursion requires it.
    auto,
};

/// Object wrapper for schemas that must have an object root.
pub const ObjectRootWrapper = struct {
    /// Property name that contains the wrapped schema.
    field_name: []const u8 = "items",
};

/// Root schema wrapper policy.
pub const RootWrapper = union(enum) {
    /// Emit the schema for `T` directly.
    none,
    /// Emit an object with one property containing the schema for `T`.
    object: ObjectRootWrapper,
};

/// Field name transform applied before per-field `.name` overrides.
pub const FieldNaming = enum {
    /// Use Zig field names unchanged.
    identity,
    /// Convert `snake_case` field names to `camelCase`.
    camelCase,
    /// Convert `snake_case` field names to `PascalCase`.
    PascalCase,
};

/// Controls schema emission.
pub const Options = struct {
    /// JSON Schema dialect.
    dialect: Dialect = .draft202012,
    /// Schema name override used by `schemaName`.
    name: ?[]const u8 = null,
    /// Field naming policy. Field metadata `.name` overrides this.
    field_naming: FieldNaming = .identity,
    /// Emit top-level `$schema`.
    include_schema_uri: bool = true,
    /// Value for object `additionalProperties`.
    additional_properties: bool = false,
    /// Put all struct fields in `required`.
    require_all_fields: bool = true,
    /// Emit Zig field defaults as JSON Schema `default`.
    emit_defaults: bool = true,
    /// `$defs` emission policy.
    use_defs: DefMode = .auto,
    /// Output formatting.
    whitespace: Whitespace = .minified,
    /// Emit `minItems` and `maxItems` for fixed arrays.
    infer_fixed_array_bounds: bool = false,
    /// Emit integer `minimum` and `maximum` from Zig integer bounds.
    infer_integer_bounds: bool = false,
    /// Wrap the root schema in an object.
    root_wrapper: RootWrapper = .none,
};

/// Provider-neutral strict schema preset.
pub const strict_options: Options = .{
    .include_schema_uri = false,
    .additional_properties = false,
    .require_all_fields = true,
    .emit_defaults = false,
    .use_defs = .auto,
    .infer_fixed_array_bounds = true,
    .infer_integer_bounds = true,
};
