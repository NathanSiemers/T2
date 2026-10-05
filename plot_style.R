## plot_style.R
## ============================================================================
## Everything about how a T2 plot LOOKS, in one place:
##
##   1. the Appearance tab's fixed settings ("Fiddly Options"): each one is a
##      real ggplot value (a font size in points, an alpha, a point size) picked
##      from a menu -- T2_STYLE lists them with their ggplot name, menu and
##      default
##   2. t2_base_theme() / t2_font_theme(): the theme those settings produce
##   3. the searchable registry of every other ggplot setting a user may tweak
##      (T2_TWEAKS): all theme elements of the installed ggplot2 plus the
##      drawing settings of the layers T2 uses. t2_validate_tweak() is the
##      server-side whitelist for their values; t2_tweak_theme() turns the
##      validated values into a theme().
##
## SECURITY: nothing a browser sends is ever parsed or evaluated. A tweak is
## applied only if its id is a key of T2_TWEAKS (generated here, not by the
## client), and its value must validate against that entry: a number inside
## the entry's range, a member of its fixed choice list, a colour name R knows
## or a #hex colour, or (for the few free-text labels) a length-capped string
## that ggplot draws literally.
## ============================================================================

library(ggplot2)

## ---------------------------------------------------------------------------
## 0. Bundled fonts
## ---------------------------------------------------------------------------
## fonts/ holds open fonts with the metrics of Arial (Liberation Sans) and
## Cambria (Caladea). Pointing XDG_DATA_HOME at the app directory makes
## fontconfig -- and with it BOTH the PNG/TIFF device (ragg) and the PDF device
## (cairo) -- find <app>/fonts, with nothing installed in the image. It has to
## be set before the first text is measured, so it is done here, first thing.
## (Set T2_NO_BUNDLED_FONTS to any value to leave XDG_DATA_HOME alone.)
T2_FONT_DIR = file.path(getwd(), "fonts")
if (dir.exists(T2_FONT_DIR) && !nzchar(Sys.getenv("T2_NO_BUNDLED_FONTS"))) {
    Sys.setenv(XDG_DATA_HOME = dirname(T2_FONT_DIR))
}

## ---------------------------------------------------------------------------
## 1. The fixed Appearance settings
## ---------------------------------------------------------------------------
.t2_font_menu = c(0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 22, 24, 28, 32, 40)

## id -> label (the made-up name), gg (what ggplot calls it), choices, default.
## A font size of 0 removes that text; a point size of 0 draws no points.
T2_STYLE = list(
    point_size      = list(label = "Point size", gg = "geom_point(size = )",
                           choices = c(0, 0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6, 8, 10, 12, 15, 20),
                           default = 1.5),
    alpha           = list(label = "Transparency", gg = "geom_point(alpha = )",
                           choices = c(0, 0.02, 0.05, 0.08, 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1),
                           default = 0.3),
    title_size      = list(label = "Title size", gg = "plot.title = element_text(size = )",
                           choices = .t2_font_menu, default = 16),
    subtitle_size   = list(label = "Subtitle size", gg = "plot.subtitle = element_text(size = )",
                           choices = .t2_font_menu, default = 11),
    axis_title_size = list(label = "Axis title size", gg = "axis.title = element_text(size = )",
                           choices = .t2_font_menu, default = 14),
    axis_text_size  = list(label = "Axis label size", gg = "axis.text = element_text(size = )",
                           choices = .t2_font_menu, default = 11),
    strip_size      = list(label = "Multi-graph label size", gg = "strip.text = element_text(size = )",
                           choices = .t2_font_menu, default = 11),
    legend_size     = list(label = "Legend font size", gg = "legend.text = element_text(size = )",
                           choices = .t2_font_menu, default = 11),
    ncols           = list(label = "Multi-graph columns", gg = "facet_wrap(ncol = )",
                           choices = c(1:16, 20, 25, 30, 40, 50), default = 8),
    plot_height     = list(label = "Plot height (pixels)", gg = NULL,
                           choices = c(300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200, 1400,
                                       1600, 1800, 2000, 2400, 2800, 3200, 4000),
                           default = 700)
)
t2_style_default = function(id) T2_STYLE[[id]]$default
## the numeric Appearance settings a plot is styled with (plot_height is the
## page's business, not the plot's)
T2_STYLE_ARGS = setdiff(names(T2_STYLE), "plot_height")

