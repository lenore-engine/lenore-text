const std = @import("std");
const res = @import("lenore-resources");

const face_module = @import("face.zig");

const Face = face_module.Face;
const Glyph = res.ShapedGlyph;
const fixedToPixels = face_module.fixedToPixels;

// Turning a string into positioned glyphs.
//
// This is the whole of what HarfBuzz is for: which glyph a character becomes
// depends on the characters around it, on the font's substitution tables and on
// the script, and none of that is a mapping a caller could do itself.

const HbBuffer = opaque {};
const HbFont = face_module.HbFont;

extern fn hb_buffer_create() ?*HbBuffer;
extern fn hb_buffer_destroy(buffer: *HbBuffer) void;
extern fn hb_buffer_clear_contents(buffer: *HbBuffer) void;
extern fn hb_buffer_pre_allocate(buffer: *HbBuffer, size: c_uint) c_int;
extern fn hb_buffer_allocation_successful(buffer: *HbBuffer) c_int;
extern fn hb_buffer_add_utf8(
    buffer: *HbBuffer,
    text: [*]const u8,
    text_length: c_int,
    item_offset: c_uint,
    item_length: c_int,
) void;
extern fn hb_buffer_guess_segment_properties(buffer: *HbBuffer) void;
// Both hand back the buffer's own arrays, and a buffer that has never been
// grown has none: `hb_buffer_get_glyph_infos` in `hb-buffer.cc` returns
// `buffer->info` whatever it is, and that is null until something is allocated
// in it. So the pointers are optional here, which is what a shaper made with no
// capacity and asked for an empty run produces.
extern fn hb_buffer_get_glyph_infos(buffer: *HbBuffer, length: *c_uint) ?[*]const Info;
extern fn hb_buffer_get_glyph_positions(buffer: *HbBuffer, length: *c_uint) ?[*]const Position;
extern fn hb_shape(font: *HbFont, buffer: *HbBuffer, features: ?*const anyopaque, count: c_uint) void;

// hb-buffer.h, hb_glyph_info_t and hb_glyph_position_t. The private members are
// declared because the structs are read out of an array HarfBuzz laid out, so
// the stride has to match; `hb_var_int_t` is a four-byte union.
const Info = extern struct {
    codepoint: u32,
    mask: u32,
    cluster: u32,
    var1: u32,
    var2: u32,
};

const Position = extern struct {
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
    private: u32,
};

comptime {
    // The stride the two arrays are indexed by. Five four-byte members each and
    // no padding, so this holds unless a member is added or retyped, which is
    // exactly when reading them would start returning the wrong glyph.
    std.debug.assert(@sizeOf(Info) == 20);
    std.debug.assert(@sizeOf(Position) == 20);
}

pub const Error = error{
    ShaperUnavailable,
    // The run produced more glyphs than the destination holds. Nothing is
    // written: a half-written run would be a line of text with its end missing
    // and no sign of it.
    GlyphsDoNotFit,
    // More text in one run than HarfBuzz takes: it measures a run with a signed
    // int, so two gigabytes is the ceiling. A label is nowhere near it and a
    // document is not one run.
    TextTooLong,
    OutOfMemory,
};

