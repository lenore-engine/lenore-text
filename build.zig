const std = @import("std");

// Shaping and glyph rasterisation, over FreeType and HarfBuzz.
//
// Both are built from their own release tarballs rather than linked from the
// system, so a run is reproducible from the hashes in `build.zig.zon` and the
// flags below rather than from whatever the host happens to have installed.

// FreeType, one file per module. The set is the one the linker demands for what
// `ftmodule.h` registers, which is narrower than the library's default: the
// three beyond the drivers are there because HarfBuzz's FreeType bridge reaches
// them. `ftbitmap` for FT_Bitmap_Convert, `ftmm` for FT_Set_Named_Instance, and
// `ftgzip` because FT_CONFIG_OPTION_USE_ZLIB is on by default and FreeType
// carries its own zlib rather than wanting one from outside.
const freetype_sources = [_][]const u8{
    "base/ftbase.c",
    "base/ftbitmap.c",
    "base/ftdebug.c",
    "base/ftinit.c",
    "base/ftmm.c",
    "base/ftsystem.c",
    "gzip/ftgzip.c",

    "autofit/autofit.c",
    "cff/cff.c",
    "psaux/psaux.c",
    "psnames/psnames.c",
    "pshinter/pshinter.c",
    "sfnt/sfnt.c",
    "smooth/smooth.c",
    "truetype/truetype.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const freetype = b.dependency("freetype", .{});
    const harfbuzz = b.dependency("harfbuzz", .{});
    const resource = b.dependency("lenore_resources", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("lenore-text", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "lenore-resources", .module = resource.module("lenore-resources") },
        },
        .target = target,
        .optimize = optimize,
    });

    mod.addCSourceFiles(.{
        .root = freetype.path("src"),
        .files = &freetype_sources,
        // FT2_BUILD_LIBRARY is what tells the headers they are being compiled
        // into the library rather than included by a consumer. The module list
        // is ours: the angle form needs no shell quoting and resolves against
        // the include path added below.
        .flags = &.{
            "-DFT2_BUILD_LIBRARY",
            "-DFT_CONFIG_MODULES_H=<ftmodule.h>",
        },
    });

    // One translation unit. `harfbuzz.cc` includes every other source, which is
    // upstream's own single-file build, and the platform backends inside it
    // compile to nothing without their HAVE_ macro. So the FreeType bridge is
    // the one define below and there is no file list to keep current.
    mod.addCSourceFiles(.{
        .root = harfbuzz.path("src"),
        .files = &.{"harfbuzz.cc"},
        // No exceptions and no RTTI: HarfBuzz uses neither, and it is reached
        // through a C surface that could not carry either.
        .flags = &.{
            "-DHAVE_FREETYPE=1",
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
        },
    });

    // Ours: the shim that reads a rendered glyph out of FreeType's structs,
    // where the header rather than a second declaration is the authority.
    mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"lenore_glyph.c"},
        .flags = &.{"-std=c11"},
    });

    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(freetype.path("include"));
    mod.addIncludePath(harfbuzz.path("src"));
    mod.link_libcpp = true;

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = testRoot(b, "tests"),
            .imports = &.{
                .{ .name = "lenore-text", .module = mod },
                // The suite names the vocabulary directly, as a consumer of this
                // module does: a shaped glyph and a placement are
                // `lenore-resources` declarations and are not re-exported here.
                .{ .name = "lenore-resources", .module = resource.module("lenore-resources") },
            },
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // addTest collects test blocks from the root module of its compilation
    // only. The suite above imports this module rather than being it, so a
    // `test` written beside the code in src/ would never run and would stay
    // green forever. This second binary is that module.
    const module_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
}

fn zigFilesIn(b: *std.Build, dir_path: []const u8) [][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.items,
        else => std.debug.panic("cannot open {s}/: {t}", .{ dir_path, err }),
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch @panic("cannot list the directory")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
            return std.mem.order(u8, a, b_) == .lt;
        }
    }.lessThan);
    return names.items;
}

// Generates the test root by listing the directory, so a new test file needs no
// registration.
//
// This cannot be done at comptime: `@import` takes a string literal and there is
// no filesystem at comptime. Zig analyses lazily, so a test file nobody imports
// is silently not run.
fn testRoot(b: *std.Build, dir_path: []const u8) std.Build.LazyPath {
    var source: std.ArrayList(u8) = .empty;
    source.appendSlice(b.allocator, "// Generated by build.zig from the test directory. Do not edit.\ntest {\n") catch @panic("OOM");
    for (zigFilesIn(b, dir_path)) |name|
        source.print(b.allocator, "    _ = @import(\"{s}/{s}\");\n", .{ dir_path, name }) catch @panic("OOM");
    source.appendSlice(b.allocator, "}\n") catch @panic("OOM");

    const generated = b.addWriteFiles();
    _ = generated.addCopyDirectory(b.path(dir_path), dir_path, .{});
    return generated.add("test_root.zig", source.items);
}
