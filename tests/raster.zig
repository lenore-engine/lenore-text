const std = @import("std");
const res = @import("lenore-resources");
const text = @import("lenore-text");

const testing = std.testing;

const ahem = @embedFile("fonts/Ahem.ttf");
const pixel_size = 16;

// Ahem's lettered glyphs are one rectangle each, spanning the full em across
// and from the descent to the ascent down: x from 0 to 1000 and y from -200 to
// 800 in font units. At sixteen pixels to the em that is x from 0 to 16, which
// lands on the pixel grid exactly, and y from -3.2 to 12.8, which does not.
//
// So the geometry below is derived rather than read off: sixteen columns, and
// seventeen rows because the rectangle's top and bottom edges fall inside a
// pixel and each of those rows is partly covered.
//
// Every figure here is the unhinted outline's, which is why the faces below
// name `.none` rather than taking the default. Pulling the top and bottom edges
// onto the grid is exactly what a hinter is for, and a test whose expected
// values came out of one would be measuring the hinter instead of the
// rasteriser. The hinted face has its own tests at the end of this file.
const columns = 16;
const rows = 17;

const unhinted: text.FaceOptions = .{ .pixel_size = pixel_size, .hinting = .none };

fn inkOf(coverage: text.Coverage) u64 {
    var total: u64 = 0;
    var y: u32 = 0;
    while (y < coverage.rows) : (y += 1) {
        for (coverage.row(y)) |value| total += value;
    }
    return total;
}

test "a glyph rasterises to the coverage its outline covers" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, unhinted);
    defer face.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    const count = try shaper.shape(face, "X", &storage);
    try testing.expectEqual(@as(usize, 1), count);

    const coverage = try text.render(face, storage[0].index, 0);
    try testing.expect(!coverage.isBlank());
    try testing.expectEqual(@as(u32, columns), coverage.width);
    try testing.expectEqual(@as(u32, rows), coverage.rows);
    // A row is padded to the pitch, so the pitch is at least the width. It is
    // the width here, which is not something to depend on.
    try testing.expect(coverage.pitch >= coverage.width);
    // The rectangle starts at the pen and rises to 12.8 pixels, so the first
    // row is the one holding 12.8: thirteen above the baseline.
    try testing.expectEqual(@as(i32, 0), coverage.left);
    try testing.expectEqual(@as(i32, 13), coverage.top);

    // Every row but the first and the last is wholly inside the rectangle and
    // is therefore wholly covered. This is the part that says the rasteriser
    // filled the shape rather than outlined it.
    for (1..rows - 1) |y| {
        for (coverage.row(@intCast(y))) |value| try testing.expectEqual(@as(u8, 255), value);
    }

    // The rectangle is sixteen pixels by sixteen, so its area is 256 pixels of
    // full coverage: 65280 units. The measured total is sixteen more than that,
    // one per column, because the two partial rows come back as 205 and 51 and
    // those sum to 256 rather than 255. That is the rasteriser rounding each
    // edge, and it is stated here rather than absorbed into a tolerance so that
    // a change in it is visible.
    try testing.expectEqual(@as(u64, columns * columns * 255 + columns), inkOf(coverage));
}

test "a glyph with no ink is blank and still has a place" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, unhinted);
    defer face.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    _ = try shaper.shape(face, " ", &storage);

    const coverage = try text.render(face, storage[0].index, 0);
    try testing.expect(coverage.isBlank());
    try testing.expectEqual(@as(u32, 0), coverage.width);
    try testing.expectEqual(@as(u32, 0), coverage.rows);
    try testing.expectEqual(@as(usize, 0), coverage.bytes.len);
    // It draws nothing and still moves the pen a whole em: ink and advance are
    // answered by different libraries and are not the same question.
    try testing.expectEqual(@as(f32, pixel_size), storage[0].x_advance);
}

test "doubling the size doubles the coverage" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size * 2, .hinting = .none });
    defer face.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    _ = try shaper.shape(face, "X", &storage);

    const coverage = try text.render(face, storage[0].index, 0);
    try testing.expectEqual(@as(u32, 2 * columns), coverage.width);
    try testing.expectEqual(@as(u64, 2 * columns * 2 * columns * 255 + 2 * columns), inkOf(coverage));
}

// Glyph indices are the face's own and a number outside its range is a caller
// mistake, not a font defect. It comes back as an error in every build mode
// rather than as whatever FreeType left in the slot.
test "an index the face has no glyph for is refused" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, unhinted);
    defer face.deinit();

    try testing.expectError(error.NoSuchGlyph, text.render(face, 100_000, 0));
}

