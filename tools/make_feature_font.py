#!/usr/bin/env python3
# Generates tests/fonts/Feature.ttf, the second test asset.
#
# Ahem answers everything about metrics and rasterisation and nothing about
# shaping: it carries no GSUB, GPOS or kern table, so nothing in the tree
# exercises a ligature, a contextual form or a kern pair. It also cannot answer
# whether a rasterisation mode moves the shaper's advances, because every Ahem
# advance is a whole em and would survive a rounding to whole pixels unchanged.
#
# This font is generated rather than found so that every expected value is exact
# by construction rather than measured off someone else's design:
#
#   - the em is 1024 units, so at sixteen pixels one pixel is exactly 64 units
#     and one unit is exactly one step of the 26.6 grid HarfBuzz reports on.
#     Every advance is then exact whatever it is, rather than only the ones that
#     divide the em. Ahem's 1000 is why its metrics need a tolerance;
#   - the advances differ from each other, which is what makes the face
#     proportional and a rounding to whole pixels visible;
#   - one ligature and one kern pair, each with a value written here.
#
# Run from this directory:
#
#   python3 tools/make_feature_font.py
#
# fontTools 4.61.1 was what generated the committed file.

import os

from fontTools.fontBuilder import FontBuilder
from fontTools.feaLib.builder import addOpenTypeFeatures
from fontTools.pens.ttGlyphPen import TTGlyphPen

# The em, and the unit that is one whole pixel at sixteen pixels to the em.
UPEM = 1024
PIXEL = UPEM // 16

# Thirteen pixels up and three down at sixteen pixels to the em, so a line is
# exactly the size the face was opened at and each part of it is exact on its
# own. Ahem's 0.8 and 0.2 of a 1000-unit em are 12.8 and 3.2, which is why its
# metrics are compared to within a step of the grid rather than with `==`.
ASCENT = 13 * PIXEL
DESCENT = -3 * PIXEL

# Every glyph is a filled rectangle of its own advance width, spanning the em
# vertically. Two glyphs of different advances are therefore different
# rectangles, which is the whole difference from Ahem.
#
# The advances are multiples of two pixels. The ligature is narrower than the
# two glyphs it replaces, which is what a ligature is for and what makes its
# effect on a run's width a number rather than a direction.
GLYPHS = {
    "space": 4 * PIXEL,
    "A": 12 * PIXEL,
    "V": 8 * PIXEL,
    "f": 6 * PIXEL,
    "i": 4 * PIXEL,
    "f_i": 8 * PIXEL,
}

CMAP = {0x20: "space", 0x41: "A", 0x56: "V", 0x66: "f", 0x69: "i"}

# Two pixels of kerning, negative, which is the direction a pair like AV is
# kerned in every real face.
KERN = -2 * PIXEL

FEATURES = f"""
languagesystem DFLT dflt;
languagesystem latn dflt;

feature liga {{
    sub f i by f_i;
}} liga;

feature kern {{
    pos A V {KERN};
}} kern;
"""


def rectangle(width):
    pen = TTGlyphPen(None)
    if width > 0:
        pen.moveTo((0, DESCENT))
        pen.lineTo((width, DESCENT))
        pen.lineTo((width, ASCENT))
        pen.lineTo((0, ASCENT))
        pen.closePath()
    return pen.glyph()


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, os.pardir, "tests", "fonts", "Feature.ttf")

    order = [".notdef"] + list(GLYPHS)
    builder = FontBuilder(UPEM, isTTF=True)
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap(CMAP)

    # A blank .notdef, so that a codepoint the face has no glyph for draws
    # nothing rather than a box. What a missing codepoint costs is a test of its
    # own and not this font's business.
    outlines = {".notdef": rectangle(0)}
    metrics = {".notdef": (8 * PIXEL, 0)}
    for name, advance in GLYPHS.items():
        # A space is an advance and no ink, like every other font's.
        outlines[name] = rectangle(0 if name == "space" else advance)
        metrics[name] = (advance, 0)

    builder.setupGlyf(outlines)
    builder.setupHorizontalMetrics(metrics)
    builder.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT, lineGap=0)
    builder.setupNameTable(
        {
            "familyName": "Lenore Feature",
            "styleName": "Regular",
            "uniqueFontIdentifier": "Lenore Feature Regular; generated",
            "fullName": "Lenore Feature Regular",
            "psName": "LenoreFeature-Regular",
            "version": "Version 1.000",
        }
    )
    builder.setupOS2(
        sTypoAscender=ASCENT,
        sTypoDescender=DESCENT,
        sTypoLineGap=0,
        usWinAscent=ASCENT,
        usWinDescent=-DESCENT,
    )
    builder.setupPost()

    features = os.path.join(here, "feature.fea")
    with open(features, "w") as handle:
        handle.write(FEATURES)
    addOpenTypeFeatures(builder.font, features)
    os.remove(features)

    builder.save(out)
    print(f"wrote {os.path.normpath(out)}")


if __name__ == "__main__":
    main()
