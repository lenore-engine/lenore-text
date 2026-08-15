const std = @import("std");
const res = @import("lenore-resources");
const text = @import("lenore-text");

const testing = std.testing;

const ahem = @embedFile("fonts/Ahem.ttf");
const pixel_size = 16;

// Ahem's lettered glyphs at this size are sixteen texels across and seventeen
// down; `tests/raster.zig` derives both from the font's own design.
//
// That derivation is of the outline, so the faces here are opened unhinted.
// What this file is about is packing, and a shelf holds whatever height it is
// given: taking the hinter's answer instead would make every figure below a
// measurement of something this file does not test.
const glyph_width = 16;
const glyph_rows = 17;

const Fixture = struct {
    library: text.Library,
    face: text.Face,
    shaper: text.Shaper,

    fn init() !Fixture {
        var library: text.Library = try .init();
        errdefer library.deinit();
        var face: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size, .hinting = .none });
        errdefer face.deinit();
        const shaper: text.Shaper = try .init(16);
        return .{ .library = library, .face = face, .shaper = shaper };
    }

    fn deinit(self: *Fixture) void {
        self.shaper.deinit();
        self.face.deinit();
        self.library.deinit();
    }

    // The index the face gives one character, which is what a key holds.
    fn index(self: *Fixture, character: []const u8) !u32 {
        var storage: [4]res.ShapedGlyph = undefined;
        const count = try self.shaper.shape(self.face, character, &storage);
        try testing.expectEqual(@as(usize, 1), count);
        return storage[0].index;
    }
};

test "a glyph is rasterised once and answered from the cache after that" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    const key: text.AtlasKey = .{ .font = 0, .bucket = 0, .glyph = try fixture.index("X") };
    const first = try atlas.glyph(testing.allocator, key, fixture.face);
    try testing.expect(!first.isBlank());
    try testing.expectEqual(@as(f32, glyph_width), first.width);
    try testing.expectEqual(@as(f32, glyph_rows), first.height);

    // Everything written so far is in the dirty box, and taking it empties it.
    try testing.expect(atlas.takeDirty() != null);
    try testing.expectEqual(@as(?text.AtlasBox, null), atlas.takeDirty());

    // The second ask writes nothing, which is what says it came from the cache
    // rather than from a second rasterisation into a second place.
    const second = try atlas.glyph(testing.allocator, key, fixture.face);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(?text.AtlasBox, null), atlas.takeDirty());
}

test "the coverage reaches the atlas where the placement says it is" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    const key: text.AtlasKey = .{ .font = 0, .bucket = 0, .glyph = try fixture.index("X") };
    const placement = try atlas.glyph(testing.allocator, key, fixture.face);

    // Back from the normalised coordinates to texels, which is the trip a
    // shader makes and the one place the two representations can disagree.
    const x: u32 = @intFromFloat(placement.u_min * @as(f32, @floatFromInt(atlas.width)));
    const y: u32 = @intFromFloat(placement.v_min * @as(f32, @floatFromInt(atlas.height)));
    try testing.expectEqual(
        placement.width,
        (placement.u_max - placement.u_min) * @as(f32, @floatFromInt(atlas.width)),
    );

    // Four bytes to a texel. A grayscale glyph writes its one coverage into all
    // four, so any channel is the whole answer and the alpha is read here
    // because that is the one a solid fill also uses.
    const stride = text.atlas_channels;
    var ink: u64 = 0;
    for (0..glyph_rows) |row| {
        const start = ((y + row) * atlas.width + x) * stride;
        for (0..glyph_width) |column| ink += atlas.pixels[start + column * stride + 3];
    }
    // The same total `tests/raster.zig` derives: a sixteen by sixteen pixel
    // rectangle of full coverage, plus one unit per column from the two partial
    // rows rounding up.
    try testing.expectEqual(@as(u64, glyph_width * glyph_width * 255 + glyph_width), ink);
}

test "glyphs of a height share a shelf and a taller one opens the next" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    const first = try atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = try fixture.index("X") }, fixture.face);
    const second = try atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = try fixture.index("Y") }, fixture.face);

    // Every Ahem letter is the same rectangle, so the second sits beside the
    // first on one shelf: same row, further along.
    try testing.expectEqual(first.v_min, second.v_min);
    try testing.expect(second.u_min > first.u_min);
    // And it does not overlap: the gap is the texel of padding between them.
    try testing.expect(second.u_min > first.u_max);
}

