const std = @import("std");
const jsonschema = @import("jsonschema");

fn expectSchema(comptime T: type, expected: []const u8, options: jsonschema.Options) !void {
    const schema = try jsonschema.stringifyAlloc(T, std.testing.allocator, options);
    defer std.testing.allocator.free(schema);
    try std.testing.expectEqualStrings(expected, schema);
}

test "plain struct" {
    const User = struct {
        name: []const u8,
        age: u8,
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"age\"],\"properties\":{\"name\":{\"type\":\"string\"},\"age\":{\"type\":\"integer\"}},\"additionalProperties\":false}",
        .{},
    );
}

test "type and field metadata" {
    const User = struct {
        name: []const u8,

        pub const jsonschema = .{
            .title = "User",
            .description = "A user profile.",
            .examples = .{.{ .name = "Ada" }},
            .deprecated = false,
            .readOnly = false,
            .writeOnly = false,
            .fields = .{
                .name = .{
                    .title = "Name",
                    .description = "Full name.",
                    .examples = &[_][]const u8{ "Ada", "Grace" },
                    .deprecated = false,
                    .readOnly = false,
                    .writeOnly = false,
                    .minLength = 1,
                    .maxLength = 128,
                    .pattern = "^[A-Za-z ]+$",
                    .format = "name",
                },
            },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"title\":\"User\",\"description\":\"A user profile.\",\"examples\":[{\"name\":\"Ada\"}],\"deprecated\":false,\"readOnly\":false,\"writeOnly\":false,\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\",\"title\":\"Name\",\"description\":\"Full name.\",\"examples\":[\"Ada\",\"Grace\"],\"deprecated\":false,\"readOnly\":false,\"writeOnly\":false,\"minLength\":1,\"maxLength\":128,\"pattern\":\"^[A-Za-z ]+$\",\"format\":\"name\"}},\"additionalProperties\":false}",
        .{},
    );
}

test "defaults remain required" {
    const User = struct {
        name: []const u8,
        age: u8 = 18,
        email: ?[]const u8 = null,
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"age\",\"email\"],\"properties\":{\"name\":{\"type\":\"string\"},\"age\":{\"type\":\"integer\",\"default\":18},\"email\":{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"null\"}],\"default\":null}},\"additionalProperties\":false}",
        .{},
    );
}

test "field metadata default overrides Zig default" {
    const Settings = struct {
        active: bool = false,

        pub const jsonschema = .{
            .fields = .{
                .active = .{ .default = true },
            },
        };
    };

    try expectSchema(
        Settings,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"active\"],\"properties\":{\"active\":{\"type\":\"boolean\",\"default\":true}},\"additionalProperties\":false}",
        .{},
    );
}

test "numeric constraints" {
    const Product = struct {
        price: f64,
        count: u32,

        pub const jsonschema = .{
            .fields = .{
                .price = .{ .minimum = 0, .exclusiveMaximum = 1000.5, .multipleOf = 0.01 },
                .count = .{ .minimum = 1, .maximum = 99 },
            },
        };
    };

    try expectSchema(
        Product,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"price\",\"count\"],\"properties\":{\"price\":{\"type\":\"number\",\"minimum\":0,\"exclusiveMaximum\":1000.5,\"multipleOf\":0.01},\"count\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":99}},\"additionalProperties\":false}",
        .{},
    );
}

test "nested struct type metadata" {
    const Address = struct {
        city: []const u8,

        pub const jsonschema = .{
            .title = "Address",
            .description = "A mailing address.",
        };
    };
    const User = struct { address: Address };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"address\"],\"properties\":{\"address\":{\"title\":\"Address\",\"description\":\"A mailing address.\",\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}},\"additionalProperties\":false}",
        .{},
    );
}

