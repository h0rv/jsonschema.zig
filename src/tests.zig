const std = @import("std");
const jsonschema = @import("jsonschema");

fn expectSchema(comptime T: type, expected: []const u8, comptime options: jsonschema.Options) !void {
    const schema = try jsonschema.stringifyAlloc(T, std.testing.allocator, options);
    defer std.testing.allocator.free(schema);
    try std.testing.expectEqualStrings(expected, schema);
}

test "validate value reports metadata constraint failures" {
    const User = struct {
        name: []const u8,
        age: u8,
        tags: []const []const u8,

        pub const jsonschema = .{
            .fields = .{
                .name = .{ .minLength = 2 },
                .age = .{ .minimum = 18, .maximum = 99 },
                .tags = .{ .minItems = 1 },
            },
        };
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const ok = try jsonschema.validateValue(User, .{ .name = "A", .age = 17, .tags = &.{} }, &out.writer, .{});
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings(
        "$.name: failed minLength 2\n$.age: failed minimum 18\n$.tags: failed minItems 1\n",
        out.written(),
    );
}

test "validate value accepts valid data and honors field naming" {
    const User = struct {
        first_name: []const u8,

        pub const jsonschema = .{
            .fields = .{ .first_name = .{ .minLength = 2 } },
        };
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const ok = try jsonschema.validateValue(User, .{ .first_name = "Ada" }, &out.writer, .{ .field_naming = .camelCase });
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("", out.written());
}

test "tool schema descriptor" {
    const User = struct {
        name: []const u8,

        pub const jsonschema = .{
            .name = "UserTool",
            .description = "Extract user.",
        };
    };

    var tool = try jsonschema.toolSchemaAlloc(User, std.testing.allocator, .{});
    defer tool.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("UserTool", tool.name);
    try std.testing.expectEqualStrings("Extract user.", tool.description.?);
    try std.testing.expectEqualStrings(
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"description\":\"Extract user.\",\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        tool.schema_json,
    );
}

test "schema name and description" {
    const User = struct {
        pub const jsonschema = .{
            .name = "UserProfile",
            .description = "Extracted user profile.",
        };
    };

    try std.testing.expectEqualStrings("UserProfile", jsonschema.schemaName(User, .{}));
    try std.testing.expectEqualStrings("Custom", jsonschema.schemaName(User, .{ .name = "Custom" }));
    try std.testing.expectEqualStrings("Extracted user profile.", jsonschema.schemaDescription(User).?);
}

test "strict options" {
    const User = struct {
        age: u8 = 18,
        codes: [2]u16,

        pub const jsonschema = .{
            .title = "IgnoredTitle",
            .description = "Kept description.",
        };
    };

    try expectSchema(
        User,
        "{\"title\":\"IgnoredTitle\",\"description\":\"Kept description.\",\"type\":\"object\",\"required\":[\"age\",\"codes\"],\"properties\":{\"age\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},\"codes\":{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":65535},\"minItems\":2,\"maxItems\":2}},\"additionalProperties\":false}",
        jsonschema.strict_options,
    );
}

test "root object wrapper wraps array schema" {
    const Item = struct { name: []const u8 };

    try expectSchema(
        []const Item,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"items\"],\"properties\":{\"items\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}},\"additionalProperties\":false}}},\"additionalProperties\":false}",
        .{ .root_wrapper = .{ .object = .{} } },
    );
}

test "root object wrapper supports custom field and strict options" {
    const Item = struct { id: u8 = 1 };

    try expectSchema(
        []const Item,
        "{\"type\":\"object\",\"required\":[\"results\"],\"properties\":{\"results\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}},\"additionalProperties\":false}}},\"additionalProperties\":false}",
        comptime blk: {
            var opts = jsonschema.strict_options;
            opts.root_wrapper = .{ .object = .{ .field_name = "results" } };
            break :blk opts;
        },
    );
}

test "root object wrapper wraps union schema" {
    const Event = union(enum) { count: u8 };

    try expectSchema(
        Event,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"event\"],\"properties\":{\"event\":{\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"count\"],\"properties\":{\"count\":{\"type\":\"integer\"}},\"additionalProperties\":false}]}},\"additionalProperties\":false}",
        .{ .root_wrapper = .{ .object = .{ .field_name = "event" } } },
    );
}

test "tuple structs emit fixed prefixItems schema" {
    const Pair = struct { []const u8, u8 };

    try expectSchema(
        Pair,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"array\",\"prefixItems\":[{\"type\":\"string\"},{\"type\":\"integer\"}],\"minItems\":2,\"maxItems\":2}",
        .{},
    );
}

test "tuple prefixItems use defs" {
    const Item = struct { id: u8 };
    const Pair = struct { []const u8, Item };

    try expectSchema(
        Pair,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"array\",\"prefixItems\":[{\"type\":\"string\"},{\"$ref\":\"#/$defs/tuple prefixItems use defs.Item\"}],\"minItems\":2,\"maxItems\":2,\"$defs\":{\"tuple prefixItems use defs.Item\":{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = .always },
    );
}

test "string hash maps emit dictionary schema" {
    const Bag = struct {
        scores: std.StringHashMap(u8),
        flags: std.StringArrayHashMapUnmanaged(bool),
    };

    try expectSchema(
        Bag,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"scores\",\"flags\"],\"properties\":{\"scores\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"integer\"}},\"flags\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"boolean\"}}},\"additionalProperties\":false}",
        .{},
    );
}

test "string hash map values use defs when enabled" {
    const Item = struct { id: u8 };
    const Bag = struct { items: std.StringHashMap(Item) };

    try expectSchema(
        Bag,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"items\"],\"properties\":{\"items\":{\"type\":\"object\",\"additionalProperties\":{\"$ref\":\"#/$defs/string hash map values use defs when enabled.Item\"}}},\"additionalProperties\":false,\"$defs\":{\"string hash map values use defs when enabled.Item\":{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = .always },
    );
}

test "sentinel string pointer types emit string schema" {
    const User = struct {
        name: [:0]const u8,
        code: *const [4:0]u8,
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"code\"],\"properties\":{\"name\":{\"type\":\"string\"},\"code\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        .{},
    );
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

test "native tagged union emits externally tagged schema" {
    const Search = struct { query: []const u8 };
    const Finish = struct { answer: []const u8 };
    const Action = union(enum) {
        search: Search,
        finish: Finish,
        wait: void,
    };

    try expectSchema(
        Action,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"search\"],\"properties\":{\"search\":{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{\"query\":{\"type\":\"string\"}},\"additionalProperties\":false}},\"additionalProperties\":false},{\"type\":\"object\",\"required\":[\"finish\"],\"properties\":{\"finish\":{\"type\":\"object\",\"required\":[\"answer\"],\"properties\":{\"answer\":{\"type\":\"string\"}},\"additionalProperties\":false}},\"additionalProperties\":false},{\"type\":\"object\",\"required\":[\"wait\"],\"properties\":{\"wait\":{\"type\":\"object\",\"additionalProperties\":false}},\"additionalProperties\":false}]}",
        .{},
    );
}

test "native tagged union payload uses defs when enabled" {
    const Search = struct { query: []const u8 };
    const Action = union(enum) { search: Search };

    try expectSchema(
        Action,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"search\"],\"properties\":{\"search\":{\"$ref\":\"#/$defs/native tagged union payload uses defs when enabled.Search\"}},\"additionalProperties\":false}],\"$defs\":{\"native tagged union payload uses defs when enabled.Search\":{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{\"query\":{\"type\":\"string\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = .always },
    );
}

test "native tagged union allows payload field named type" {
    const Search = struct { type: []const u8, query: []const u8 };
    const Action = union(enum) { search: Search };

    try expectSchema(
        Action,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"search\"],\"properties\":{\"search\":{\"type\":\"object\",\"required\":[\"type\",\"query\"],\"properties\":{\"type\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"}},\"additionalProperties\":false}},\"additionalProperties\":false}]}",
        .{},
    );
}

