pub const Dialect = enum {
    draft202012,
};

pub const Whitespace = enum {
    minified,
    indent_2,
};

pub const Options = struct {
    dialect: Dialect = .draft202012,
    include_schema_uri: bool = true,
    additional_properties: bool = false,
    require_all_fields: bool = true,
    emit_defaults: bool = true,
    use_defs: bool = false,
    whitespace: Whitespace = .minified,
};
