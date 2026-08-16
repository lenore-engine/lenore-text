// Text shaping and glyph rasterisation.
//
// Two libraries, in the layering they were designed for: FreeType owns the face
// and turns a glyph into coverage, HarfBuzz turns a string into glyph indices
// and positions and reads its tables through that same face. What this module
// adds is the Zig surface over them and the vocabulary above it.
//
// The C surface is declared by hand rather than imported with `@cImport`. What
// this module calls is a dozen entry points out of some hundreds, and each is
// declared where it is used with the comment that says what it promises. What
// no build step checks is that a declaration matches the C one: the linker
// resolves a name and knows nothing of the types on either side of it, so a
// wrong signature or a mistyped struct is caught by a test that calls through
// it and by nothing else. That is what `tests/link.zig` and the sizes asserted
// beside each borrowed struct are for.
//
// What this module produces it does not declare. A shaped glyph, a placement
// and a face's metrics are `lenore-resources` declarations, so that a UI can
// draw a run without linking two C libraries to say what one is. They are not
// re-exported here: one name for a type is what keeps two consumers agreeing
// about it.

const atlas = @import("atlas.zig");
const face = @import("face.zig");
const raster = @import("raster.zig");
const shape = @import("shape.zig");

pub const Antialias = face.Antialias;
pub const Error = face.Error;
pub const Face = face.Face;
pub const FaceOptions = face.Options;
pub const Hinting = face.Hinting;
pub const Library = face.Library;
pub const Versions = face.Versions;
pub const fixedToPixels = face.fixedToPixels;
pub const max_pixel_size = face.max_pixel_size;

pub const Shaper = shape.Shaper;
pub const ShapeError = shape.Error;
pub const advance = shape.advance;

pub const Coverage = raster.Coverage;
pub const RasterError = raster.Error;
pub const render = raster.render;

pub const Atlas = atlas.Atlas;
pub const atlas_channels = atlas.channels;
pub const AtlasBox = atlas.Box;
pub const AtlasError = atlas.Error;
pub const AtlasKey = atlas.Key;
pub const AtlasSizeError = atlas.SizeError;
