const std = @import("std");

// Text shaping and glyph rasterisation.
//
// Two libraries, in the layering they were designed for: FreeType owns the face
// and turns a glyph into coverage, HarfBuzz turns a string into glyph indices
// and positions and reads its tables through that same face. What this module
// adds is the Zig surface over them and the vocabulary above it.
//
// The C surface is declared here rather than imported with `@cImport`. What the
// module actually calls is a dozen entry points out of some hundreds, and a
// declaration written by hand is one the compiler checks against the linker at
// the same moment as everything else in the tree.

// An opaque handle is a pointer C hands back and never lets us look inside.
const Face = opaque {};
const Library = opaque {};

extern fn FT_Init_FreeType(library: *?*Library) c_int;
extern fn FT_Done_FreeType(library: *Library) c_int;
extern fn FT_Library_Version(library: *Library, major: *c_int, minor: *c_int, patch: *c_int) void;

extern fn hb_version_string() [*:0]const u8;

pub const Error = error{
    // FreeType would not start. It allocates and it opens nothing, so this is
    // out of memory or a library built against a different configuration.
    LibraryUnavailable,
};

// What the two libraries report about themselves at run time.
//
// Read rather than assumed: this module builds them from pinned sources, and a
// version that disagrees with the pin means something else on the link line
// answered first.
pub const Versions = struct {
    freetype_major: u16,
    freetype_minor: u16,
    freetype_patch: u16,
    // HarfBuzz's own string, which is its version and nothing else. Static
    // storage inside the library, so it outlives any caller.
    harfbuzz: [:0]const u8,

    pub fn format(self: Versions, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("freetype {d}.{d}.{d}, harfbuzz {s}", .{
            self.freetype_major,
            self.freetype_minor,
            self.freetype_patch,
            self.harfbuzz,
        });
    }
};

pub fn versions() Error!Versions {
    var library: ?*Library = null;
    if (FT_Init_FreeType(&library) != 0) return error.LibraryUnavailable;
    // A library that started has a handle; FreeType reports failure through the
    // return value and leaves the handle alone otherwise.
    const started = library orelse return error.LibraryUnavailable;
    defer _ = FT_Done_FreeType(started);

    var major: c_int = 0;
    var minor: c_int = 0;
    var patch: c_int = 0;
    FT_Library_Version(started, &major, &minor, &patch);

    return .{
        .freetype_major = @intCast(major),
        .freetype_minor = @intCast(minor),
        .freetype_patch = @intCast(patch),
        .harfbuzz = std.mem.span(hb_version_string()),
    };
}
