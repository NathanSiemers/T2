## figure_export.R
## ============================================================================
## Publication-quality figures (the Publish tab).
##
## A figure has a PHYSICAL size (inches) and a resolution. Every size ggplot
## draws with is physical too (points, mm), so a figure drawn at 100 dpi and at
## 600 dpi has the same layout -- only the number of pixels differs. The live
## preview and the download therefore go through ONE function,
## t2_render_figure(), with the same physical size: what the preview shows is
## what the file contains.
##
## The on-screen plot is no guide to a printed figure (the Plot tab is ~19
## "inches" wide in ggplot's terms), so the Publish tab keeps its own style
## values; T2_FIG_PRESETS supplies sizes and matching print-scale defaults.
## Reference for the print defaults: Nature's figure guide (text 5-7 pt at final
## size, Arial/Helvetica, single column 89 mm, double column 183 mm, at most
## 170 mm high, 300 dpi or more, PDF preferred).
## ============================================================================

T2_CITATION = "T2 Database and Search Tool, Nathan O. Siemers, Ph.D., https://www.fiveprime.org"

## ---- fonts ------------------------------------------------------------------
## The bundled fonts in fonts/ are made visible in plot_style.R (it has to
## happen before any text is measured). Here: which choices are usable.
t2_font_available = function(family) {
    if (family %in% c("sans", "serif", "mono")) return(TRUE)
    m = tryCatch(systemfonts::match_fonts(family), error = function(e) NULL)
    !is.null(m) && grepl(gsub(" ", "", family), gsub(" ", "", basename(m$path[1])), ignore.case = TRUE)
}
T2_FIG_FAMILIES = Filter(t2_font_available, as.list(T2_FAMILIES[c(4, 5, 1, 2, 3)]))
T2_FIG_FAMILIES = stats::setNames(unlist(T2_FIG_FAMILIES), names(T2_FIG_FAMILIES))

## ---- presets ----------------------------------------------------------------
## style: the Publish tab's defaults for the fixed style menus;
## base_size: theme base size (spacing, margins, legend keys follow it);
## gg: defaults for registry settings that have no fixed menu (line widths ...)
.t2_print_style = list(point_size = 0.5, alpha = 0.4, title_size = 8, subtitle_size = 6,
                       axis_title_size = 7, axis_text_size = 6, strip_size = 6, legend_size = 6,
                       ncols = 4)
## (legend keys are 1.2 "lines" of the DEVICE's 12 pt in every ggplot theme,
## whatever the base size, so a print figure has to set them itself)
.t2_print_gg = list(smooth.linewidth = 0.5, boxplot.linewidth = 0.3, point.stroke = 0.2,
                    `theme|plot.caption|size` = 5, `theme|legend.key.size` = 8,
                    ## (a ggplot linewidth of 1 is about 2 pt: these are 0.3-0.5 pt rules)
                    `theme|panel.grid.major|linewidth` = 0.15, `theme|axis.line|linewidth` = 0.25,
                    `theme|axis.line.x|linewidth` = 0.25, `theme|axis.ticks|linewidth` = 0.2,
                    `theme|legend.box.spacing` = 4)
## a half-page-wide figure has no room for a legend beside the panel
.t2_narrow_gg = list(`theme|legend.position` = "bottom", legend.ncol = "2")
.t2_slide_style = list(point_size = 2.5, alpha = 0.4, title_size = 24, subtitle_size = 16,
                       axis_title_size = 20, axis_text_size = 16, strip_size = 16, legend_size = 16,
                       ncols = 6)
.t2_slide_gg = list(smooth.linewidth = 1.5, boxplot.linewidth = 0.8, point.stroke = 0.5,
                    `theme|plot.caption|size` = 10, `theme|legend.key.size` = 22)
