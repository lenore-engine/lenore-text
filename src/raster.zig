const std = @import("std");

const face_module = @import("face.zig");

const Face = face_module.Face;
const FtFace = face_module.FtFace;

// One glyph, rasterised to eight-bit coverage.
//
// The rendering itself is FreeType's and the reading of its result is
// `lenore_glyph.c`, which exists because a rendered glyph lives in fields of
// FreeType's own structs. What is added here is the bound: the shim hands back
// a pointer and a size, and nothing below this file sees either.

// `lenore_glyph.h`, `lenore_glyph_coverage`. Declared a second time rather than
// translated, so the two have to be changed together. Nothing on this side can
// check that they agree; what checks it is a rasterised glyph whose size and
// coverage are known, which is what `tests/raster.zig` renders.
const Raw = extern struct {
    pixels: ?[*]const u8,
    pitch: u32,
    width: u32,
    rows: u32,
    channels: u32,
    left: i32,
    top: i32,
};

const not_coverage = -1;
const bottom_up = -2;

extern fn lenore_render_glyph(
    face: *FtFace,
    glyph_index: u32,
    hinting: c_int,
    antialias: c_int,
    x_shift: c_int,
    out: *Raw,
) c_int;

pub const Error = error{
    // The index is not a glyph of this face. Glyph indices come from shaping
    // and are the face's own, so this is a caller mixing two faces up rather
    // than anything a font did.
    NoSuchGlyph,
    // The glyph rendered into a colour or embedded bitmap. Those are a feature
    // of their own and this module produces coverage.
    NotCoverage,
    // Stored bottom row first, which the anti-aliased renderer does not
    // produce and this module does not reverse.
    BottomUpBitmap,
    OutOfMemory,
    // Anything else FreeType reported while loading or rendering.
    GlyphUnreadable,
};

// The coverage of one glyph and where it sits relative to the pen.
//
// **Borrowed.** `bytes` points into the face's glyph slot, which FreeType
// reuses, so it is valid only until the next glyph is rendered on that face.
// Copy what is wanted before rendering the next one. This is FreeType's own
// contract and no arrangement here removes it: the alternative is a second copy
// of every glyph, and the one consumer is an atlas that copies immediately.
pub const Coverage = struct {
    // `pitch * rows` bytes, or empty for a glyph with nothing to draw.
    bytes: []const u8,
    // The byte distance from one row to the next, at least `width * channels`.
    // Rows are padded, so this is not the width in any units.
    pitch: u32,
    // In pixels, whichever mode rendered it.
    width: u32,
    rows: u32,
    // Bytes per pixel: one coverage for a grayscale glyph, three for a
    // subpixel one. Read off the result rather than off the face, because an
    // embedded bitmap comes back grayscale whatever was asked for.
    channels: u32,
    // Where the coverage sits against the pen: `left` along the baseline and
    // `top` up from it to the first row. Both are signed, and a glyph that
    // hangs below the baseline or behind the pen is ordinary rather than
    // exceptional.
    left: i32,
    top: i32,

    // A glyph with nothing to draw. A space is the common one, and it still
    // advances the pen: the advance is the shaper's and has nothing to do with
    // whether there is ink.
    pub fn isBlank(self: Coverage) bool {
        return self.rows == 0 or self.width == 0;
    }

    // One row of coverage from the top down, `width * channels` bytes: a
    // grayscale glyph's is one per pixel and a subpixel glyph's is three, in
    // the order the stripes are. The padding each row may carry beyond that is
    // not part of the glyph and is not returned.
    pub fn row(self: Coverage, index: u32) []const u8 {
        std.debug.assert(index < self.rows);
        const start = index * self.pitch;
        return self.bytes[start..][0 .. self.width * self.channels];
    }
};

// Rasterises `glyph_index` of `font` at one of the face's subpixel buckets, in
// the hinting and antialiasing modes the face was opened with.
//
// The index is the one shaping produced for this same face. Nothing checks that
// the two match, because nothing can: an index is a number and every face has
// its own meaning for it. A wrong one draws a wrong glyph rather than failing,
// which is why the two come from one `Face` here.
//
// `bucket` is below the face's count, which is what `subpixelSplit` in
// `lenore-resources` answers with. A face of one bucket takes zero and the
// shift is nothing, so the unshifted glyph costs no branch of its own.
pub fn render(font: Face, glyph_index: u32, bucket: u8) Error!Coverage {
    var raw: Raw = undefined;
    const code = lenore_render_glyph(
        font.ft,
        glyph_index,
        @intFromEnum(font.hinting),
        @intFromEnum(font.antialias),
        font.shiftOf(bucket),
        &raw,
    );
    if (code != 0) return renderError(code);

    // The shim produces one channel or three and refuses every other pixel
    // format, so this is that contract checked once where the value crosses
    // into Zig. What it buys is that everything downstream may switch on the
    // count without a case for the impossible: the atlas does.
    if (raw.channels != 1 and raw.channels != 3) return error.NotCoverage;

    // A glyph with no ink reports no rows, and its pointer is null. Bounding an
    // empty slice on a null pointer is the one case that has to be spelled out.
    const pixels = raw.pixels orelse return .{
        .bytes = &.{},
        .pitch = 0,
        .width = 0,
        .rows = 0,
        .channels = raw.channels,
        .left = raw.left,
        .top = raw.top,
    };

    // Where the pointer becomes a slice, and the only place this module reads
    // FreeType's memory without a length. `pitch` is at least `width` times
    // `channels` by the shim's contract, so the rows a caller asks for are
    // inside it.
    const length = @as(usize, raw.pitch) * @as(usize, raw.rows);
    return .{
        .bytes = pixels[0..length],
        .pitch = raw.pitch,
        .width = raw.width,
        .rows = raw.rows,
        .channels = raw.channels,
        .left = raw.left,
        .top = raw.top,
    };
}

// FreeType's codes are `include/freetype/fterrdef.h`; the two negative ones are
// the shim's own and are declared beside it.
fn renderError(code: c_int) Error {
    return switch (code) {
        not_coverage => error.NotCoverage,
        bottom_up => error.BottomUpBitmap,
        // Measured: an index past the face's glyph count comes back as
        // Invalid_Argument and not as Invalid_Glyph_Index, which is the code
        // the name would suggest. Both are mapped, because which one a driver
        // answers with is the driver's business.
        0x06, 0x10 => error.NoSuchGlyph,
        // Invalid_Glyph_Format and Cannot_Render_Glyph. A glyph whose shape
        // this build has no module for reaches a caller as the same answer as
        // a colour one: there is no coverage to be had. `include/ftmodule.h`
        // is the list that decides it, and the outline formats are in it.
        0x12, 0x13 => error.NotCoverage,
        0x40 => error.OutOfMemory,
        else => error.GlyphUnreadable,
    };
}