// A reusable shaping buffer.
//
// Kept for the life of the program rather than made per call: HarfBuzz
// allocates inside it, and a buffer that is cleared and refilled reaches its
// high-water mark once and never allocates again. That is what keeps a
// per-frame path free of the allocator.
//
// One per thread that shapes, and that is a floor rather than the whole rule:
// `shape` reaches the face as well, and a face is one thread's at a time. Two
// shapers over one face are two threads in the same `FT_Face`, which is the
// thing FreeType's model does not allow.
pub const Shaper = struct {
    buffer: *HbBuffer,

    // `capacity` is how many glyphs the buffer is asked to hold before it is
    // first used. Exceeding it costs an allocation and nothing else, so this is
    // a figure to set from what an application draws rather than a limit.
    pub fn init(capacity: u32) Error!Shaper {
        const buffer = hb_buffer_create() orelse return error.ShaperUnavailable;
        errdefer hb_buffer_destroy(buffer);

        // HarfBuzz reports failure by leaving the buffer in an error state
        // rather than by returning, here and everywhere below.
        _ = hb_buffer_pre_allocate(buffer, capacity);
        if (hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        return .{ .buffer = buffer };
    }

    pub fn deinit(self: *Shaper) void {
        hb_buffer_destroy(self.buffer);
        self.* = undefined;
    }

    // Shapes `text` with `face` and writes the result into `out`, returning how
    // many glyphs it wrote.
    //
    // The count is not the length of the text and cannot be derived from it.
    // Substitution merges characters into one glyph and decomposition splits
    // one into several, so `out` is sized from what an application draws and a
    // run that overruns it is refused rather than truncated.
    //
    // Direction, script and language are guessed from the text itself, which is
    // what `hb_buffer_guess_segment_properties` does: the first character with
    // a strong direction decides. That is right for a label and wrong for a run
    // that mixes scripts, which is a case this module will have to be told
    // about rather than left to guess.
    pub fn shape(self: *Shaper, font: Face, text: []const u8, out: []Glyph) Error!usize {
        // Refused rather than narrowed, because the narrowing has a meaning of
        // its own. Both lengths below are a signed int to HarfBuzz and -1 is a
        // value in each: a text length of -1 says the string is NUL-terminated,
        // an item length of -1 says the rest of it. A slice that did not fit
        // would arrive as some other length, or as an instruction to read past
        // its end.
        if (text.len > std.math.maxInt(c_int)) return error.TextTooLong;

        hb_buffer_clear_contents(self.buffer);
        hb_buffer_add_utf8(self.buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb_buffer_guess_segment_properties(self.buffer);
        hb_shape(font.font, self.buffer, null, 0);
        if (hb_buffer_allocation_successful(self.buffer) == 0) return error.OutOfMemory;

        var info_count: c_uint = 0;
        var position_count: c_uint = 0;
        const infos = hb_buffer_get_glyph_infos(self.buffer, &info_count);
        const positions = hb_buffer_get_glyph_positions(self.buffer, &position_count);
        // The two arrays are one buffer read two ways, so a disagreement is
        // HarfBuzz contradicting itself rather than anything a caller did.
        std.debug.assert(info_count == position_count);

        const count: usize = info_count;
        if (count > out.len) return error.GlyphsDoNotFit;
        // The count is what decides whether either array is read, so a buffer
        // that has none is a run of no glyphs rather than a null to bound a
        // slice on. A count with no array behind it is HarfBuzz contradicting
        // itself, the same disagreement the assertion above covers, and it is
        // answered rather than asserted because an assertion is not there in
        // the shipping build.
        if (count == 0) return 0;
        const info_array = infos orelse return error.ShaperUnavailable;
        const position_array = positions orelse return error.ShaperUnavailable;

        for (info_array[0..count], position_array[0..count], out[0..count]) |info, position, *glyph| {
            glyph.* = .{
                .index = info.codepoint,
                .cluster = info.cluster,
                .x_advance = fixedToPixels(position.x_advance),
                .y_advance = fixedToPixels(position.y_advance),
                .x_offset = fixedToPixels(position.x_offset),
                .y_offset = fixedToPixels(position.y_offset),
            };
        }
        return count;
    }
};

// How wide a shaped run is: the sum of what each glyph moves the pen by.
//
// Separate from `shape` because measuring and drawing want the same numbers off
// the same run: a caller that lays out and then draws shapes once and asks both
// questions of what it got. It is what a layout puts in a node's intrinsic
// size.
//
// The glyphs are the input, so this measures a run rather than a string. A
// caller that wants only a width still shapes into a destination of its own
// first, which is the cost of the width and not of drawing it.
pub fn advance(glyphs: []const Glyph) f32 {
    var total: f32 = 0;
    for (glyphs) |glyph| total += glyph.x_advance;
    return total;
}