## ---------------------------------------------------------------------------
## 2. Themes
## ---------------------------------------------------------------------------
## Font sizes + legend visibility only: laid over ANY plot (scatter, boxplot,
## Kaplan-Meier). Size 0 removes the text.
t2_font_theme = function(title_size = 16, subtitle_size = 11, axis_title_size = 14,
                         axis_text_size = 11, strip_size = 11, legend_size = 11,
                         show_legend = TRUE) {
    txt = function(s, ...) if (isTRUE(s > 0)) element_text(size = s, ...) else element_blank()
    th = theme(plot.title    = txt(title_size),
               plot.subtitle = txt(subtitle_size),
               axis.title    = txt(axis_title_size),
               axis.text     = txt(axis_text_size),
               strip.text    = txt(strip_size),
               legend.title  = txt(legend_size),
               legend.text   = txt(legend_size))
    if (!isTRUE(show_legend)) th = th + theme(legend.position = "none")
    th
}

## The complete theme of T2's scatter / box plots.
## base_size drives everything that is not set explicitly (spacing, margins,
## legend keys); 12 is the on-screen look, a printed figure uses about 7.
t2_base_theme = function(title_size = 16, subtitle_size = 11, axis_title_size = 14,
                         axis_text_size = 11, strip_size = 11, legend_size = 11,
                         show_legend = TRUE, base_size = 12, base_family = "sans") {
    th = ggthemes::theme_gdocs(base_size = base_size, base_family = base_family) +
        theme(text = element_text(colour = "black"),
              legend.title = element_text(colour = "black"),
              legend.text = element_text(colour = "black"),
              panel.background = element_rect(fill = "white"),
              plot.caption = element_text(size = 0.75 * base_size)) +
        t2_font_theme(title_size, subtitle_size, axis_title_size, axis_text_size,
                      strip_size, legend_size, show_legend)
    ## category labels on X read bottom-to-top (unless axis text is switched off)
    if (isTRUE(axis_text_size > 0))
        th = th + theme(axis.text.x = element_text(angle = 90, hjust = 1))
    th
}

## ---------------------------------------------------------------------------
## 3. The tweak registry
## ---------------------------------------------------------------------------
.t2_menus = list(
    size      = .t2_font_menu,
    angle     = c(0, 15, 30, 45, 60, 75, 90, 105, 120, 135, 150, 165, 180, 225, 270, 315),
    just      = seq(0, 1, by = 0.05),
    lineheight = seq(0.5, 2.4, by = 0.1),
    linewidth = c(0, 0.1, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.75, 0.8, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5),
    pt        = c(0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 50, 60),
    ratio     = c(0.25, 0.33, 0.5, 0.6, 0.75, 0.8, 1, 1.25, 1.33, 1.5, 1.6, 1.75, 2, 2.5, 3, 4),
    unit01    = seq(0, 1, by = 0.05)
)
.t2_ranges = list(size = c(0, 200), angle = c(-360, 360), just = c(-2, 3), lineheight = c(0.1, 10),
                  linewidth = c(0, 50), pt = c(0, 500), ratio = c(0.05, 20), unit01 = c(0, 1))
T2_COLOURS = c("black", "white", "transparent", "grey10", "grey20", "grey30", "grey40", "grey50",
               "grey60", "grey70", "grey80", "grey90", "grey95", "red", "firebrick", "darkorange",
               "gold", "forestgreen", "darkgreen", "steelblue", "royalblue", "navy", "purple",
               "magenta", "brown", "#0D0887", "#9C179E", "#ED7953", "#F0F921")
T2_LINETYPES = c("solid", "dashed", "dotted", "dotdash", "longdash", "twodash", "blank")
T2_FACES     = c("plain", "bold", "italic", "bold.italic")
## fonts: the generic families plus the two bundled in fonts/ (open fonts with
## the same metrics as Arial and Cambria; see figure_export.R)
T2_FAMILIES  = c("sans" = "sans", "serif" = "serif", "mono" = "mono",
                 "Arial-compatible (Liberation Sans)" = "Liberation Sans",
                 "Cambria-compatible (Caladea)" = "Caladea")
