//! Runs the official JSON-Schema-Test-Suite (draft2020-12) against the validator.
//!
//! Usage: suite_runner [--optional] [--format] [--verbose] [file-substring]

const std = @import("std");
const jsonschema = @import("jsonschema");

const suite_dir = "tests/suite/tests";
const remotes_dir = "tests/suite/remotes";
const remote_base = "http://localhost:1234/";

const Remote = struct { uri: []const u8, value: *std.json.Value };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var include_optional = false;
    var include_format = false;
    var verbose = false;
    var filter: ?[]const u8 = null;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = arg_it.next(); // program name
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--optional")) {
            include_optional = true;
        } else if (std.mem.eql(u8, a, "--format")) {
            include_format = true;
            include_optional = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else {
            filter = try arena.dupe(u8, a);
        }
    }

    const io = init.io;

    // Load remotes and the dialect meta-schemas once.
    var remotes: std.ArrayListUnmanaged(Remote) = .empty;
    try loadRemotes(io, arena, &remotes);
    try loadMetaschemas(io, arena, &remotes);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const w = &stdout.interface;

    var total: usize = 0;
    var passed: usize = 0;
    var failed_groups: usize = 0;

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectFiles(io, arena, suite_dir, include_optional, include_format, &files);
    std.mem.sort([]const u8, files.items, {}, lessStr);

    for (files.items) |path| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, path, f) == null) continue;
        }
        const r = try runFile(io, gpa, arena, path, remotes.items, w, verbose);
        total += r.total;
        passed += r.passed;
        failed_groups += r.failed_groups;
    }

    try w.print("\n== {d}/{d} assertions passed ({d} failed) ==\n", .{ passed, total, total - passed });
    try w.flush();
    if (passed != total) std.process.exit(1);
}

const FileResult = struct { total: usize = 0, passed: usize = 0, failed_groups: usize = 0 };

fn runFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    remotes: []const Remote,
    w: *std.Io.Writer,
    verbose: bool,
) !FileResult {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
    if (parsed != .array) return .{};

    var result: FileResult = .{};
    for (parsed.array.items) |*group| {
        if (group.* != .object) continue;
        const schema = group.object.getPtr("schema") orelse continue;
        const tests = group.object.getPtr("tests") orelse continue;
        const group_desc = if (group.object.getPtr("description")) |d| d.string else "";

        // The optional/format suite exercises `format` as an assertion.
        const assert_format = std.mem.indexOf(u8, path, "optional/format/") != null;
        var v = try jsonschema.Validator.init(gpa, .{ .assert_format = assert_format });
        defer v.deinit();
        for (remotes) |rem| try v.addResource(rem.uri, rem.value);
        v.setRootSchema(schema) catch {
            // schema with constructs we can't even index: count its tests failed
            for (tests.array.items) |_| {
                result.total += 1;
                result.failed_groups += 1;
            }
            continue;
        };

        for (tests.array.items) |*t| {
            if (t.* != .object) continue;
            const data_v = t.object.getPtr("data") orelse continue;
            const want = (t.object.getPtr("valid") orelse continue).bool;
            const test_desc = if (t.object.getPtr("description")) |d| d.string else "";

            result.total += 1;
            var errs: std.ArrayListUnmanaged(jsonschema.ValidationError) = .empty;
            const got = v.validate(data_v, &errs) catch |e| {
                if (verbose) try w.print("ERROR {s} / {s} / {s}: {s}\n", .{ path, group_desc, test_desc, @errorName(e) });
                continue;
            };
            if (got == want) {
                result.passed += 1;
            } else if (verbose) {
                try w.print("FAIL {s}\n   group: {s}\n   test:  {s}\n   want valid={}, got {}\n", .{ path, group_desc, test_desc, want, got });
                for (errs.items) |er| try w.print("     - {s}: {s}\n", .{ er.instance_path, er.message });
            }
        }
    }
    return result;
}

fn loadRemotes(io: std.Io, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(Remote)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, remotes_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;
        const full = try std.fs.path.join(arena, &.{ remotes_dir, entry.path });
        const data = try std.Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch continue;
        const vptr = try arena.create(std.json.Value);
        vptr.* = parsed;
        // Normalize path separators to '/'.
        const rel = try arena.dupe(u8, entry.path);
        for (rel) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        const uri = try std.mem.concat(arena, u8, &.{ remote_base, rel });
        try out.append(arena, .{ .uri = uri, .value = vptr });
    }
}

const metaschema_dir = "tests/suite/metaschema";

/// Load the vendored dialect/vocabulary meta-schemas, keyed by their `$id`.
fn loadMetaschemas(io: std.Io, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(Remote)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, metaschema_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;
        const full = try std.fs.path.join(arena, &.{ metaschema_dir, entry.path });
        const data = try std.Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch continue;
        const vptr = try arena.create(std.json.Value);
        vptr.* = parsed;
        const id = if (parsed == .object) (if (parsed.object.getPtr("$id")) |i| i.string else continue) else continue;
        try out.append(arena, .{ .uri = try arena.dupe(u8, id), .value = vptr });
    }
}

fn collectFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    include_optional: bool,
    include_format: bool,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            try out.append(arena, try std.fs.path.join(arena, &.{ dir_path, entry.name }));
        } else if (entry.kind == .directory) {
            const is_format = std.mem.eql(u8, entry.name, "format");
            const is_optional = std.mem.eql(u8, entry.name, "optional");
            if (is_optional and !include_optional) continue;
            if (is_format and !include_format) continue;
            const sub = try std.fs.path.join(arena, &.{ dir_path, entry.name });
            try collectFiles(io, arena, sub, include_optional, include_format, out);
        }
    }
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
