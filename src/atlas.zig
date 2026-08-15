const std = @import("std");
const res = @import("lenore-resources");

const face_module = @import("face.zig");
const raster = @import("raster.zig");

const Allocator = std.mem.Allocator;
const Face = face_module.Face;
const Placement = res.GlyphPlacement;

// Where rasterised glyphs are kept so that a frame draws them from one image.
//
// One image for every face an application uses, not one per face. What a draw
// command names is an image, so a second image is a second command and a batch
// that cannot be merged with the first; a label in two weights would then cost
// two draws instead of one.

// A glyph of a face, as this cache knows it.
//
// The face is named by a number the caller assigns rather than by its pointer.
// A pointer would be an identity that changes when a face is reopened at the
// same size, which is the one case a cache exists to survive. Nothing checks
// that a number and a face agree, because nothing can: the caller that hands
// both is the only thing that knows.
// `bucket` is which of the face's horizontal rasterisations this is. A face
// with more than one holds a separate entry per bucket for the same glyph,
// because they are different pictures: the outline was moved before it met the
// grid, so the coverage, the width and the bearing all differ.
pub const Key = struct {
    font: u32,
    glyph: u32,
    bucket: u8,
};

// A rectangle of texels.
pub const Box = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    fn cover(self: Box, other: Box) Box {
        const x = @min(self.x, other.x);
        const y = @min(self.y, other.y);
        return .{
            .x = x,
            .y = y,
            .width = @max(self.x + self.width, other.x + other.width) - x,
            .height = @max(self.y + self.height, other.y + other.height) - y,
        };
    }
};

// What is wrong with a size, answered once and before there is an atlas to put
// a glyph into. Separate from the errors a glyph can raise for that reason.
pub const SizeError = error{
    // More texels than a `u32` counts the bytes of, which is the bound the
    // arithmetic in this file is written against.
    AtlasTooLarge,
    // A dimension of zero. Such an atlas places no glyph, so it is a
    // configuration that could only fail later and further from its cause.
    AtlasEmpty,
};

pub const Error = error{
    // The atlas has no room for another glyph. It never evicts, so this is an
    // atlas sized for less than the application draws.
    AtlasFull,
    // A glyph larger than the atlas is, which no packing arrangement helps.
    GlyphTooLarge,
} || raster.Error || Allocator.Error;

// One row of the atlas that glyphs are placed along.
//
// Shelves rather than a general packer: glyphs of one size are within a texel
// or two of the same height, so a row filled left to right wastes little, and
// the alternative costs a search where this costs a comparison. Godot packs its
// font atlases the same way.
const Shelf = struct {
    // The top of the shelf, and how tall the tallest glyph on it may be.
    y: u32,
    height: u32,
    // How far along the shelf is filled.
    used: u32,
};

// A texel of space around every glyph.
//
// Sampling a glyph at its exact edge reads the texel next to it when the filter
// is anything but nearest, and the texel next to it is another glyph. One texel
// of unwritten space between them is what keeps a letter from wearing a sliver
// of its neighbour.
const padding = 1;

// Bytes per texel of the atlas.
//
// Four, because a subpixel glyph carries a coverage per colour stripe and the
// image a shader samples has four channels whether or not they differ. RGB is
// the coverage of each stripe and A is the coverage of the whole pixel, so a
// grayscale glyph writes one number into all four and a fragment stage needs no
// swizzle and no variant to read either kind.
//
// Three would fit a subpixel glyph exactly and is the wrong trade: a
// three-channel image is not a format every implementation samples, and a row
// of three-byte texels is a copy no aligned move can serve.
pub const channels = 4;

