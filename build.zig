const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("jsonschema", .{
        .root_source_file = b.path("src/jsonschema.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "jsonschema-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "jsonschema", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run schema demo");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const schema_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsonschema", .module = mod }},
    });
    const schema_tests = b.addTest(.{ .root_module = schema_tests_mod });
    const run_schema_tests = b.addRunArtifact(schema_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_schema_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "unknown_metadata_key",
        "tests/compile_errors/unknown_metadata_key.zig",
        "error: unknown jsonschema field metadata key 'descriptoin'",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "unknown_type_metadata_key",
        "tests/compile_errors/unknown_type_metadata_key.zig",
        "error: unknown jsonschema type metadata key 'titel'",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "nonexistent_field",
        "tests/compile_errors/nonexistent_field.zig",
        "error: jsonschema metadata references unknown field 'email' on nonexistent_field.Bad",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "invalid_metadata_type",
        "tests/compile_errors/invalid_metadata_type.zig",
        "error: jsonschema field metadata key 'minLength' must be integer",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "constraint_wrong_type",
        "tests/compile_errors/constraint_wrong_type.zig",
        "error: jsonschema numeric constraint 'minimum' on non-numeric field 'constraint_wrong_type.Bad.name'",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "format_on_non_string",
        "tests/compile_errors/format_on_non_string.zig",
        "error: jsonschema string constraint 'format' on non-string field 'format_on_non_string.Bad.age'",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "examples_wrong_type",
        "tests/compile_errors/examples_wrong_type.zig",
        "error: jsonschema metadata key 'examples' must be an array",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "unsupported_type",
        "tests/compile_errors/unsupported_type.zig",
        "error: unsupported jsonschema Zig type at 'unsupported_type.Bad.callback': fn () void",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "default_wrong_type",
        "tests/compile_errors/default_wrong_type.zig",
        "error: jsonschema default at 'default_wrong_type.Bad.age' does not match field type",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "nonfinite_default",
        "tests/compile_errors/nonfinite_default.zig",
        "error: jsonschema default at 'nonfinite_default.Bad.score' does not match field type",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "enum_default_unknown",
        "tests/compile_errors/enum_default_unknown.zig",
        "error: jsonschema default at 'enum_default_unknown.Bad.role' does not match field type",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "object_default_missing_field",
        "tests/compile_errors/object_default_missing_field.zig",
        "error: jsonschema default at 'object_default_missing_field.Bad.address' does not match field type",
    );
    addCompileErrorTest(
        b,
        test_step,
        mod,
        target,
        optimize,
        "examples_incompatible",
        "tests/compile_errors/examples_incompatible.zig",
        "error: jsonschema field metadata at 'examples_incompatible.Bad.age' key 'examples' contains value that does not match u8",
    );
}

fn addCompileErrorTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    jsonschema_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    path: []const u8,
    expected: []const u8,
) void {
    const fail_mod = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsonschema", .module = jsonschema_mod }},
    });
    const fail_test = b.addTest(.{
        .name = name,
        .root_module = fail_mod,
    });
    fail_test.expect_errors = .{ .contains = expected };
    test_step.dependOn(&fail_test.step);
}