test "std json parses native tagged union shape only" {
    const Event = union(enum) { count: u8 };

    var parsed = try std.json.parseFromSlice(Event, std.testing.allocator, "{\"count\":2}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 2), parsed.value.count);

    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(Event, std.testing.allocator, "{\"type\":\"count\",\"value\":2}", .{}),
    );
}

test "tagged union emits oneOf discriminator schemas" {
    const Search = struct {
        query_text: []const u8,

        pub const jsonschema = .{
            .fields = .{ .query_text = .{ .name = "query", .description = "Search query." } },
        };
    };
    const Finish = struct { answer: []const u8 };
    const Action = union(enum) {
        search: Search,
        finish: Finish,
        wait: void,

        pub const jsonschema = .{ .discriminator = "kind" };
    };

    try expectSchema(
        Action,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"kind\",\"query\"],\"properties\":{\"kind\":{\"type\":\"string\",\"const\":\"search\"},\"query\":{\"type\":\"string\",\"description\":\"Search query.\"}},\"additionalProperties\":false},{\"type\":\"object\",\"required\":[\"kind\",\"answer\"],\"properties\":{\"kind\":{\"type\":\"string\",\"const\":\"finish\"},\"answer\":{\"type\":\"string\"}},\"additionalProperties\":false},{\"type\":\"object\",\"required\":[\"kind\"],\"properties\":{\"kind\":{\"type\":\"string\",\"const\":\"wait\"}},\"additionalProperties\":false}]}",
        .{},
    );
}

