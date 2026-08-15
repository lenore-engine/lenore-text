/*
 * The C surface Zig calls to rasterise one glyph.
 *
 * FreeType keeps a rendered glyph in fields of `FT_FaceRec` and
 * `FT_GlyphSlotRec` rather than behind accessors, so reaching it means knowing
 * those layouts. Declaring them a second time in Zig would be a copy of an ABI
 * that nothing checks; this reads them in C, where the header is the authority,
 * and hands back a flat struct whose layout is ours.
 *
 * One crossing per glyph. A glyph is rasterised once and cached in an atlas, so
 * the call is cold and there is nothing to batch.
 */
#ifndef LENORE_GLYPH_H
#define LENORE_GLYPH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* How coverage is measured across a pixel.
 *
 * The values are the caller's to pass and are mirrored in Zig, like the hinting
 * constants above.
 */
/* One number per pixel: how much of it the outline covers. */
#define LENORE_ANTIALIAS_GRAYSCALE (0)
/* Three, one per colour subpixel of a striped display, each the coverage of
 * its own third of the pixel. FreeType renders these as three coverage maps
 * with the outline shifted against each subpixel's offset, which leaves the
 * integral coverage of the pixel unchanged. */
#define LENORE_ANTIALIAS_SUBPIXEL (1)

/* Eight-bit coverage for one glyph, borrowed from the face that rendered it.
 *
 * `pixels` points into the face's own glyph slot and is valid until the next
 * glyph is loaded on that face. FreeType owns the slot and reuses it, so this
 * has to be copied out before the next call rather than kept.
 *
 * `pitch` is the byte distance from one row to the next and is always
 * positive here: rows run top to bottom. FreeType signs it, a negative pitch
 * meaning a bitmap stored bottom row first, and such a bitmap is refused
 * rather than handed on with a sign for every reader to remember.
 *
 * `width` is in pixels and `channels` is how many bytes each of them takes,
 * so a row is `width * channels` bytes of the `pitch` it sits in and the rest
 * is padding. FreeType counts a subpixel bitmap's width in subpixels; that is
 * divided out here, so a caller sees the same units whichever mode it asked
 * for.
 *
 * `left` and `top` are the bearing: where the glyph sits relative to the pen,
 * with `top` measured up from the baseline to the first row.
 *
 * A glyph with no outline, such as a space, is a success with `width` and
 * `rows` of zero and `pixels` null.
 */
typedef struct {
  const unsigned char *pixels;
  uint32_t pitch;
  uint32_t width;
  uint32_t rows;
  uint32_t channels;
  int32_t left;
  int32_t top;
} lenore_glyph_coverage;

/* How much of the pixel grid a glyph is snapped to.
 *
 * The values are the caller's to pass and are mirrored in Zig, so they are
 * fixed here rather than left to an enum's numbering. What each one means in
 * FreeType's own flags is `lenore_glyph.c`, which is the only file in this
 * module that may name them.
 */
/* The outline is scaled and nothing else. */
#define LENORE_HINTING_NONE (0)
/* Snapped along the vertical axis only, leaving every horizontal position
 * where the unhinted outline put it. */
#define LENORE_HINTING_LIGHT (1)

/* Rasterises one glyph of `face` into `out`.
 *
 * `face` is an `FT_Face`. It is taken as void* so that this header does not
 * put FreeType's own headers into the caller's include path.
 *
 * `hinting` and `antialias` are each one of the constants above.
 *
 * `x_shift` moves the outline right before it is rasterised, in sixty-fourths
 * of a pixel, which is FreeType's own fixed-point grid for a scaled outline.
 * It is how one glyph comes to have several rasterisations: a caller that will
 * draw at a fractional position asks for the one rasterised at that fraction
 * and then draws it at a whole pixel. Zero is the glyph on the grid, and the
 * bearing and width reported below are the shifted outline's.
 *
 * Returns zero on success and a FreeType error code otherwise, plus two of its
 * own. Neither is an error in the font: they are shapes this module does not
 * produce coverage for.
 */
/* Rendered into something other than eight-bit coverage: a colour or embedded
 * bitmap format, which is a different feature. */
#define LENORE_GLYPH_NOT_COVERAGE (-1)
/* Stored bottom row first. The anti-aliased renderer does not produce these;
 * an embedded strike can. */
#define LENORE_GLYPH_BOTTOM_UP (-2)

int lenore_render_glyph(void *face, uint32_t glyph_index, int hinting,
    int antialias, int x_shift, lenore_glyph_coverage *out);

#ifdef __cplusplus
}
#endif

#endif
