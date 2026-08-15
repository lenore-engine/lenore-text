const std = @import("std");
const text = @import("lenore-text");

const testing = std.testing;

// Ahem, from the W3C CSS test suite, embedded rather than read from a path.
// A module tests from its own directory, and the one font every host is
// guaranteed to have is the one carried here.
//
// It is this font and not a typeface because its metrics are defined rather
// than designed: the em is 1000 units, every glyph advances exactly one em, the
// ascent is 800 and the descent -200, and a lettered glyph is a solid rectangle
// filling the em. Every number below is derived from those four facts and the
// pixel size, so a test that fails says the code is wrong rather than that the
// font changed. What it cannot answer is anything about shaping features: it
// carries no `GSUB`, `GPOS` or `kern` table at all.
const ahem = @embedFile("fonts/Ahem.ttf");

// The size everything here is opened at. Sixteen, so that one em is sixteen
// pixels and the 26.6 grid the libraries report on divides it exactly.
const pixel_size = 16;

// One step of that grid, and the tolerance every metric below is compared with.
// Ahem's ascent is 0.8 em, which is 12.8 pixels and not a whole number of
// sixty-fourths away from anything, so the reported value is the true one
// rounded onto the grid and can be off by one step.
const grid = 1.0 / 64.0;

test "a face opens over the caller's bytes and reports the font's metrics" {
    var library: text.Library = try .init();
    defer library.deinit();

    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer face.deinit();

    const metrics = face.metrics();
    // 800 and -200 of a 1000-unit em, at sixteen pixels to the em.
    try testing.expectApproxEqAbs(@as(f32, 12.8), metrics.ascent, grid);
    try testing.expectApproxEqAbs(@as(f32, -3.2), metrics.descent, grid);
    try testing.expectApproxEqAbs(@as(f32, 0), metrics.line_gap, grid);
    // The two together are the whole em, and Ahem asks for no gap between
    // lines, so a line is exactly the size the face was opened at.
    try testing.expectApproxEqAbs(@as(f32, 16), metrics.lineHeight(), 2 * grid);
}

test "the size a face is opened at is the size it measures" {
    var library: text.Library = try .init();
    defer library.deinit();

    // Doubling the size doubles every metric, because they are all fractions of
    // the em and the em is the size.
    var small: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer small.deinit();
    var large: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size * 2 });
    defer large.deinit();

    try testing.expectApproxEqAbs(2 * small.metrics().ascent, large.metrics().ascent, grid);
    try testing.expectApproxEqAbs(@as(f32, 32), large.metrics().lineHeight(), 2 * grid);
}

// Font files come from outside and a wrong one is a runtime condition, not a
// programmer's mistake. It has to reach the caller as an error in every build
// mode: an assertion here would be removed in the shipping one and leave
// FreeType parsing whatever was handed to it.
test "bytes that are not a font are refused rather than trusted" {
    var library: text.Library = try .init();
    defer library.deinit();

    try testing.expectError(error.FontUnreadable, text.Face.open(library, "not a font", .{ .pixel_size = pixel_size }));
    try testing.expectError(error.FontUnreadable, text.Face.open(library, "", .{ .pixel_size = pixel_size }));
    // A real font, but no face at that index: an ordinary file holds one, and
    // the caller gets an error that says which of the two was wrong.
    try testing.expectError(error.NoSuchFace, text.Face.open(library, ahem, .{ .face_index = 7, .pixel_size = pixel_size }));
}

// FreeType clamps a size instead of refusing it: `FT_Set_Pixel_Sizes` in
// `ftobjs.c` raises a zero to one and lowers anything above 0xFFFF to 0xFFFF,
// then returns success. A face would keep a size that is not the one it was
// opened at, and every metric read off it would be right for a size nobody
// asked for. These are the two ends of that, and 0xFFFF itself is admitted
// because it is the value FreeType clamps to.
test "a size FreeType would silently change is refused instead" {
    var library: text.Library = try .init();
    defer library.deinit();

    try testing.expectError(error.SizeUnavailable, text.Face.open(library, ahem, .{ .pixel_size = 0 }));
    try testing.expectError(error.SizeUnavailable, text.Face.open(library, ahem, .{ .pixel_size = 0x10000 }));

    var largest: text.Face = try .open(library, ahem, .{ .pixel_size = 0xFFFF });
    defer largest.deinit();
    // Ahem's ascent is 0.8 em, so a face at the largest admitted size measures
    // it at four fifths of that size and not at four fifths of a clamp.
    try testing.expectApproxEqAbs(@as(f32, 0.8 * 0xFFFF), largest.metrics().ascent, 1);
}