test "strict root union keeps oneOf object shape" {
    const Event = union(enum) { count: u8 };

    try expectSchema(
        Event,
        "{\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"count\"],\"properties\":{\"count\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}},\"additionalProperties\":false}]}",
        jsonschema.strict_options,
    );
}

test "discriminator tagged union scalar payload uses value" {
    const Event = union(enum) {
        count: u8,

        pub const jsonschema = .{ .discriminator = "kind" };
    };

    try expectSchema(
        Event,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"kind\",\"value\"],\"properties\":{\"kind\":{\"type\":\"string\",\"const\":\"count\"},\"value\":{\"type\":\"integer\"}},\"additionalProperties\":false}]}",
        .{},
    );
}

test "tagged union default emits native object" {
    const Event = union(enum) { count: u8 };
    const Wrapper = struct { event: Event = .{ .count = 2 } };

    try expectSchema(
        Wrapper,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"event\"],\"properties\":{\"event\":{\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"count\"],\"properties\":{\"count\":{\"type\":\"integer\"}},\"additionalProperties\":false}],\"default\":{\"count\":2}}},\"additionalProperties\":false}",
        .{},
    );
}

test "tagged union scalar payload uses native tag field" {
    const Event = union(enum) {
        count: u8,
        message: []const u8,
    };

    try expectSchema(
        Event,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"oneOf\":[{\"type\":\"object\",\"required\":[\"count\"],\"properties\":{\"count\":{\"type\":\"integer\"}},\"additionalProperties\":false},{\"type\":\"object\",\"required\":[\"message\"],\"properties\":{\"message\":{\"type\":\"string\"}},\"additionalProperties\":false}]}",
        .{},
    );
}

test "field metadata const" {
    const Search = struct {
        type: []const u8,
        query: []const u8,

        pub const jsonschema = .{
            .fields = .{
                .type = .{ .@"const" = "search", .description = "Action kind." },
            },
        };
    };

    try expectSchema(
        Search,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"type\",\"query\"],\"properties\":{\"type\":{\"type\":\"string\",\"description\":\"Action kind.\",\"const\":\"search\"},\"query\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        .{},
    );
}