T2_SHAPES    = stats::setNames(as.character(0:25), c(
    "0 square (open)", "1 circle (open)", "2 triangle (open)", "3 plus", "4 cross",
    "5 diamond (open)", "6 triangle down (open)", "7 square cross", "8 asterisk",
    "9 diamond plus", "10 circle plus", "11 star", "12 square plus", "13 circle cross",
    "14 square triangle", "15 square (solid)", "16 circle (solid, small edge)",
    "17 triangle (solid)", "18 diamond (solid)", "19 circle (solid)", "20 bullet",
    "21 circle (filled)", "22 square (filled)", "23 diamond (filled)",
    "24 triangle (filled)", "25 triangle down (filled)"))

## one registry entry
.tw = function(id, group, label, gg, kind, default = NULL, menu = NULL, choices = NULL,
               element = NULL, prop = NULL, etype = NULL) {
    list(id = id, group = group, label = label, gg = gg, kind = kind, default = default,
         menu = menu, choices = choices, element = element, prop = prop, etype = etype)
}

## element property -> (kind, menu)
.t2_props = list(
    text = list(size = "size", colour = "colour", face = "face", family = "family",
                angle = "angle", hjust = "just", vjust = "just", lineheight = "lineheight"),
    line = list(colour = "colour", linewidth = "linewidth", linetype = "linetype"),
    rect = list(fill = "colour", colour = "colour", linewidth = "linewidth", linetype = "linetype")
)
.t2_prop_entry = function(ptype) {
    switch(ptype,
           colour   = list(kind = "colour"),
           face     = list(kind = "enum", choices = T2_FACES),
           family   = list(kind = "enum", choices = T2_FAMILIES),
           linetype = list(kind = "enum", choices = T2_LINETYPES),
           list(kind = "num", menu = ptype))
}

## theme settings that take one value from a fixed list
.t2_theme_enums = list(
    legend.position        = c("right", "left", "top", "bottom", "inside", "none"),
    legend.direction       = c("vertical", "horizontal"),
    legend.box             = c("vertical", "horizontal"),
    legend.box.just        = c("top", "bottom", "left", "right", "center"),
    legend.justification   = c("center", "left", "right", "top", "bottom"),
    legend.text.position   = c("right", "left", "top", "bottom"),
    legend.title.position  = c("top", "bottom", "left", "right"),
    legend.byrow           = c("FALSE", "TRUE"),
    plot.title.position    = c("panel", "plot"),
    plot.caption.position  = c("panel", "plot"),
    strip.placement        = c("inside", "outside"),
    strip.clip             = c("on", "off", "inherit"),
    panel.ontop            = c("FALSE", "TRUE")
)