// A face of each mode over the same bytes, which is what a hinting test needs
// and what the atlas above this module is already arranged for: it keys a glyph
// by the face, so two modes never answer for each other.
//
// The two coverages may be held at once. Each borrows its own face's glyph
// slot, and rendering on one face does not touch the other's.
const Pair = struct {
    library: text.Library,
    none: text.Face,
    light: text.Face,
    shaper: text.Shaper,

    fn init(size: u32) !Pair {
        var library: text.Library = try .init();
        errdefer library.deinit();
        var none: text.Face = try .open(library, ahem, .{ .pixel_size = size, .hinting = .none });
        errdefer none.deinit();
        var light: text.Face = try .open(library, ahem, .{ .pixel_size = size, .hinting = .light });
        errdefer light.deinit();
        const shaper: text.Shaper = try .init(16);
        return .{ .library = library, .none = none, .light = light, .shaper = shaper };
    }

    fn deinit(self: *Pair) void {
        self.shaper.deinit();
        self.light.deinit();
        self.none.deinit();
        self.library.deinit();
    }

    fn index(self: *Pair, character: []const u8) !u32 {
        var storage: [4]res.ShapedGlyph = undefined;
        const count = try self.shaper.shape(self.none, character, &storage);
        try testing.expectEqual(@as(usize, 1), count);
        return storage[0].index;
    }
};

// The invariant the hinted mode exists under, and the reason it may be the
// default: a run is laid out from advances the shaper measured off the face's
// own tables, so a glyph that moved horizontally would sit off the pen it was
// placed at, by a fraction of a pixel that accumulates along the line.
//
// Light hinting cannot do that, and this pins it over every glyph a Latin
// interface draws rather than over one. The unhinted mode is the reference
// because it is the outline as designed.
test "light hinting leaves every glyph where the outline put it horizontally" {
    var pair: Pair = try .init(pixel_size);
    defer pair.deinit();

    var character: u8 = ' ';
    while (character <= '~') : (character += 1) {
        const source = [_]u8{character};
        const glyph = try pair.index(&source);
        const plain = try text.render(pair.none, glyph, 0);
        const hinted = try text.render(pair.light, glyph, 0);

        try testing.expectEqual(plain.left, hinted.left);
        try testing.expectEqual(plain.width, hinted.width);
    }
}

// The other half, and what says the flag reached FreeType at all: a mode that
// were quietly ignored would agree with the unhinted one everywhere and the
// test above would pass on its own.
//
// Ahem's rectangle runs from 12.8 pixels above the baseline to 3.2 below at
// this size, so unhinted it covers seventeen rows of which the first and last
// are partial. Snapped, both edges land on the grid and the same rectangle is
// sixteen rows, every one of them wholly inside it. That is the whole of what
// light hinting is for: a stem edge resolves to one row of full coverage
// instead of two of half.
test "light hinting snaps the edges that do not lie on the grid" {
    var pair: Pair = try .init(pixel_size);
    defer pair.deinit();

    const hinted = try text.render(pair.light, try pair.index("X"), 0);
    try testing.expectEqual(@as(u32, columns), hinted.width);
    try testing.expectEqual(@as(u32, columns), hinted.rows);
    try testing.expectEqual(@as(i32, 0), hinted.left);
    try testing.expectEqual(@as(i32, 13), hinted.top);

    // No partial row anywhere, so no rounding remainder either: the unhinted
    // total above carries sixteen extra units and this one does not.
    try testing.expectEqual(@as(u64, columns * columns * 255), inkOf(hinted));
}

// And it snaps nothing that is already there. At twenty pixels to the em
// Ahem's rectangle runs from 16 above the baseline to 4 below, both whole, so
// the two modes have to agree to the texel. A hinter that moved this would be
// moving glyphs for its own sake.
test "a glyph already on the grid is the same in both modes" {
    const size = 20;
    var pair: Pair = try .init(size);
    defer pair.deinit();

    const glyph = try pair.index("X");
    const plain = try text.render(pair.none, glyph, 0);
    const hinted = try text.render(pair.light, glyph, 0);

    try testing.expectEqual(@as(u32, size), plain.width);
    try testing.expectEqual(@as(u32, size), plain.rows);
    try testing.expectEqual(plain.width, hinted.width);
    try testing.expectEqual(plain.rows, hinted.rows);
    try testing.expectEqual(plain.left, hinted.left);
    try testing.expectEqual(plain.top, hinted.top);
    try testing.expectEqual(inkOf(plain), inkOf(hinted));
}

// The shift is a whole number of sixty-fourths at every count this enum
// admits, which is what makes a bucket a position on FreeType's own grid
// rather than a rounding of one. A count that did not divide 64 would space
// the buckets unevenly, and the arithmetic that picks one assumes they are
// even.
test "a bucket is an exact number of sixty-fourths" {
    var library: text.Library = try .init();
    defer library.deinit();

    var whole: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size });
    defer whole.deinit();
    try testing.expectEqual(@as(i32, 0), whole.shiftOf(0));

    var half: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size, .subpixel = .half });
    defer half.deinit();
    try testing.expectEqual(@as(i32, 0), half.shiftOf(0));
    try testing.expectEqual(@as(i32, 32), half.shiftOf(1));

    var quarter: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size, .subpixel = .quarter });
    defer quarter.deinit();
    for (0..4) |bucket| {
        try testing.expectEqual(@as(i32, @intCast(bucket * 16)), quarter.shiftOf(@intCast(bucket)));
    }
}