test "a glyph with no ink takes no room and is still remembered" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    const key: text.AtlasKey = .{ .font = 0, .bucket = 0, .glyph = try fixture.index(" ") };
    const placement = try atlas.glyph(testing.allocator, key, fixture.face);
    try testing.expect(placement.isBlank());
    // Nothing was written, so there is nothing to upload.
    try testing.expectEqual(@as(?text.AtlasBox, null), atlas.takeDirty());
    try testing.expectEqual(placement, try atlas.glyph(testing.allocator, key, fixture.face));
}

test "an atlas that has run out says so rather than overwriting" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    // Room for one glyph across and one shelf down, and not two.
    var atlas: text.Atlas = try .init(testing.allocator, 20, 20);
    defer atlas.deinit(testing.allocator);

    _ = try atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = try fixture.index("X") }, fixture.face);
    try testing.expectError(
        error.AtlasFull,
        atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = try fixture.index("Y") }, fixture.face),
    );
}

test "a glyph larger than the atlas is refused by its size and not by packing" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 8, 8);
    defer atlas.deinit(testing.allocator);

    try testing.expectError(
        error.GlyphTooLarge,
        atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = try fixture.index("X") }, fixture.face),
    );
}

test "the same glyph index of two fonts is two entries" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    const index = try fixture.index("X");
    const first = try atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = index }, fixture.face);
    const second = try atlas.glyph(testing.allocator, .{ .font = 1, .bucket = 0, .glyph = index }, fixture.face);

    // The same face was handed in twice under two names, which is a caller's
    // mistake this cannot see. What it shows is that the font is part of the
    // key: the two went to different places rather than the second being
    // answered with the first.
    try testing.expect(first.u_min != second.u_min or first.v_min != second.v_min);
}

// Every extent and index in the atlas is a u32, and the widest thing computed
// from them is the byte offset of a row. A size whose bytes do not number in
// one is refused where it is given rather than where it wraps: with the safety
// checks off that wrap is not a panic but a write past the buffer.
test "a size the atlas cannot address is refused rather than wrapped" {
    // One texel past what four bytes to a texel fit in a u32, and the largest
    // that does. The second allocates four gigabytes minus four bytes, so it is
    // the failing allocator that answers rather than the check.
    const largest = std.math.maxInt(u32) / 4;
    try testing.expectError(error.AtlasTooLarge, text.Atlas.init(testing.allocator, largest + 1, 1));
    try testing.expectError(error.AtlasTooLarge, text.Atlas.init(testing.allocator, 65536, 65536));
    try testing.expectError(error.OutOfMemory, text.Atlas.init(testing.failing_allocator, largest, 1));

    // A dimension of zero would allocate happily and place nothing.
    try testing.expectError(error.AtlasEmpty, text.Atlas.init(testing.allocator, 0, 128));
    try testing.expectError(error.AtlasEmpty, text.Atlas.init(testing.allocator, 128, 0));
}

// The number a caller keys a face by is the caller's, and this is the only way
// one becomes free again: the entries are keyed by it, so a second face under a
// number the first still has glyphs under would be handed the first's pictures.
test "a forgotten face frees its number and leaves the rest alone" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    const index = try fixture.index("X");
    const dropped = try atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = index }, fixture.face);
    const kept = try atlas.glyph(testing.allocator, .{ .font = 1, .bucket = 0, .glyph = index }, fixture.face);

    atlas.forget(0);
    _ = atlas.takeDirty();

    // The other face is untouched, and answers from the cache: nothing was
    // written, which is what says it was not rasterised a second time.
    try testing.expectEqual(kept, try atlas.glyph(testing.allocator, .{ .font = 1, .bucket = 0, .glyph = index }, fixture.face));
    try testing.expectEqual(@as(?text.AtlasBox, null), atlas.takeDirty());

    // The number is free, so the same key rasterises again and lands somewhere
    // new rather than on the coverage the dropped face left behind.
    const reused = try atlas.glyph(testing.allocator, .{ .font = 0, .bucket = 0, .glyph = index }, fixture.face);
    try testing.expect(atlas.takeDirty() != null);
    try testing.expect(reused.u_min != dropped.u_min or reused.v_min != dropped.v_min);
}