t2_build_tweaks = function() {
    ## unit conversion needs a graphics device; use a throw-away null device so
    ## that building the registry at start-up never creates an Rplots.pdf
    grDevices::pdf(NULL)
    dev_own = grDevices::dev.cur()
    on.exit(grDevices::dev.off(dev_own), add = TRUE)
    out = list()
    add = function(e) out[[e$id]] <<- e
    base = t2_base_theme()
    ## a theme in which nothing is blank, to learn every element's type
    probe = theme_grey() + theme(axis.line = element_line(), panel.border = element_rect(fill = NA),
                                 legend.box.background = element_rect(),
                                 panel.grid.minor = element_line(), axis.ticks = element_line())
    calc = function(nm, th) tryCatch(suppressWarnings(calc_element(nm, th)), error = function(e) NULL)
    val = function(el, p) {
        v = tryCatch(el[[p]], error = function(e) NULL)
        if (is.null(v) || length(v) != 1 || is.na(v)) NULL else v
    }
    lty_name = function(v) {
        if (is.numeric(v)) c("blank", "solid", "dashed", "dotted", "dotdash", "longdash", "twodash")[v + 1]
        else as.character(v)
    }
    tree = names(get_element_tree())
    tree = tree[!grepl("\\.(theta|r)$|^palette\\.|^plot\\.tag|^(point|polygon|geom)$", tree)]

    for (nm in tree) {
        pe = calc(nm, probe)
        etype = if (inherits(pe, "element_text")) "text"
                else if (inherits(pe, "element_line")) "line"
                else if (inherits(pe, "element_rect")) "rect"
                else if (inherits(pe, "unit") && length(pe) == 4) "margin"   # t, r, b, l
                else if (inherits(pe, "unit") && !inherits(pe, "rel") && length(pe) == 1) "unit"
                else NA_character_
        if (is.na(etype)) next
        be = calc(nm, base)                      # what T2 actually uses
        if (etype %in% c("text", "line", "rect")) {
            src = if (inherits(be, paste0("element_", etype))) be else pe
            for (p in names(.t2_props[[etype]])) {
                pt = .t2_props[[etype]][[p]]
                spec = .t2_prop_entry(pt)
                d = val(src, p)
                if (pt == "linetype" && !is.null(d)) d = lty_name(d)
                if (pt == "colour" && is.null(d)) d = "transparent"
                grp = switch(etype, text = "Theme: text", line = "Theme: lines", rect = "Theme: backgrounds and borders")
                add(.tw(id = paste("theme", nm, p, sep = "|"), group = grp,
                        label = sprintf("%s: %s", nm, p),
                        gg = sprintf("theme(%s = element_%s(%s = ))", nm, etype, p),
                        kind = spec$kind, default = d, menu = spec$menu, choices = spec$choices,
                        element = nm, prop = p, etype = etype))
            }
        } else if (etype == "unit") {
            u = if (inherits(be, "unit")) be else pe
            d = tryCatch(round(as.numeric(grid::convertUnit(u, "pt")), 2), error = function(e) NULL)
            add(.tw(id = paste("theme", nm, sep = "|"), group = "Theme: spacing and sizes",
                    label = sprintf("%s (points)", nm), gg = sprintf("theme(%s = unit( , \"pt\"))", nm),
                    kind = "num", default = if (length(d) == 1 && is.finite(d)) d, menu = "pt",
                    element = nm, etype = "unit"))
        } else if (etype == "margin") {
            u = if (inherits(be, "unit")) be else pe
            d = tryCatch(round(as.numeric(grid::convertUnit(u, "pt")), 2), error = function(e) rep(5.5, 4))
            sides = c("top", "right", "bottom", "left")
            for (i in 1:4) {
                add(.tw(id = paste("theme", nm, sides[i], sep = "|"), group = "Theme: spacing and sizes",
                        label = sprintf("%s: %s (points)", nm, sides[i]),
                        gg = sprintf("theme(%s = margin(%s = ))", nm, substr(sides[i], 1, 1)),
                        kind = "num", default = d[i], menu = "pt",
                        element = nm, prop = sides[i], etype = "margin"))
            }
        }
    }
    for (nm in intersect(names(.t2_theme_enums), names(get_element_tree()))) {
        d = tryCatch(base[[nm]], error = function(e) NULL)
        d = if (is.null(d) || length(d) != 1) .t2_theme_enums[[nm]][1] else as.character(d)
        add(.tw(id = paste("theme", nm, sep = "|"), group = "Theme: legend and layout", label = nm,
                gg = sprintf("theme(%s = )", nm), kind = "enum", default = d,
                choices = .t2_theme_enums[[nm]], element = nm, etype = "value"))
    }
    add(.tw("theme|aspect.ratio", "Theme: legend and layout", "aspect.ratio (panel height / width)",
            "theme(aspect.ratio = )", "num", default = NULL, menu = "ratio",
            element = "aspect.ratio", etype = "value"))
    if ("legend.position.inside" %in% names(get_element_tree())) {
        for (ax in c("x", "y")) {
            add(.tw(paste0("theme|legend.position.inside|", ax), "Theme: legend and layout",
                    sprintf("legend.position.inside: %s (0-1, with legend.position = inside)", ax),
                    "theme(legend.position.inside = c(x, y))", "num", default = 0.5, menu = "unit01",
                    element = "legend.position.inside", prop = ax, etype = "xy"))
        }
    }

    ## ---- layers, scales, labels: the settings plotter() reads via gg ----
    g = function(id, group, label, gg, kind, default = NULL, menu = NULL, choices = NULL) {
        add(.tw(id, group, label, gg, kind, default, menu, choices))
    }
    P = "Points"; B = "Boxplots"; S = "Fit line"; F = "Multi-graph (facets)"
    C = "Colour scale and axes"; L = "Titles and labels"
    plasma1 = "#0D0887"
    g("point.shape",  P, "point shape", "geom_point(shape = )", "enum", "19", choices = T2_SHAPES)
    g("point.stroke", P, "point outline width", "geom_point(stroke = )", "num", 0.5, "linewidth")
    g("point.colour", P, "point colour (when no color variable)", "geom_point(colour = )", "colour", plasma1)
    g("jitter.width", P, "jitter width (categorical X)", "position_jitter(width = )", "num", 0.2, "unit01")
    g("boxplot.linewidth", B, "boxplot line width", "geom_boxplot(linewidth = )", "num", 0.5, "linewidth")
    g("boxplot.width",     B, "boxplot width", "geom_boxplot(width = )", "num", 0.75, "unit01")
    g("boxplot.notch",     B, "boxplot notches", "geom_boxplot(notch = )", "enum", "FALSE", choices = c("FALSE", "TRUE"))
    g("boxplot.varwidth",  B, "boxplot width by sample count", "geom_boxplot(varwidth = )", "enum", "FALSE", choices = c("FALSE", "TRUE"))
    g("smooth.method",    S, "fit line method", "geom_smooth(method = )", "enum", "lm", choices = c("lm", "loess"))
    g("smooth.se",        S, "fit line confidence band", "geom_smooth(se = )", "enum", "TRUE", choices = c("TRUE", "FALSE"))
    g("smooth.level",     S, "fit line confidence level", "geom_smooth(level = )", "num", 0.95, "unit01")
    g("smooth.linewidth", S, "fit line width", "geom_smooth(linewidth = )", "num", 1, "linewidth")
    g("smooth.linetype",  S, "fit line type", "geom_smooth(linetype = )", "enum", "solid", choices = setdiff(T2_LINETYPES, "blank"))
    g("smooth.colour",    S, "fit line colour", "geom_smooth(colour = )", "colour", plasma1)
    g("smooth.alpha",     S, "fit line band transparency", "geom_smooth(alpha = )", "num", 0.25, "unit01")
    g("median.show",      S, "median regression line", "geom_quantile(quantiles = 0.5)", "enum", "TRUE", choices = c("TRUE", "FALSE"))
    g("median.linetype",  S, "median regression line type", "geom_quantile(linetype = )", "enum", "dashed", choices = setdiff(T2_LINETYPES, "blank"))
    g("median.colour",    S, "median regression line colour", "geom_quantile(colour = )", "colour", "black")
    g("facet.strip.position", F, "multi-graph label position", "facet_wrap(strip.position = )", "enum", "top", choices = c("top", "bottom", "left", "right"))
    g("facet.dir",            F, "multi-graph fill direction", "facet_wrap(dir = )", "enum", "h", choices = c("h", "v"))
    g("colour.palette",   C, "colour palette", "scale_colour_viridis(option = )", "enum", "plasma",
      choices = c("plasma", "viridis", "magma", "inferno", "cividis", "rocket", "mako", "turbo"))
    g("colour.direction", C, "colour palette direction", "scale_colour_viridis(direction = )", "enum", "1", choices = c("1", "-1"))
    g("colour.end",       C, "colour palette end (0-1)", "scale_colour_viridis(end = )", "num", NULL, "unit01")
    g("legend.ncol",      C, "legend columns (categorical colour)", "guide_legend(ncol = )", "enum", "1",
      choices = as.character(1:8))
    g("scale.x.trans",    C, "X axis transform (numeric X)", "scale_x_continuous(transform = )", "enum", "identity",
      choices = c("identity", "log10", "log2", "sqrt", "reverse"))
    g("scale.y.trans",    C, "Y axis transform (numeric Y)", "scale_y_continuous(transform = )", "enum", "identity",
      choices = c("identity", "log10", "log2", "sqrt", "reverse"))
    for (lb in c("title", "subtitle", "caption", "x", "y", "colour", "size")) {
        g(paste0("labs.", lb), L, sprintf("%s text", switch(lb, x = "X axis title", y = "Y axis title",
                                                           colour = "colour legend title",
                                                           size = "size legend title", lb)),
          sprintf("labs(%s = )", lb), "text", "")
    }
    out
}
T2_TWEAKS = t2_build_tweaks()