test "nested struct enum arrays slices" {
    const Role = enum { admin, user };
    const Address = struct { city: []const u8 };
    const User = struct {
        role: Role,
        tags: []const []const u8,
        codes: [2]u16,
        address: Address,

        pub const jsonschema = .{
            .fields = .{
                .tags = .{ .minItems = 1, .maxItems = 4, .uniqueItems = true },
            },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"role\",\"tags\",\"codes\",\"address\"],\"properties\":{\"role\":{\"type\":\"string\",\"enum\":[\"admin\",\"user\"]},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"maxItems\":4,\"uniqueItems\":true},\"codes\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}},\"address\":{\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}},\"additionalProperties\":false}",
        .{},
    );
}

test "options" {
    const User = struct {
        name: []const u8,
        age: u8 = 18,
    };

    try expectSchema(
        User,
        "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"age\":{\"type\":\"integer\"}},\"additionalProperties\":true}",
        .{
            .include_schema_uri = false,
            .additional_properties = true,
            .require_all_fields = false,
            .emit_defaults = false,
        },
    );
}

test "metadata defaults for enum and nested object" {
    const Role = enum { admin, user };
    const Address = struct { city: []const u8, zip: u32 };
    const User = struct {
        role: Role,
        address: Address,

        pub const jsonschema = .{
            .fields = .{
                .role = .{ .default = "admin" },
                .address = .{ .default = .{ .city = "Philadelphia", .zip = 19104 } },
            },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"role\",\"address\"],\"properties\":{\"role\":{\"type\":\"string\",\"enum\":[\"admin\",\"user\"],\"default\":\"admin\"},\"address\":{\"type\":\"object\",\"required\":[\"city\",\"zip\"],\"properties\":{\"city\":{\"type\":\"string\"},\"zip\":{\"type\":\"integer\"}},\"additionalProperties\":false,\"default\":{\"city\":\"Philadelphia\",\"zip\":19104}}},\"additionalProperties\":false}",
        .{},
    );
}

test "$defs for nested structs" {
    const Address = struct { city: []const u8 };
    const User = struct {
        name: []const u8,
        address: Address,
        previous: ?Address = null,
        history: []const Address,
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"address\",\"previous\",\"history\"],\"properties\":{\"name\":{\"type\":\"string\"},\"address\":{\"$ref\":\"#/$defs/Address\"},\"previous\":{\"anyOf\":[{\"$ref\":\"#/$defs/Address\"},{\"type\":\"null\"}],\"default\":null},\"history\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Address\"}}},\"additionalProperties\":false,\"$defs\":{\"Address\":{\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = true },
    );
}

test "$defs include nested type metadata" {
    const Address = struct {
        city: []const u8,

        pub const jsonschema = .{ .title = "Address" };
    };
    const User = struct { address: Address };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"address\"],\"properties\":{\"address\":{\"$ref\":\"#/$defs/Address\"}},\"additionalProperties\":false,\"$defs\":{\"Address\":{\"title\":\"Address\",\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = true },
    );
}

test "$defs include transitive nested structs" {
    const Country = struct { code: []const u8 };
    const Address = struct { country: Country };
    const User = struct { address: Address };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"address\"],\"properties\":{\"address\":{\"$ref\":\"#/$defs/Address\"}},\"additionalProperties\":false,\"$defs\":{\"Address\":{\"type\":\"object\",\"required\":[\"country\"],\"properties\":{\"country\":{\"$ref\":\"#/$defs/Country\"}},\"additionalProperties\":false},\"Country\":{\"type\":\"object\",\"required\":[\"code\"],\"properties\":{\"code\":{\"type\":\"string\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = true },
    );
}

test "$defs preserve ref field metadata and defaults" {
    const Address = struct { city: []const u8 };
    const User = struct {
        address: Address = .{ .city = "Philadelphia" },

        pub const jsonschema = .{
            .fields = .{
                .address = .{ .description = "Mailing address." },
            },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"address\"],\"properties\":{\"address\":{\"$ref\":\"#/$defs/Address\",\"description\":\"Mailing address.\",\"default\":{\"city\":\"Philadelphia\"}}},\"additionalProperties\":false,\"$defs\":{\"Address\":{\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = true },
    );
}

test "$defs recursive slice" {
    const Node = struct {
        name: []const u8,
        children: []const @This(),
    };

    try expectSchema(
        Node,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"children\"],\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Node\"}}},\"additionalProperties\":false,\"$defs\":{\"Node\":{\"type\":\"object\",\"required\":[\"name\",\"children\"],\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Node\"}}},\"additionalProperties\":false}}}",
        .{ .use_defs = true },
    );
}

test "$defs recursive optional slice" {
    const Node = struct {
        name: []const u8,
        children: ?[]const @This() = null,
    };

    try expectSchema(
        Node,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"children\"],\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"anyOf\":[{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Node\"}},{\"type\":\"null\"}],\"default\":null}},\"additionalProperties\":false,\"$defs\":{\"Node\":{\"type\":\"object\",\"required\":[\"name\",\"children\"],\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"anyOf\":[{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Node\"}},{\"type\":\"null\"}],\"default\":null}},\"additionalProperties\":false}}}",
        .{ .use_defs = true },
    );
}

test "sentinel strings and string literals" {
    const Text = struct {
        sentinel: [:0]const u8,
        literal: *const [5:0]u8 = "hello",
    };

    try expectSchema(
        Text,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"sentinel\",\"literal\"],\"properties\":{\"sentinel\":{\"type\":\"string\"},\"literal\":{\"type\":\"string\",\"default\":\"hello\"}},\"additionalProperties\":false}",
        .{},
    );
}

test "json string escaping" {
    const Text = struct {
        value: []const u8 = "quote\" slash\\ newline\n tab\t",
    };

    try expectSchema(
        Text,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"value\"],\"properties\":{\"value\":{\"type\":\"string\",\"default\":\"quote\\\" slash\\\\ newline\\n tab\\t\"}},\"additionalProperties\":false}",
        .{},
    );
}
