#include "lenore_glyph.h"

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H

/* What a rasterised glyph must not do is move away from the pen the shaper
 * placed it at, and neither mode here does.
 *
 * FT_LOAD_TARGET_LIGHT is documented to snap to the pixel grid along the
 * vertical axis only and so to preserve inter-glyph spacing in horizontal text
 * (`freetype.h', FT_LOAD_TARGET_XXX). The contract holds whichever hinter
 * answers, which matters because that depends on the driver.
 * `tests/raster.zig' pins it over the printable range rather than taking it.
 *
 * The shaper is unaffected by both, and not because of the mode. HarfBuzz
 * loads with flags of its own, `FT_LOAD_DEFAULT | FT_LOAD_NO_HINTING'
 * (`hb-ft.cc', _hb_ft_font_create), and reads every advance through them
 * (hb_ft_get_glyph_h_advances). Nothing here calls hb_ft_font_set_load_flags,
 * so those flags stay as they were and FT_Get_Advance takes the fast path that
 * reads the face's own advance table (`ftadvanc.c', LOAD_ADVANCE_FAST_CHECK).
 * The rasteriser's flags never reach it. Nothing in the tree can check that:
 * every Ahem advance is a whole em and would survive a rounding to whole
 * pixels unchanged.
 *
 * FT_LOAD_NO_BITMAP is on both, and it is what keeps a scalable face's own
 * embedded strikes out of the answer. A strike is not a shape this module can
 * use: it cannot be moved to a subpixel bucket, FT_Outline_Translate needing
 * points that a bitmap does not have, so one strike would answer for every
 * bucket of that glyph while the outlines around it answered per bucket. It
 * also renders grayscale whatever was asked for.
 *
 * A bitmap-only face is unaffected: the TrueType driver suppresses its strikes
 * only when the face is scalable as well (`ttgload.c', TT_Load_Glyph, the
 * FT_LOAD_NO_BITMAP and FT_IS_SCALABLE pair). Such a face has no outline at any
 * size, so there is no shift and no subpixel coverage to be had for it, and
 * what it does give is read off the result below rather than off the request.
 */
static FT_Int32 load_flags_of(int hinting)
{
  if (hinting == LENORE_HINTING_LIGHT)
    return FT_LOAD_NO_BITMAP | FT_LOAD_TARGET_LIGHT;
  return FT_LOAD_NO_BITMAP | FT_LOAD_NO_HINTING;
}

/* Grayscale measures one coverage per pixel; subpixel measures one per colour
 * stripe of it.
 *
 * This build leaves FT_CONFIG_OPTION_SUBPIXEL_RENDERING undefined, so
 * FT_RENDER_MODE_LCD selects FreeType's Harmony rendering: three coverage maps
 * with the outline shifted against each subpixel's own offset, rather than one
 * map at triple resolution passed through an equalising filter. `ftlcdfil.h',
 * section `lcd_rendering', states the consequence -- the shifts do not change
 * the pixel's integral coverage, so the method carries no colour fringes of its
 * own and suits any regular subpixel structure. Nothing here calls
 * FT_Library_SetLcdFilter, which that mode ignores.
 */
static FT_Render_Mode render_mode_of(int antialias)
{
  if (antialias == LENORE_ANTIALIAS_SUBPIXEL)
    return FT_RENDER_MODE_LCD;
  return FT_RENDER_MODE_NORMAL;
}

int lenore_render_glyph(void *face, uint32_t glyph_index, int hinting,
    int antialias, int x_shift, lenore_glyph_coverage *out)
{
  FT_Face ft_face = (FT_Face)face;

  FT_Error error = FT_Load_Glyph(ft_face, glyph_index, load_flags_of(hinting));
  if (error != 0)
    return error;

  /* Between loading and rendering, which is the only window where the outline
   * exists and the raster does not. Hinting has already run and moved points
   * along the vertical axis; this moves the whole shape along the horizontal
   * one, so the two do not interfere.
   *
   * Only an outline can be translated, and after FT_LOAD_NO_BITMAP the format
   * is one unless the face is bitmap-only, which is the case that has no
   * outline to shift at any size.
   */
  if (x_shift != 0 && ft_face->glyph->format == FT_GLYPH_FORMAT_OUTLINE)
    FT_Outline_Translate(&ft_face->glyph->outline, x_shift, 0);

  /* A glyph that is already a bitmap needs no rendering and would be left
   * alone by FT_Render_Glyph; one that is an outline becomes coverage here.
   *
   * An embedded bitmap comes back grayscale whatever was asked for, which is
   * why the channel count below is read off the result rather than off the
   * request.
   */
  if (ft_face->glyph->format != FT_GLYPH_FORMAT_BITMAP) {
    error = FT_Render_Glyph(ft_face->glyph, render_mode_of(antialias));
    if (error != 0)
      return error;
  }

  FT_Bitmap *bitmap = &ft_face->glyph->bitmap;
  uint32_t channels = 1;
  if (bitmap->rows != 0) {
    switch (bitmap->pixel_mode) {
    case FT_PIXEL_MODE_GRAY:
      break;
    case FT_PIXEL_MODE_LCD:
      channels = 3;
      break;
    default:
      return LENORE_GLYPH_NOT_COVERAGE;
    }
  }
  if (bitmap->pitch < 0)
    return LENORE_GLYPH_BOTTOM_UP;

  out->pixels = bitmap->buffer;
  out->pitch = (uint32_t)bitmap->pitch;
  /* FreeType counts a subpixel bitmap's width in subpixels, and it is always a
   * whole number of pixels: `ft_glyphslot_preset_bitmap' in `ftobjs.c' builds
   * it as the pixel width times three. */
  out->channels = channels;
  out->width = bitmap->width / channels;
  out->rows = bitmap->rows;
  out->left = ft_face->glyph->bitmap_left;
  out->top = ft_face->glyph->bitmap_top;
  return 0;
}