// A bucket is a different picture of the same glyph, so it is a different
// entry. Answering one bucket with another's box would draw the glyph half a
// pixel from where it was asked for, which is the whole thing buckets exist to
// stop.
test "two buckets of one glyph are two entries" {
    var library: text.Library = try .init();
    defer library.deinit();
    var face: text.Face = try .open(library, ahem, .{
        .pixel_size = pixel_size,
        .hinting = .none,
        .subpixel = .half,
    });
    defer face.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    var storage: [4]res.ShapedGlyph = undefined;
    _ = try shaper.shape(face, "X", &storage);
    const index = storage[0].index;

    const first = try atlas.glyph(testing.allocator, .{ .font = 0, .glyph = index, .bucket = 0 }, face);
    const second = try atlas.glyph(testing.allocator, .{ .font = 0, .glyph = index, .bucket = 1 }, face);

    try testing.expect(first.u_min != second.u_min or first.v_min != second.v_min);
    // And the second is the wider one, because half a pixel of shift reaches
    // into the column past the rectangle's right edge.
    try testing.expectEqual(first.width + 1, second.width);

    // Each is still cached under its own bucket rather than rasterised again.
    _ = atlas.takeDirty();
    try testing.expectEqual(
        first,
        try atlas.glyph(testing.allocator, .{ .font = 0, .glyph = index, .bucket = 0 }, face),
    );
    try testing.expectEqual(@as(?text.AtlasBox, null), atlas.takeDirty());
}

// What the atlas holds is four bytes to a texel whichever mode rendered the
// glyph, so a fragment stage reads either kind with one sample and no swizzle.
//
// A grayscale glyph writes its one coverage into all four channels, which is
// exactly what the image view used to do with a swizzle of R into every
// component. A subpixel glyph writes its three stripes and, in alpha, the
// largest of them: alpha is what the destination is scaled down by, and a pixel
// with one stripe fully covered has nothing of the background left to show.
test "the atlas expands both kinds of coverage into four channels" {
    var library: text.Library = try .init();
    defer library.deinit();
    var shaper: text.Shaper = try .init(16);
    defer shaper.deinit();
    var atlas: text.Atlas = try .init(testing.allocator, 128, 128);
    defer atlas.deinit(testing.allocator);

    var gray: text.Face = try .open(library, ahem, .{ .pixel_size = pixel_size, .hinting = .none });
    defer gray.deinit();
    var colour: text.Face = try .open(library, ahem, .{
        .pixel_size = pixel_size,
        .hinting = .none,
        .antialias = .subpixel,
    });
    defer colour.deinit();

    var storage: [4]res.ShapedGlyph = undefined;
    _ = try shaper.shape(gray, "X", &storage);
    const index = storage[0].index;

    const stride = text.atlas_channels;
    const first = try atlas.glyph(testing.allocator, .{ .font = 0, .glyph = index, .bucket = 0 }, gray);
    const second = try atlas.glyph(testing.allocator, .{ .font = 1, .glyph = index, .bucket = 0 }, colour);

    // A texel wholly inside the grayscale glyph: four times the same number.
    {
        const x: u32 = @intFromFloat(first.u_min * @as(f32, @floatFromInt(atlas.width)));
        const y: u32 = @intFromFloat(first.v_min * @as(f32, @floatFromInt(atlas.height)));
        const at = ((y + 8) * atlas.width + x + 8) * stride;
        try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, atlas.pixels[at..][0..stride]);
    }

    // The subpixel glyph's leftmost texel, which `tests/raster.zig` derives as
    // no red, no green and 84 of blue. Alpha is the largest of the three.
    {
        const x: u32 = @intFromFloat(second.u_min * @as(f32, @floatFromInt(atlas.width)));
        const y: u32 = @intFromFloat(second.v_min * @as(f32, @floatFromInt(atlas.height)));
        const at = ((y + 8) * atlas.width + x) * stride;
        try testing.expectEqualSlices(u8, &.{ 0, 0, 84, 84 }, atlas.pixels[at..][0..stride]);
    }
}