// What a bucket is, made visible.
//
// Ahem's rectangle spans x from 0 to exactly 16 at this size, so bucket zero
// is sixteen columns of full coverage and nothing partial. Move it a quarter
// of a pixel right and it spans 0.25 to 16.25: seventeen columns, of which the
// first is three quarters covered and the last is one quarter. Half a pixel
// splits it evenly, and three quarters is the mirror of one.
//
// The coverages are derived from that and not read off a run: three quarters
// of 255 is 191.25 and one quarter is 63.75, and the rasteriser rounds each
// edge up, which is the same rounding the unhinted test above records for the
// two partial rows.
test "each bucket rasterises the outline at its own offset" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{
        .pixel_size = pixel_size,
        .hinting = .none,
        .subpixel = .quarter,
    });
    defer face.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    _ = try shaper.shape(face, "X", &storage);
    const glyph = storage[0].index;

    const edges = [_]struct { first: u8, last: u8 }{
        .{ .first = 192, .last = 64 },
        .{ .first = 128, .last = 128 },
        .{ .first = 64, .last = 192 },
    };
    for (edges, 1..) |edge, bucket| {
        const coverage = try text.render(face, glyph, @intCast(bucket));
        // One column wider than bucket zero, because a shifted rectangle
        // reaches into the pixel past its right edge.
        try testing.expectEqual(@as(u32, columns + 1), coverage.width);
        // And it still starts at the pen: the shift is inside the first pixel,
        // so the bearing does not move.
        try testing.expectEqual(@as(i32, 0), coverage.left);

        // A row wholly inside the rectangle, so the only partial coverage in
        // it is the two the shift made.
        const middle = coverage.row(coverage.rows / 2);
        try testing.expectEqual(edge.first, middle[0]);
        try testing.expectEqual(edge.last, middle[middle.len - 1]);
        for (middle[1 .. middle.len - 1]) |value| try testing.expectEqual(@as(u8, 255), value);
    }

    // Bucket zero is the unshifted glyph, which is what a face of one bucket
    // gets and what every test above this one measures.
    const unshifted = try text.render(face, glyph, 0);
    try testing.expectEqual(@as(u32, columns), unshifted.width);
}

// Subpixel rasterisation, derived rather than read off a run.
//
// FreeType's default stripe geometry is {(-21, 0), (0, 0), (21, 0)} in 26.6
// units (`ftsmooth.c', ft_smooth_init under Harmony), so red sits 21/64 of a
// pixel left of the centre and blue the same to the right. Each channel is
// rendered with the outline translated against its own stripe, which is why the
// three differ and why the glyph reaches one pixel past the outline on each
// side: FreeType pads the box for it.
//
// Ahem's rectangle spans x from 0 to exactly 16 here. Red is therefore measured
// against a rectangle shifted right by 21/64 = 0.328125, so pixel -1 has no red
// and pixel 0 has 1 - 0.328125 of it: 171.3 of 255, which the rasteriser rounds
// up to 172. Blue is the mirror, so pixel -1 has 0.328125 of it, 83.7 rounded
// up to 84. Green is unshifted and is 0 then 255.
test "subpixel rasterisation measures each stripe where the stripe is" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{
        .pixel_size = pixel_size,
        .hinting = .none,
        .antialias = .subpixel,
    });
    defer face.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    _ = try shaper.shape(face, "X", &storage);
    const coverage = try text.render(face, storage[0].index, 0);

    try testing.expectEqual(@as(u32, 3), coverage.channels);
    // A pixel of padding on each side, which the shifts need and FreeType adds.
    try testing.expectEqual(@as(i32, -1), coverage.left);
    try testing.expectEqual(@as(u32, columns + 2), coverage.width);
    try testing.expectEqual(@as(u32, rows), coverage.rows);

    // A row wholly inside the rectangle, so the only partial coverage in it is
    // the stripes'. Two pixels at each end, in RGB order.
    const middle = coverage.row(coverage.rows / 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 84, 172, 255, 255 }, middle[0..6]);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 172, 84, 0, 0 }, middle[middle.len - 6 ..]);
}

// The mode a face takes is what it rasterises in, and the count comes back with
// the coverage rather than being assumed from the request: an embedded bitmap
// is grayscale whatever was asked for, so a consumer that read the face would
// be wrong about the bytes it holds.
test "a grayscale face reports one channel" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, unhinted);
    defer face.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    _ = try shaper.shape(face, "X", &storage);
    const coverage = try text.render(face, storage[0].index, 0);

    try testing.expectEqual(@as(u32, 1), coverage.channels);
    try testing.expectEqual(@as(u32, columns), coverage.width);
    try testing.expectEqual(@as(i32, 0), coverage.left);
}