## input id of a tweak's widget (ids are generated here; uniqueness is asserted).
## `prefix` separates the Appearance tab's widgets ("") from the Publish tab's
## ("pub_"): two independent sets of the same settings.
t2_tweak_input_id = function(id, prefix = "") paste0(prefix, "tw_", gsub("[^A-Za-z0-9]", "_", id))
stopifnot(!anyDuplicated(vapply(names(T2_TWEAKS), t2_tweak_input_id, "")))

## choices for the search box: grouped, label -> id
t2_tweak_choices = function() {
    grp = vapply(T2_TWEAKS, `[[`, "", "group")
    lab = vapply(T2_TWEAKS, `[[`, "", "label")
    ord = c("Points", "Boxplots", "Fit line", "Multi-graph (facets)", "Colour scale and axes",
            "Titles and labels", "Theme: text", "Theme: lines", "Theme: backgrounds and borders",
            "Theme: legend and layout", "Theme: spacing and sizes")
    lapply(stats::setNames(ord, ord), function(g) stats::setNames(names(T2_TWEAKS)[grp == g], lab[grp == g]))
}

## the value menu a tweak's widget offers (default included, numerically sorted)
t2_tweak_menu = function(tw, default = tw$default) {
    if (tw$kind == "num") {
        m = .t2_menus[[tw$menu]]
        if (!is.null(default)) m = sort(unique(c(m, default)))
        as.character(m)
    } else if (tw$kind == "colour") {
        unique(c(default, T2_COLOURS))
    } else tw$choices
}

