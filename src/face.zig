const std = @import("std");
const res = @import("lenore-resources");

const Metrics = res.FontMetrics;
const SubpixelBuckets = res.SubpixelBuckets;

// A font, opened and sized, with a shaper attached to it.
//
// FreeType owns the face and turns a glyph into coverage; HarfBuzz reads the
// same face's tables to shape. The two are bound here rather than by a caller,
// because binding them has an order and a lifetime rule that are easy to get
// wrong and silent when you do.

// Handles the libraries hand back and never let us look inside.
const FtLibrary = opaque {};
// Public so that the shaper and the rasteriser reach these types rather than
// casting to their own declarations of them.
pub const FtFace = opaque {};
pub const HbFont = opaque {};

// FreeType reports through a return code; zero is success. `openError` below is
// where the codes that reach a caller are read.
extern fn FT_Init_FreeType(library: *?*FtLibrary) c_int;
extern fn FT_Done_FreeType(library: *FtLibrary) c_int;
extern fn FT_Library_Version(library: *FtLibrary, major: *c_int, minor: *c_int, patch: *c_int) void;
extern fn FT_New_Memory_Face(
    library: *FtLibrary,
    file_base: [*]const u8,
    file_size: c_long,
    face_index: c_long,
    face: *?*FtFace,
) c_int;
extern fn FT_Done_Face(face: *FtFace) c_int;
extern fn FT_Set_Pixel_Sizes(face: *FtFace, width: c_uint, height: c_uint) c_int;

extern fn hb_ft_font_create_referenced(face: *FtFace) ?*HbFont;
extern fn hb_font_get_empty() *HbFont;
extern fn hb_font_destroy(font: *HbFont) void;
extern fn hb_font_get_h_extents(font: *HbFont, extents: *Extents) c_int;
extern fn hb_version_string() [*:0]const u8;

// hb-font.h, hb_font_extents_t. The three named fields are the whole of the
// public part; the rest is reserved and is declared so the struct is the size
// HarfBuzz writes.
const Extents = extern struct {
    ascender: i32,
    descender: i32,
    line_gap: i32,
    reserved: [9]i32,
};

// Nothing here logs. A font that will not open is a condition the caller
// handed in and gets back, and whether it is worth reporting is the
// application's to decide; a library that both returns and prints makes that
// decision for it.
pub const Error = error{
    // FreeType would not start: out of memory, or a library whose
    // configuration does not match these headers.
    LibraryUnavailable,
    // The bytes are not a font, or they are a format this build registers no
    // driver for. `include/ftmodule.h` is that list.
    FontUnreadable,
    // More bytes than FreeType can be handed on this target, which takes the
    // length as a `c_long`. Two gigabytes on a 32-bit long and never on a
    // 64-bit one, so on the host this cannot occur and the check compiles out.
    FontTooLarge,
    // The file holds no face at that index. An ordinary font file holds one.
    NoSuchFace,
    // A size this face cannot be opened at: a face with fixed strikes and no
    // strike of it, or a size outside the range FreeType accepts. Scalable
    // faces take any size inside that range.
    SizeUnavailable,
    // HarfBuzz could not build a font over the face. It allocates here and
    // does nothing else, so this is out of memory.
    ShaperUnavailable,
    OutOfMemory,
};

// What a FreeType code means to a caller of `Face.open`.
//
// The codes are `include/freetype/fterrdef.h`. Only the ones a caller can act
// on differently are separated: a stream it could not read and a format it does
// not know are both bytes that are not a font this build reads, and there is
// nothing to do about either but reject them.
//
// `Invalid_Argument` is generic in FreeType and specific here. The arguments
// this module passes are its own library handle, the caller's bytes and the
// caller's face index, and the first two are checked before the call, so within
// this one call it is the index.
fn openError(code: c_int) Error {
    return switch (code) {
        0x06 => error.NoSuchFace,
        0x40 => error.OutOfMemory,
        else => error.FontUnreadable,
    };
}