.preset = function(label, width, height, units, dpi, kind = "print", narrow = FALSE) {
    list(label = label, width = width, height = height, units = units, dpi = dpi,
         base_size = if (kind == "print") 7 else 18,
         style = if (kind == "print") .t2_print_style else .t2_slide_style,
         gg = c(if (kind == "print") .t2_print_gg else .t2_slide_gg,
                if (narrow) .t2_narrow_gg))
}
## A US-letter page with 0.75 in margins has a 7 x 9.5 in text area.
T2_FIG_PRESETS = list(
    half_third = .preset("Half page wide, 1/3 page high (3.5 x 3.2 in)", 3.5, 3.2, "in", 300, narrow = TRUE),
    full_half  = .preset("Full page wide, half page high (7 x 4.75 in)", 7, 4.75, "in", 300),
    nature1    = .preset("Nature single column (89 x 80 mm)", 89, 80, "mm", 450, narrow = TRUE),
    nature2    = .preset("Nature double column (183 x 110 mm)", 183, 110, "mm", 450),
    slide      = .preset("Slide 16:9 (13.33 x 7.5 in)", 13.33, 7.5, "in", 150, kind = "slide")
)
T2_FIG_DEFAULT_PRESET = "half_third"

T2_FIG_DPI     = c(72, 100, 150, 200, 300, 450, 600, 900, 1200)
T2_FIG_FORMATS = c("PNG" = "png", "TIFF (LZW compressed)" = "tiff", "PDF (vector)" = "pdf")
T2_FIG_UNITS   = c("in", "cm", "mm")
## limits: one request must not be able to exhaust the server's memory
T2_FIG_MAX_IN     = 20
T2_FIG_MIN_IN     = 1
T2_FIG_MAX_PIXELS = 60e6

.t2_to_in = function(v, units) v / c("in" = 1, "cm" = 2.54, "mm" = 25.4)[[units]]

## Server-side validation of the figure settings: a plain list of safe values.
## Sizes are clamped to 1-20 in; the resolution is lowered, with a note, if the
## image would exceed the pixel limit.
sanitize_t2_figure = function(input) {
    one = function(v, allowed, default) {
        v = as.character(unlist(v))[1]
        if (length(v) == 1 && !is.na(v) && v %in% allowed) v else default
    }
    preset = one(input$pub_preset, names(T2_FIG_PRESETS), T2_FIG_DEFAULT_PRESET)
    pr = T2_FIG_PRESETS[[preset]]
    units = one(input$pub_units, T2_FIG_UNITS, pr$units)
    side = function(v, default) {
        v = suppressWarnings(as.numeric(unlist(v))[1])
        if (length(v) != 1 || !is.finite(v) || v <= 0) v = default
        min(max(.t2_to_in(v, units), T2_FIG_MIN_IN), T2_FIG_MAX_IN)
    }
    ## a size typed in other units than the preset's still means "the preset"
    ## when the field is empty: convert the preset's own size
    w = side(input$pub_width,  pr$width  * c("in" = 1, "cm" = 2.54, "mm" = 25.4)[[units]] /
                               c("in" = 1, "cm" = 2.54, "mm" = 25.4)[[pr$units]])
    h = side(input$pub_height, pr$height * c("in" = 1, "cm" = 2.54, "mm" = 25.4)[[units]] /
                               c("in" = 1, "cm" = 2.54, "mm" = 25.4)[[pr$units]])
    dpi = suppressWarnings(as.numeric(unlist(input$pub_dpi))[1])
    dpi = if (length(dpi) == 1 && is.finite(dpi)) T2_FIG_DPI[which.min(abs(T2_FIG_DPI - dpi))] else pr$dpi
    format = one(input$pub_format, unname(T2_FIG_FORMATS), "png")
    note = NULL
    if (format != "pdf" && w * h * dpi^2 > T2_FIG_MAX_PIXELS) {
        ok = T2_FIG_DPI[w * h * T2_FIG_DPI^2 <= T2_FIG_MAX_PIXELS]
        new = if (length(ok)) max(ok) else min(T2_FIG_DPI)
        note = sprintf("%d dpi would be %.0f megapixels; reduced to %d dpi (limit %.0f megapixels).",
                       as.integer(dpi), w * h * dpi^2 / 1e6, as.integer(new), T2_FIG_MAX_PIXELS / 1e6)
        dpi = new
    }
    src = suppressWarnings(as.logical(unlist(input$pub_source))[1])
    list(preset = preset, width = w, height = h, units = units, dpi = dpi, format = format,
         family = one(input$pub_family, unname(T2_FIG_FAMILIES), unname(T2_FIG_FAMILIES)[1]),
         source_line = if (length(src) == 1 && !is.na(src)) src else TRUE,
         base_size = pr$base_size, note = note)
}