## Server-side whitelist for ONE tweak value. Returns the clean value, or NULL
## when the raw value is missing, empty or not acceptable (the tweak is then
## simply not applied).
t2_validate_tweak = function(tw, raw) {
    if (is.null(tw) || is.null(raw)) return(NULL)
    raw = as.character(unlist(raw))[1]
    if (length(raw) != 1 || is.na(raw)) return(NULL)
    if (tw$kind == "text") {
        raw = gsub("[[:cntrl:]]", " ", raw)
        raw = substr(raw, 1, 200)
        return(if (nzchar(trimws(raw))) raw else NULL)
    }
    raw = trimws(raw)
    if (!nzchar(raw)) return(NULL)
    switch(tw$kind,
        num = {
            v = suppressWarnings(as.numeric(raw))
            rng = .t2_ranges[[tw$menu]]
            if (length(v) != 1 || !is.finite(v) || v < rng[1] || v > rng[2]) NULL else v
        },
        enum = if (raw %in% unname(tw$choices)) raw else NULL,
        colour = if (raw == "transparent" || raw %in% grDevices::colors() ||
                     grepl("^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", raw)) raw else NULL,
        NULL)
}

## Validate a whole set: `values` is id -> raw value. Unknown ids are dropped.
t2_validate_tweaks = function(values) {
    out = list()
    for (id in intersect(names(values), names(T2_TWEAKS))) {
        v = t2_validate_tweak(T2_TWEAKS[[id]], values[[id]])
        if (!is.null(v)) out[[id]] = v
    }
    out
}