// Everything FreeType needs to exist before a face does. One per application:
// it holds the module registry and the memory the faces are allocated from.
pub const Library = struct {
    handle: *FtLibrary,

    pub fn init() Error!Library {
        var handle: ?*FtLibrary = null;
        if (FT_Init_FreeType(&handle) != 0) return error.LibraryUnavailable;
        // FreeType reports failure through the code and leaves the handle
        // alone otherwise, so a zero code with no handle is not a state it
        // produces. Checked rather than asserted: the check is one branch on a
        // path taken once.
        return .{ .handle = handle orelse return error.LibraryUnavailable };
    }

    // **Every face opened from this library is closed first.** FreeType does
    // not leave a live face alone here: `FT_Done_Library` in `ftobjs.c` walks
    // the driver's face list and calls `FT_Done_Face` until it is empty, so a
    // face that is still open is destroyed rather than kept. The reference the
    // shaper holds does not protect it either, because that loop repeats until
    // the face is gone. Closing one afterwards reads freed memory.
    pub fn deinit(self: *Library) void {
        _ = FT_Done_FreeType(self.handle);
        self.* = undefined;
    }

    // What the two libraries report about themselves. Read rather than
    // assumed: this module builds them from pinned sources, and a version that
    // disagrees with the pin means something else on the link line answered
    // first.
    pub fn versions(self: Library) Versions {
        var major: c_int = 0;
        var minor: c_int = 0;
        var patch: c_int = 0;
        FT_Library_Version(self.handle, &major, &minor, &patch);
        return .{
            .freetype_major = @intCast(major),
            .freetype_minor = @intCast(minor),
            .freetype_patch = @intCast(patch),
            .harfbuzz = std.mem.span(hb_version_string()),
        };
    }
};