test "field metadata controls required and omitted fields" {
    const User = struct {
        id: u8,
        nickname: []const u8,
        internal: []const u8,

        pub const jsonschema = .{
            .fields = .{
                .nickname = .{ .required = false },
                .internal = .{ .omit = true },
            },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\"},\"nickname\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        .{},
    );
}

test "field metadata can require with global required disabled" {
    const User = struct {
        id: u8,
        nickname: []const u8,

        pub const jsonschema = .{
            .fields = .{ .id = .{ .required = true } },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\"},\"nickname\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        .{ .require_all_fields = false },
    );
}

test "field naming policy transforms property names" {
    const User = struct {
        first_name: []const u8,
        last_name: []const u8,
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"firstName\",\"lastName\"],\"properties\":{\"firstName\":{\"type\":\"string\"},\"lastName\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        .{ .field_naming = .camelCase },
    );

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"FirstName\",\"LastName\"],\"properties\":{\"FirstName\":{\"type\":\"string\"},\"LastName\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        .{ .field_naming = .PascalCase },
    );
}

test "field metadata name overrides field naming policy" {
    const User = struct {
        first_name: []const u8,
        last_name: []const u8,

        pub const jsonschema = .{
            .fields = .{ .first_name = .{ .name = "given" } },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"given\",\"lastName\"],\"properties\":{\"given\":{\"type\":\"string\"},\"lastName\":{\"type\":\"string\"}},\"additionalProperties\":false}",
        .{ .field_naming = .camelCase },
    );
}

test "field metadata can rename emitted property" {
    const User = struct {
        first_name: []const u8,
        age: u8,

        pub const jsonschema = .{
            .fields = .{
                .first_name = .{ .name = "firstName", .description = "Given name." },
            },
        };
    };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"firstName\",\"age\"],\"properties\":{\"firstName\":{\"type\":\"string\",\"description\":\"Given name.\"},\"age\":{\"type\":\"integer\"}},\"additionalProperties\":false}",
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

test "inferred fixed array and integer bounds" {
    const Data = struct {
        small: u8,
        signed: i8,
        codes: [2]u16,
    };

    try expectSchema(
        Data,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"small\",\"signed\",\"codes\"],\"properties\":{\"small\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},\"signed\":{\"type\":\"integer\",\"minimum\":-128,\"maximum\":127},\"codes\":{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":65535},\"minItems\":2,\"maxItems\":2}},\"additionalProperties\":false}",
        .{ .infer_fixed_array_bounds = true, .infer_integer_bounds = true },
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

test "pretty output" {
    const User = struct {
        name: []const u8,
        age: u8 = 18,
    };

    try expectSchema(
        User,
        \\{
        \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
        \\  "type": "object",
        \\  "required": [
        \\    "name",
        \\    "age"
        \\  ],
        \\  "properties": {
        \\    "name": {
        \\      "type": "string"
        \\    },
        \\    "age": {
        \\      "type": "integer",
        \\      "default": 18
        \\    }
        \\  },
        \\  "additionalProperties": false
        \\}
    ,
        .{ .whitespace = .indent_2 },
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
        .{ .use_defs = .always },
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
        .{ .use_defs = .always },
    );
}

test "$defs include transitive nested structs" {
    const Country = struct { code: []const u8 };
    const Address = struct { country: Country };
    const User = struct { address: Address };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"address\"],\"properties\":{\"address\":{\"$ref\":\"#/$defs/Address\"}},\"additionalProperties\":false,\"$defs\":{\"Address\":{\"type\":\"object\",\"required\":[\"country\"],\"properties\":{\"country\":{\"$ref\":\"#/$defs/Country\"}},\"additionalProperties\":false},\"Country\":{\"type\":\"object\",\"required\":[\"code\"],\"properties\":{\"code\":{\"type\":\"string\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = .always },
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
        .{ .use_defs = .always },
    );
}

test "$defs disambiguate same short names" {
    const A = struct {
        pub const Address = struct { city: []const u8 };
    };
    const B = struct {
        pub const Address = struct { zip: u32 };
    };
    const User = struct {
        home: A.Address,
        work: B.Address,
    };

    const schema = try jsonschema.stringifyAlloc(User, std.testing.allocator, .{ .use_defs = .always });
    defer std.testing.allocator.free(schema);
    try std.testing.expect(std.mem.indexOf(u8, schema, "A.Address") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "B.Address") != null);
}

test "$defs recursive slice" {
    const Node = struct {
        name: []const u8,
        children: []const @This(),
    };

    try expectSchema(
        Node,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"children\"],\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Node\"}}},\"additionalProperties\":false,\"$defs\":{\"Node\":{\"type\":\"object\",\"required\":[\"name\",\"children\"],\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Node\"}}},\"additionalProperties\":false}}}",
        .{ .use_defs = .always },
    );
}

test "pointer to struct" {
    const Address = struct { city: []const u8 };
    const User = struct { address: *const Address };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"address\"],\"properties\":{\"address\":{\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}},\"additionalProperties\":false}",
        .{},
    );
}

test "$defs pointer to struct" {
    const Address = struct { city: []const u8 };
    const User = struct { address: *const Address };

    try expectSchema(
        User,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"address\"],\"properties\":{\"address\":{\"$ref\":\"#/$defs/Address\"}},\"additionalProperties\":false,\"$defs\":{\"Address\":{\"type\":\"object\",\"required\":[\"city\"],\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}}}",
        .{ .use_defs = .always },
    );
}

test "$defs recursive optional pointer" {
    const Node = struct {
        name: []const u8,
        next: ?*const @This() = null,
    };

    try expectSchema(
        Node,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"required\":[\"name\",\"next\"],\"properties\":{\"name\":{\"type\":\"string\"},\"next\":{\"anyOf\":[{\"$ref\":\"#/$defs/Node\"},{\"type\":\"null\"}],\"default\":null}},\"additionalProperties\":false,\"$defs\":{\"Node\":{\"type\":\"object\",\"required\":[\"name\",\"next\"],\"properties\":{\"name\":{\"type\":\"string\"},\"next\":{\"anyOf\":[{\"$ref\":\"#/$defs/Node\"},{\"type\":\"null\"}],\"default\":null}},\"additionalProperties\":false}}}",
        .{},
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
        .{ .use_defs = .always },
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