## theme() built from validated tweaks (the "theme|..." ids); everything else
## in `gg` is read by plotter() directly.
t2_tweak_theme = function(gg) {
    ids = grep("^theme\\|", names(gg), value = TRUE)
    if (length(ids) == 0) return(theme())
    els = unique(vapply(ids, function(id) T2_TWEAKS[[id]]$element, ""))
    args = list()
    for (el in els) {
        mine = ids[vapply(ids, function(id) T2_TWEAKS[[id]]$element == el, NA)]
        et = T2_TWEAKS[[mine[1]]]$etype
        props = stats::setNames(lapply(mine, function(id) gg[[id]]),
                                vapply(mine, function(id) { p = T2_TWEAKS[[id]]$prop; if (is.null(p)) "" else p }, ""))
        args[[el]] =
            if (et == "text") {
                if (identical(props$size, 0)) element_blank() else do.call(element_text, props)
            } else if (et == "line") {
                if (identical(props$linewidth, 0) || identical(props$linetype, "blank")) element_blank()
                else do.call(element_line, props)
            } else if (et == "rect") {
                do.call(element_rect, props)
            } else if (et == "unit") {
                grid::unit(props[[1]], "pt")
            } else if (et == "margin") {
                d = vapply(c("top", "right", "bottom", "left"), function(s) {
                    if (!is.null(props[[s]])) props[[s]]
                    else T2_TWEAKS[[paste("theme", el, s, sep = "|")]]$default
                }, 0)
                margin(d[1], d[2], d[3], d[4], unit = "pt")
            } else if (et == "xy") {
                c(if (!is.null(props$x)) props$x else 0.5, if (!is.null(props$y)) props$y else 0.5)
            } else {
                v = props[[1]]
                if (v %in% c("TRUE", "FALSE")) as.logical(v) else v
            }
    }
    do.call(theme, args)
}

## Lay the Appearance settings over a Kaplan-Meier result (a ggsurvplot, whose
## curve is $plot, or the faceted variant, a plain ggplot): fonts, legend
## visibility and theme tweaks. Layer settings do not apply to survival plots.
## Wrap a title to the width of a figure: a character is about 0.55 em wide,
## and a title has the panel's width (roughly 85% of the figure) to itself.
t2_wrap_text = function(txt, fig_width, font_size) {
    if (is.null(fig_width) || is.null(txt) || !is.character(txt) || !isTRUE(font_size > 0)) return(txt)
    n = max(20, floor(0.85 * fig_width * 72 / (0.55 * font_size)))
    paste(vapply(strsplit(txt, "\n", fixed = FALSE)[[1]],
                 function(l) paste(strwrap(l, width = n), collapse = "\n"), ""), collapse = "\n")
}

t2_style_survival = function(res, style = list(), gg = list(), caption = NULL, fig_width = NULL) {
    th = do.call(t2_font_theme, style[intersect(names(style), names(formals(t2_font_theme)))]) +
        t2_tweak_theme(gg)
    ## "Show legend" off beats any legend.position among the settings
    if (identical(style$show_legend, FALSE)) th = th + theme(legend.position = "none")
    lb = gg[grep("^labs\\.", names(gg), value = TRUE)]
    names(lb) = sub("^labs\\.", "", names(lb))
    ## a source line, when the caller asks for one (Publish tab)
    if (is.null(lb$caption) && length(caption) == 1 && !is.na(caption) && nzchar(caption))
        lb$caption = caption
    keep = attributes(res)[c("t2summary", "km_data", "stats")]
    ## legend columns, and titles wrapped to a figure's width (Publish tab)
    extra = function(p) {
        if (!is.null(gg[["legend.ncol"]])) {
            n = as.integer(gg[["legend.ncol"]])
            p = p + guides(colour = guide_legend(ncol = n), fill = guide_legend(ncol = n))
        }
        if (!is.null(fig_width)) {
            ts = if (is.null(style$title_size)) 12 else style$title_size
            ss = if (is.null(style$subtitle_size)) 10 else style$subtitle_size
            p$labels$title = t2_wrap_text(p$labels$title, fig_width, ts)
            p$labels$subtitle = t2_wrap_text(p$labels$subtitle, fig_width, ss)
        }
        p
    }
    if (inherits(res, "ggsurvplot")) {
        res$plot = extra(res$plot + th)
        if (length(lb)) res$plot = res$plot + do.call(labs, lb)
    } else if (inherits(res, "ggplot")) {
        res = extra(res + th)
        if (length(lb)) res = res + do.call(labs, lb)
        for (a in names(keep)) if (!is.null(keep[[a]])) attr(res, a) = keep[[a]]
    }
    res
}