pub const Atlas = struct {
    // Eight-bit coverage, `width * height * channels` of it, in rows from the
    // top, four bytes to a texel.
    pixels: []u8,
    width: u32,
    height: u32,

    shelves: std.ArrayList(Shelf),
    entries: std.AutoHashMapUnmanaged(Key, Placement),

    // What has been written since a caller last took it. Null is an atlas
    // nothing has changed, which is the steady state once every glyph an
    // application draws has been seen once.
    dirty: ?Box,

    // **The one bound this file has, and what it buys.** Every extent, index
    // and sum below is a `u32`, and an atlas whose bytes number more than one
    // holds would wrap one of them: the byte offset of a row is the widest of
    // them at `width * height * channels`. Checked here, once, so that nothing
    // per glyph has to check anything. In a build with the safety checks off a
    // wrap is not a panic but a write past the buffer, so this is the reason it
    // is an error rather than an assertion.
    //
    // It also bounds the two dimensions on their own, which is what makes the
    // sums safe: a width above 2^30 cannot pass, so `used + width + padding`
    // and `x + width` stay inside a `u32` however the shelves are filled.
    //
    // The divisions rather than the product, so that the check itself cannot
    // be the thing that wraps.
    pub fn init(allocator: Allocator, width: u32, height: u32) (SizeError || Allocator.Error)!Atlas {
        if (width == 0 or height == 0) return error.AtlasEmpty;
        if (width > std.math.maxInt(u32) / height / channels) return error.AtlasTooLarge;

        const pixels = try allocator.alloc(u8, width * height * channels);
        // Zero is no coverage. The space between glyphs is read by the sampler
        // at the edges and has to be transparent rather than whatever the
        // allocator returned.
        @memset(pixels, 0);
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .shelves = .empty,
            .entries = .empty,
            .dirty = null,
        };
    }

    pub fn deinit(self: *Atlas, allocator: Allocator) void {
        allocator.free(self.pixels);
        self.shelves.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    // The placement of one glyph, rasterising it into the atlas if this is the
    // first time it has been asked for.
    //
    // Allocates only when a glyph is new, and a new glyph is one an application
    // has not drawn before. A run of text that has been drawn once costs a
    // lookup per glyph and nothing else, which is what makes this callable from
    // a frame.
    // `key.glyph` is the index to rasterise and `key.bucket` the offset to
    // rasterise it at, so neither can disagree with what is stored under it.
    pub fn glyph(self: *Atlas, allocator: Allocator, key: Key, font: Face) Error!Placement {
        if (self.entries.get(key)) |placement| return placement;

        // Room for the key before the atlas is touched, because `place` is not
        // undone. It writes coverage and moves a shelf along, and a map that
        // then failed to grow would leave a glyph in the atlas that nothing can
        // find, with the next call for the same key taking a second piece of
        // room for the same picture.
        try self.entries.ensureUnusedCapacity(allocator, 1);

        const coverage = try raster.render(font, key.glyph, key.bucket);
        const placement = try self.place(allocator, coverage);
        self.entries.putAssumeCapacity(key, placement);
        return placement;
    }

    // Drops every glyph of one face, so that its number may be given to another.
    //
    // This is what makes a number reusable, and nothing else does: the entries
    // are keyed by it, so a second face under a number the first still has
    // glyphs under would be handed the first face's pictures. A caller that
    // never reuses a number never needs this.
    //
    // The room those glyphs took is not reclaimed. The shelves are filled in
    // the order they were opened and hold no free list, so what this buys is
    // correctness and not space. The coverage stays in the image as well, where
    // it is unreferenced rather than wrong, and clearing it would be an upload
    // to no purpose.
    //
    // Removing during the walk is safe: a removal marks the slot and moves no
    // other entry (`std/hash_map.zig`, `removeByIndex`), so the iterator's
    // position stays the position it was.
    pub fn forget(self: *Atlas, font: u32) void {
        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            if (entry.key_ptr.font == font) self.entries.removeByPtr(entry.key_ptr);
        }
    }

    // What has changed since the last call, and nothing after it.
    //
    // A caller uploads the box it is given. Taking it clears it, so a caller
    // that takes and then fails to upload has lost the record of what to
    // upload; that is the same bargain every dirty-region interface makes, and
    // the alternative is a second call to say the upload happened.
    pub fn takeDirty(self: *Atlas) ?Box {
        defer self.dirty = null;
        return self.dirty;
    }

    // One row of a rasterised glyph into one row of the atlas.
    //
    // The alpha channel is the coverage of the whole pixel, and for a subpixel
    // glyph that is the largest of its three. The largest rather than the mean
    // because it is what the destination is scaled down by: a pixel any stripe
    // of which is fully covered has nothing of the background left to show, and
    // a mean would leave a ghost of it under solid ink.
    //
    // The two cases are separate loops rather than one loop over a channel
    // count. Each is a fixed stride the compiler can widen, which the general
    // form would not be, and this runs once per glyph per bucket at load.
    fn expand(destination: []u8, source: []const u8, source_channels: u32) void {
        switch (source_channels) {
            1 => for (source, 0..) |value, index| {
                destination[index * channels + 0] = value;
                destination[index * channels + 1] = value;
                destination[index * channels + 2] = value;
                destination[index * channels + 3] = value;
            },
            3 => {
                var index: usize = 0;
                while (index * 3 < source.len) : (index += 1) {
                    const red = source[index * 3 + 0];
                    const green = source[index * 3 + 1];
                    const blue = source[index * 3 + 2];
                    destination[index * channels + 0] = red;
                    destination[index * channels + 1] = green;
                    destination[index * channels + 2] = blue;
                    destination[index * channels + 3] = @max(red, @max(green, blue));
                }
            },
            // `raster.render` refuses any other count where the value enters
            // Zig, so no count but these two reaches a `Coverage`.
            else => unreachable,
        }
    }

    // Copies coverage into the atlas and returns where it went.
    fn place(self: *Atlas, allocator: Allocator, coverage: raster.Coverage) Error!Placement {
        // A glyph with no ink carries no corner either: there is no box for
        // `left` and `top` to be the corner of, and nothing samples an atlas
        // for it. It is still cached, which is the point of returning a
        // placement rather than nothing at all.
        if (coverage.isBlank()) return .blank;

        const box = try self.reserve(allocator, coverage.width, coverage.rows);
        var row: u32 = 0;
        while (row < coverage.rows) : (row += 1) {
            const start = ((box.y + row) * self.width + box.x) * channels;
            expand(self.pixels[start..][0 .. coverage.width * channels], coverage.row(row), coverage.channels);
        }
        self.dirty = if (self.dirty) |current| current.cover(box) else box;

        const width: f32 = @floatFromInt(self.width);
        const height: f32 = @floatFromInt(self.height);
        return .{
            .left = @floatFromInt(coverage.left),
            .top = @floatFromInt(coverage.top),
            .width = @floatFromInt(coverage.width),
            .height = @floatFromInt(coverage.rows),
            .u_min = @as(f32, @floatFromInt(box.x)) / width,
            .v_min = @as(f32, @floatFromInt(box.y)) / height,
            .u_max = @as(f32, @floatFromInt(box.x + box.width)) / width,
            .v_max = @as(f32, @floatFromInt(box.y + box.height)) / height,
        };
    }

    // Finds room for a glyph and marks it taken.
    //
    // The shelf whose height is closest to what is wanted, so a short glyph
    // does not take a row built for a tall one. A new shelf opens below the
    // last when none fits, which is why the shelves are in the order they were
    // opened and their tops never move.
    fn reserve(self: *Atlas, allocator: Allocator, width: u32, height: u32) Error!Box {
        if (width + padding > self.width or height + padding > self.height)
            return error.GlyphTooLarge;

        var best: ?*Shelf = null;
        for (self.shelves.items) |*shelf| {
            if (shelf.height < height) continue;
            if (shelf.used + width + padding > self.width) continue;
            if (best) |current| {
                if (shelf.height >= current.height) continue;
            }
            best = shelf;
        }

        if (best) |shelf| {
            const box: Box = .{ .x = shelf.used, .y = shelf.y, .width = width, .height = height };
            shelf.used += width + padding;
            return box;
        }

        const top = if (self.shelves.items.len == 0) 0 else blk: {
            const last = self.shelves.items[self.shelves.items.len - 1];
            break :blk last.y + last.height + padding;
        };
        if (top + height > self.height) return error.AtlasFull;

        try self.shelves.append(allocator, .{ .y = top, .height = height, .used = width + padding });
        return .{ .x = 0, .y = top, .width = width, .height = height };
    }
};
