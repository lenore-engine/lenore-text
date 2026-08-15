const std = @import("std");
const res = @import("lenore-resources");
const text = @import("lenore-text");

const testing = std.testing;

const ahem = @embedFile("fonts/Ahem.ttf");
const pixel_size = 16;

// One em is `pixel_size` pixels and every Ahem glyph advances exactly one em,
// so a run of n glyphs is n times this and the number is exact in f32.
const em = @as(f32, pixel_size);

fn shaped(shaper: *text.Shaper, face: text.Face, source: []const u8, out: []res.ShapedGlyph) ![]res.ShapedGlyph {
    const count = try shaper.shape(face, source, out);
    return out[0..count];
}

test "a run of characters becomes a run of glyphs that advance by the em" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer face.deinit();
    var shaper: text.Shaper = try .init(64);
    defer shaper.deinit();

    var storage: [64]res.ShapedGlyph = undefined;
    const glyphs = try shaped(&shaper, face, "XXX", &storage);

    try testing.expectEqual(@as(usize, 3), glyphs.len);
    for (glyphs) |glyph| {
        try testing.expectEqual(em, glyph.x_advance);
        // A horizontal run moves the pen along one axis only, and Ahem places
        // no glyph off its own origin.
        try testing.expectEqual(@as(f32, 0), glyph.y_advance);
        try testing.expectEqual(@as(f32, 0), glyph.x_offset);
        try testing.expectEqual(@as(f32, 0), glyph.y_offset);
    }
    try testing.expectEqual(3 * em, text.advance(glyphs));
}

test "every glyph carries the byte it came from" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer face.deinit();
    var shaper: text.Shaper = try .init(64);
    defer shaper.deinit();

    var storage: [64]res.ShapedGlyph = undefined;
    const glyphs = try shaped(&shaper, face, "X Y", &storage);

    try testing.expectEqual(@as(usize, 3), glyphs.len);
    // Three single-byte characters, so the clusters are the byte offsets
    // themselves. This is what a cursor is placed by.
    try testing.expectEqual(@as(u32, 0), glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 1), glyphs[1].cluster);
    try testing.expectEqual(@as(u32, 2), glyphs[2].cluster);
    // The space is a glyph of its own and advances like every other one.
    try testing.expectEqual(3 * em, text.advance(glyphs));
}

// The same buffer, twice. HarfBuzz keeps the storage a shaped run went into and
// hands it out again, so a shaper that failed to clear would return the first
// run appended to the second.
test "a shaper is reused without carrying the previous run into the next" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer face.deinit();
    var shaper: text.Shaper = try .init(4);
    defer shaper.deinit();

    var storage: [64]res.ShapedGlyph = undefined;
    _ = try shaped(&shaper, face, "XXXXXXXX", &storage);
    const second = try shaped(&shaper, face, "XX", &storage);

    try testing.expectEqual(@as(usize, 2), second.len);
    try testing.expectEqual(2 * em, text.advance(second));
}

test "a run that does not fit is refused rather than cut short" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer face.deinit();
    var shaper: text.Shaper = try .init(64);
    defer shaper.deinit();

    var storage: [2]res.ShapedGlyph = undefined;
    try testing.expectError(error.GlyphsDoNotFit, shaper.shape(face, "XXX", &storage));
    // Exactly full is not too many.
    try testing.expectEqual(@as(usize, 2), try shaper.shape(face, "XX", &storage));
}

test "text with no characters shapes into no glyphs" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer face.deinit();
    var shaper: text.Shaper = try .init(64);
    defer shaper.deinit();

    var storage: [64]res.ShapedGlyph = undefined;
    try testing.expectEqual(@as(usize, 0), try shaper.shape(face, "", &storage));
    // A destination of no glyphs is enough for a run of none.
    try testing.expectEqual(@as(usize, 0), try shaper.shape(face, "", storage[0..0]));
    try testing.expectEqual(@as(f32, 0), text.advance(storage[0..0]));
}

// A capacity of none, which is the one case where the buffer has no arrays at
// all: HarfBuzz allocates them when it is asked to grow, and one that was never
// grown answers with a length of zero and a null pointer rather than with an
// empty array. Measured on this run, not taken from the shape of the code.
test "a shaper given no room shapes an empty run and then grows for a full one" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer face.deinit();
    var shaper: text.Shaper = try .init(0);
    defer shaper.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    try testing.expectEqual(@as(usize, 0), try shaper.shape(face, "", &storage));
    try testing.expectEqual(@as(usize, 2), try shaper.shape(face, "XX", &storage));
    try testing.expectEqual(2 * em, text.advance(storage[0..2]));
}