pub const Versions = struct {
    freetype_major: u16,
    freetype_minor: u16,
    freetype_patch: u16,
    // HarfBuzz's own string. Static storage inside the library, so it outlives
    // any caller.
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

// How much the rasteriser snaps a glyph to the pixel grid.
//
// A property of the face rather than of a call, because a cache above this
// module keys a glyph by the face it came from and by nothing else. Two modes
// over one file are two faces, and the coverage of one is never handed out for
// the other.
//
// The numbers are `lenore_glyph.h`'s, declared a second time rather than
// translated, so the two have to be changed together. What catches a
// disagreement is that the two modes rasterise differently, which
// `tests/raster.zig` measures.
pub const Hinting = enum(c_int) {
    // The outline is scaled and nothing else. What a run of text is laid out
    // from, and what a face at a size large enough for the grid not to matter
    // wants.
    //
    // The dozen faces FreeType marks tricky are the exception, and it is
    // FreeType's own: their native hinter always runs, because they use it to
    // place their subglyphs at all, and `FT_LOAD_NO_HINTING` alone is ignored
    // for them (`freetype.h`, FT_FACE_FLAG_TRICKY). Nothing here works around
    // that. The mode a caller asks for is what a hintable face gets.
    none = 0,
    // Snapped vertically only. Horizontal stems land on pixel boundaries, so
    // they resolve to one row of full coverage instead of two of half, and
    // every horizontal position stays where the unhinted outline put it.
    light = 1,
};

// There is no third mode, and that is a measurement rather than an omission.
//
// A stronger mode would have to move a glyph horizontally to be worth a name,
// and in this build nothing does. A face without bytecode is hinted by the
// autofitter, and asking it for `FT_LOAD_TARGET_NORMAL` instead of
// `FT_LOAD_TARGET_LIGHT` was measured to produce the same bearing, the same
// width and the same coverage byte for byte, over four proportional glyphs at
// six sizes. A face with bytecode is interpreted by version 40, which
// `ftoption.h` selects by defining `TT_CONFIG_OPTION_SUBPIXEL_HINTING`, and
// that interpreter denies movement along the x axis and leaves bearings and
// advances unchanged (`ttinterp.h`, the backward compatibility list).
//
// So a caller mapping a host preference with more steps than this enum has
// loses nothing by folding them onto `light`. What it must not do is pretend
// the steps exist here.

// How coverage is measured across a pixel.
//
// A property of the face for the reason hinting is: it decides what a glyph of
// it looks like, and the cache above keys by the face.
//
// The numbers are `lenore_glyph.h`'s, declared a second time rather than
// translated. What catches a disagreement is that the two modes produce a
// different number of channels, which `tests/raster.zig` measures.
pub const Antialias = enum(c_int) {
    // One coverage per pixel, which is what a display with no fixed subpixel
    // order can show and what an atlas of a single channel holds.
    grayscale = 0,
    // One per colour stripe. It triples the horizontal resolution of a display
    // whose stripes are where the rasteriser was told they are, and it is wrong
    // on one whose are not, so the choice belongs to whoever asked the host.
    subpixel = 1,

    pub fn channels(self: Antialias) u32 {
        return switch (self) {
            .grayscale => 1,
            .subpixel => 3,
        };
    }
};

pub const Options = struct {
    // Which face of a collection. Zero is the only face of an ordinary font
    // file.
    face_index: u32 = 0,
    // The size the face is opened at, in pixels, and the one it keeps. From
    // one to 65535: `open` refuses the rest rather than letting FreeType clamp
    // them into a face whose size is not the one that was asked for.
    pixel_size: u32,
    // The outline as it was designed, unless a caller asks otherwise. Which
    // mode reads better is a judgement about a display and a size, and this
    // module knows neither.
    hinting: Hinting = .none,
    // How many horizontal rasterisations of each glyph this face has. One is
    // the glyph on the pixel grid and nothing else, which is what a face large
    // enough for half a pixel not to matter wants. Where that size is is a
    // judgement about a display, so it is not made here either.
    subpixel: SubpixelBuckets = .whole,
    // One coverage per pixel unless a caller knows the display's stripe order,
    // which this module has no way to ask about.
    antialias: Antialias = .grayscale,
};

// **One thread at a time.** Shaping and rasterising both reach the same
// `FT_Face`, and FreeType's model is that a face may be used from one thread at
// a time while a library may be shared between them, with face creation and
// destruction under a lock of the caller's (`docs/CHANGES`, the entry for 2.6).
// So a face is one thread's for as long as it draws with it, and a shaper being
// per-thread does not make two of them independent: it is the face they share
// that decides.
pub const Face = struct {
    ft: *FtFace,
    font: *HbFont,
    hinting: Hinting,
    subpixel: SubpixelBuckets,
    antialias: Antialias,

    // How far right the outline is moved for `bucket`, in the sixty-fourths of
    // a pixel FreeType scales an outline onto.
    //
    // Exact for every count this enum admits: 64 divides by one, two and four
    // without a remainder, so a bucket is a whole number of sixty-fourths and
    // no rasterisation lands between two of them. A count that did not divide
    // 64 would put the buckets at uneven spacings, which is the one thing the
    // arithmetic in `lenore-resources` assumes away.
    pub fn shiftOf(self: Face, bucket: u8) i32 {
        return @intCast(bucket * (64 / self.subpixel.count()));
    }

    // Opens `bytes` at a pixel size and binds a shaper to the result.
    //
    // **The bytes are the caller's and must outlive the face.** FreeType parses
    // them in place and keeps the pointer: `FT_New_Memory_Face` states that the
    // memory must not be deallocated before `FT_Done_Face`. Nothing here copies
    // them, which is the point on a path that loads a font once and shapes
    // against it for the life of a program.
    //
    // The size is fixed here and cannot be changed afterwards. HarfBuzz reads
    // the face's size when the font is created and caches the scale from it —
    // `hb-ft.h` says to set the size first — so a face that could be resized
    // would need every shaper over it told, and a missed call is a run of text
    // measured at the wrong size with nothing to report. A second size is a
    // second face over the same bytes.
    //
    // The hinting mode and the subpixel count are fixed here for the same
    // reason the size is: together they are what a glyph of this face looks
    // like, and a cache above keys glyphs by the face. The shaper is unaffected
    // by either, because HarfBuzz reads an advance off the face's own table
    // rather than off a rasterisation.
    pub fn open(library: Library, bytes: []const u8, options: Options) Error!Face {
        // Three values that would otherwise be narrowed or clamped inside the
        // calls below, each turning a caller's mistake into a face that is not
        // the one it asked for.
        //
        // The length and the index are `c_long` to FreeType, which is 32 bits
        // on Windows, so a file above two gigabytes or an index above two
        // billion would arrive negative there. The size is worse, because
        // FreeType does not refuse it at all: `FT_Set_Pixel_Sizes` in
        // `ftobjs.c` raises a zero to one and lowers anything above 0xFFFF to
        // 0xFFFF, then reports success, and the face would keep a size nothing
        // above it could tell from the one it named.
        if (bytes.len > std.math.maxInt(c_long)) return error.FontTooLarge;
        if (options.face_index > std.math.maxInt(c_long)) return error.NoSuchFace;
        if (options.pixel_size == 0 or options.pixel_size > 0xFFFF) return error.SizeUnavailable;

        var ft: ?*FtFace = null;
        const opened = FT_New_Memory_Face(
            library.handle,
            bytes.ptr,
            @intCast(bytes.len),
            @intCast(options.face_index),
            &ft,
        );
        if (opened != 0) return openError(opened);
        const face = ft orelse return error.FontUnreadable;
        errdefer _ = FT_Done_Face(face);

        // A width of zero takes the height for both, which is what a square
        // pixel grid wants and what every consumer here asks for.
        if (FT_Set_Pixel_Sizes(face, 0, options.pixel_size) != 0) return error.SizeUnavailable;

        // The referencing form, so the shaper holds the face alive on its own
        // account. The two are then destroyed in either order, and the hazard
        // of outliving one with the other does not arise.
        //
        // Out of memory is not a null here, which is why the singleton is
        // compared for as well. `hb_font_create` answers a failed allocation
        // with the immutable empty font rather than with nothing
        // (`hb-font.cc`, `_hb_font_create`), and `hb_ft_font_create` hands
        // that straight back, so a caller that took it would shape every
        // string to nothing and read every metric as zero. It is static, so
        // there is nothing to give back; the reference this call took on the
        // face was already released along that path, and the `errdefer` above
        // releases ours.
        const font = hb_ft_font_create_referenced(face) orelse return error.ShaperUnavailable;
        if (font == hb_font_get_empty()) return error.ShaperUnavailable;
        return .{
            .ft = face,
            .font = font,
            .hinting = options.hinting,
            .subpixel = options.subpixel,
            .antialias = options.antialias,
        };
    }

    // Gives back both references this face holds. The bytes it was opened over
    // are the caller's and are not touched.
    pub fn deinit(self: *Face) void {
        hb_font_destroy(self.font);
        _ = FT_Done_Face(self.ft);
        self.* = undefined;
    }

    // The face's own line metrics.
    //
    // Taken through the shaper rather than off the face, because that is the
    // scale a shaped position is in and the two must not come from separate
    // readings. HarfBuzz reports them in 26.6 fixed point, which the division
    // below is the whole of: a sixty-fourth of a pixel is the grid every
    // position in this module lands on.
    pub fn metrics(self: Face) Metrics {
        var extents: Extents = undefined;
        if (hb_font_get_h_extents(self.font, &extents) == 0) {
            // A face with no horizontal metrics at all. Vertical-only fonts
            // exist and this module has nothing to say about them, so the line
            // is reported as having no height rather than as a failure a
            // caller would have to handle at every call site.
            return .zero;
        }
        return .{
            .ascent = fixedToPixels(extents.ascender),
            .descent = fixedToPixels(extents.descender),
            .line_gap = fixedToPixels(extents.line_gap),
        };
    }
};

// 26.6 fixed point to pixels. The division is exact, its divisor being a power
// of two; what limits the conversion is f32's 24-bit mantissa, above which the
// integer this reads no longer has an exact float. A position at this scale is
// a pixel count times 64, so that limit is 262144 pixels from the origin and
// every value a laid-out line of text carries is far inside it.
pub fn fixedToPixels(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}
