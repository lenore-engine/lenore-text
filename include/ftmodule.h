/*
 * The FreeType modules this build compiles, and nothing else.
 *
 * FreeType registers its drivers from this list rather than from the set of
 * source files, so the two have to agree: a module named here whose source is
 * not compiled fails to link, and a source compiled without its name here is
 * dead weight the library never reaches. Reached through FT_CONFIG_MODULES_H,
 * which is FreeType's documented override point (include/freetype/config/
 * ftheader.h, "FT_CONFIG_MODULES_H").
 *
 * What is left out, and why it can be: the bitmap font formats (bdf, pcf,
 * winfnt, pfr), the PostScript wrappers around them (type1, type42, cid), the
 * table validators (gxvalid, otvalid), the monochrome rasteriser, the signed
 * distance renderers and the SVG hook. A user interface reads a scalable
 * TrueType or OpenType face and wants anti-aliased coverage from it.
 */

FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