## what the user is about to get, in words
t2_figure_readout = function(fig) {
    px = if (fig$format == "pdf") "vector"
         else sprintf("%s x %s pixels", format(round(fig$width * fig$dpi), big.mark = ","),
                      format(round(fig$height * fig$dpi), big.mark = ","))
    sprintf("%.2f x %.2f in  (%.0f x %.0f mm)%s  =  %s, %s",
            fig$width, fig$height, fig$width * 25.4, fig$height * 25.4,
            if (fig$format == "pdf") "" else sprintf(" at %d dpi", as.integer(fig$dpi)),
            px, toupper(fig$format))
}

## the printable object inside whatever fun_plot1() returned, or NULL
t2_figure_object = function(res) {
    if (inherits(res, "ggsurvplot") || inherits(res, "ggplot")) return(res)
    if (is.list(res) && !is.null(res$plot)) return(res$plot)
    NULL
}

## Draw `obj` (a ggplot, or a ggsurvplot with its risk table) into `file`.
## The ONE rendering path of preview and download: same physical size, only
## `dpi` differs between them.
t2_render_figure = function(obj, file, width, height, dpi = 300, format = "png") {
    stopifnot(is.numeric(width), is.numeric(height), is.numeric(dpi),
              width >= T2_FIG_MIN_IN, width <= T2_FIG_MAX_IN,
              height >= T2_FIG_MIN_IN, height <= T2_FIG_MAX_IN,
              format %in% unname(T2_FIG_FORMATS))
    if (format != "pdf") stopifnot(width * height * dpi^2 <= T2_FIG_MAX_PIXELS * 1.001)
    switch(format,
        png  = ragg::agg_png(file, width = width, height = height, units = "in", res = dpi,
                             background = "white"),
        tiff = ragg::agg_tiff(file, width = width, height = height, units = "in", res = dpi,
                              compression = "lzw", background = "white"),
        pdf  = grDevices::cairo_pdf(file, width = width, height = height, onefile = TRUE))
    dev = grDevices::dev.cur()
    on.exit(if (dev %in% grDevices::dev.list()) grDevices::dev.off(dev), add = TRUE)
    ## a ggsurvplot starts its own new page; on a fresh device that would put
    ## an empty first page into a PDF
    if (inherits(obj, "ggsurvplot")) suppressWarnings(print(obj, newpage = FALSE))
    else suppressWarnings(print(obj))
    grDevices::dev.off(dev)
    invisible(file)
}

## the resolution the PREVIEW is drawn at: the figure's own, unless that would
## be a needlessly large image to send to the browser for a fit-to-window view
t2_preview_dpi = function(fig, zoom = "fit", max_px = 1600) {
    if (identical(zoom, "pixels")) return(fig$dpi)
    min(fig$dpi, floor(max_px / max(fig$width, fig$height)))
}

## T2_<x>_vs_<y>_<w>x<h>in_<dpi>dpi.<ext>, from validated values only
t2_figure_filename = function(inp, fig) {
    clean = function(v) gsub("[^A-Za-z0-9.-]+", "-", paste(head(as.character(v), 3), collapse = "+"))
    sprintf("T2_%s_vs_%s_%sx%sin%s.%s", clean(inp$x), clean(inp$y),
            format(round(fig$width, 2)), format(round(fig$height, 2)),
            if (fig$format == "pdf") "" else sprintf("_%ddpi", as.integer(fig$dpi)),
            fig$format)
}
