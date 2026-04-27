pub const core_keys = [_][]const u8{
    "$id",
    "$anchor",
    "$dynamicAnchor",
    "$dynamicRef",
    "$vocabulary",
    "$comment",
};

pub const annotation_keys = [_][]const u8{
    "title",
    "description",
    "examples",
    "deprecated",
    "readOnly",
    "writeOnly",
};

pub const default_key = [_][]const u8{"default"};

pub const const_key = [_][]const u8{"const"};

pub const emitter_field_keys = [_][]const u8{ "name", "required", "omit" };

pub const emitter_type_keys = [_][]const u8{ "fields", "name", "discriminator" };

pub const object_constraint_keys = [_][]const u8{
    "minProperties",
    "maxProperties",
    "patternProperties",
    "dependentSchemas",
    "propertyNames",
    "dependentRequired",
};

pub const content_keys = [_][]const u8{
    "contentEncoding",
    "contentMediaType",
    "contentSchema",
};

pub const validation_keys = [_][]const u8{
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "multipleOf",
    "minLength",
    "maxLength",
    "pattern",
    "format",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minProperties",
    "maxProperties",
    "patternProperties",
    "dependentSchemas",
    "propertyNames",
    "dependentRequired",
    "contentEncoding",
    "contentMediaType",
    "contentSchema",
};
