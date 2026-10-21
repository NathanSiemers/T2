## test_figure_export.R — publication figures (figure_export.R): the files have
## exactly the size asked for, the preview shows what the download contains,
## the limits hold, and the bundled fonts are really used.
##   Rscript test_figure_export.R        (from the app directory)
suppressMessages({
  source("global.R")
  source("lib.R"); source("input_validation.R")
})
grDevices::pdf(NULL)
source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero, quiet()
tmp <- function(ext) tempfile(fileext = paste0(".", ext))

## minimal readers, so the checks do not depend on the code under test
png_info <- function(f) {
  r <- readBin(f, "raw", 64)
  int <- function(x) sum(as.integer(x) * 256^(3:0))
  phys <- grepRaw("pHYs", readBin(f, "raw", 4096), fixed = TRUE)
  rr <- readBin(f, "raw", 4096)
  list(width = int(r[17:20]), height = int(r[21:24]),
       dpi = if (length(phys)) round(int(rr[(phys + 4):(phys + 7)]) * 0.0254) else NA)
}
tiff_info <- function(f) {
  r <- readBin(f, "raw", file.size(f))
  le <- identical(rawToChar(r[1:2]), "II")
  num <- function(x) { x <- as.numeric(as.integer(x)); if (le) x <- rev(x); sum(x * 256^((length(x) - 1):0)) }
  ifd <- num(r[5:8]); n <- num(r[(ifd + 1):(ifd + 2)])
  tags <- list()
  for (i in seq_len(n)) {
    e <- r[(ifd + 3 + (i - 1) * 12):(ifd + 2 + i * 12)]
    typ <- num(e[3:4])
    val <- if (typ == 3) num(e[9:10]) else num(e[9:12])
    if (typ == 5) { off <- val; val <- num(r[(off + 1):(off + 4)]) / num(r[(off + 5):(off + 8)]) }
    tags[[as.character(num(e[1:2]))]] <- val
  }
  list(magic = num(r[3:4]), width = tags[["256"]], height = tags[["257"]],
       compression = tags[["259"]], xres = tags[["282"]], unit = tags[["296"]])
}
## PDFs are inspected with pdftools (their page objects are compressed)
pdf_info <- function(f) {
  sz <- pdftools::pdf_pagesize(f)
  list(header = rawToChar(readBin(f, "raw", 5)), pages = nrow(sz),
       box = c(0, 0, sz$width[1], sz$height[1]), fonts = pdftools::pdf_fonts(f)$name)
}
if (!requireNamespace("pdftools", quietly = TRUE)) stop("this test needs the pdftools package")

cat("== figure settings are validated ==\n")
d <- sanitize_t2_figure(list())
ok(d$preset == T2_FIG_DEFAULT_PRESET && d$width == 3.5 && d$height == 3.2 && d$dpi == 300 &&
   d$format == "png" && isTRUE(d$source_line),
   "no input: the default preset (half page wide, 1/3 page high, 300 dpi PNG)")
ok(identical(d$family, "Liberation Sans"), "default font is the bundled Arial-compatible one")
m <- sanitize_t2_figure(list(pub_width = 89, pub_height = 80, pub_units = "mm", pub_dpi = 450, pub_format = "tiff"))
ok(abs(m$width - 89 / 25.4) < 1e-9 && abs(m$height - 80 / 25.4) < 1e-9 && m$dpi == 450 && m$format == "tiff",
   "mm are converted to inches")
j <- sanitize_t2_figure(list(pub_preset = "x'; DROP", pub_width = "abc", pub_height = -3, pub_units = "furlong",
                             pub_dpi = "1e9", pub_format = "exe", pub_family = "../../etc/passwd", pub_source = "maybe"))
ok(j$preset == T2_FIG_DEFAULT_PRESET && j$width == 3.5 && j$height == 3.2 && j$units == "in" &&
   j$dpi == max(T2_FIG_DPI) && j$format == "png" && j$family == "Liberation Sans" && isTRUE(j$source_line),
   "junk falls back to defaults / the nearest allowed value")
big <- sanitize_t2_figure(list(pub_width = 500, pub_height = 0.01, pub_units = "in", pub_dpi = 300))
ok(big$width == T2_FIG_MAX_IN && big$height == T2_FIG_MIN_IN, "sizes are clamped to 1-20 inches")
mp <- sanitize_t2_figure(list(pub_width = 20, pub_height = 20, pub_units = "in", pub_dpi = 1200, pub_format = "tiff"))
ok(mp$dpi < 1200 && mp$width * mp$height * mp$dpi^2 <= T2_FIG_MAX_PIXELS && grepl("megapixels", mp$note),
   sprintf("over the pixel limit: resolution lowered to %d dpi, with a note", as.integer(mp$dpi)))
pv <- sanitize_t2_figure(list(pub_width = 20, pub_height = 20, pub_units = "in", pub_dpi = 1200, pub_format = "pdf"))
ok(is.null(pv$note), "a PDF is vector: no pixel limit applies")
ok(tryCatch({ t2_render_figure(ggplot(), tmp("png"), 30, 30, 300, "png"); FALSE }, error = function(e) TRUE) &&
   tryCatch({ t2_render_figure(ggplot(), tmp("png"), 20, 20, 1200, "png"); FALSE }, error = function(e) TRUE) &&
   tryCatch({ t2_render_figure(ggplot(), tmp("sh"), 3, 3, 300, "sh"); FALSE }, error = function(e) TRUE),
   "the renderer itself refuses oversize figures and unknown formats")
ok(grepl("^T2_CD8A_vs_FOXP3_3.5x3.2in_300dpi\\.png$", t2_figure_filename(list(x = "CD8A", y = "FOXP3"), d)) &&
   !grepl("[^A-Za-z0-9._+-]", t2_figure_filename(list(x = "a/../b c", y = "x;rm -rf"), d)),
   "file names are built from cleaned values")

cat("\n== a real figure, in all three formats ==\n")
b <- load_dataset_bundle("TCGA")
draw <- function(inp, preset = "half_third", family = "Liberation Sans", source = TRUE, extra_gg = list()) {
  pr <- T2_FIG_PRESETS[[preset]]
  inp <- utils::modifyList(c(list(cohort = "all", nonormal = FALSE, allComplete = TRUE, smooth = "TRUE",
                                  show_legend = TRUE), pr$style), inp)
  r <- quiet(fun_plot1(inp, reactive = FALSE, ctx = t2_plot_ctx(b),
                       gg = utils::modifyList(pr$gg, extra_gg), base_size = pr$base_size, base_family = family,
                       caption = if (source) T2_CITATION else "",
                       fig_width = .t2_to_in(pr$width, pr$units)))
  t2_figure_object(r)
}
t0 <- Sys.time(); p <- draw(list(x = "CD8A", y = "FOXP3", color = "sample_type")); t_first <- as.numeric(Sys.time() - t0)
t0 <- Sys.time(); p <- draw(list(x = "CD8A", y = "FOXP3", color = "sample_type")); t_again <- as.numeric(Sys.time() - t0)
ok(inherits(p, "ggplot"), "the figure object builds")
ok(t_again < t_first, sprintf("a redraw reuses the data (%.1fs, then %.1fs)", t_first, t_again))

f <- tmp("png"); t2_render_figure(p, f, 3.5, 3.2, 300, "png"); i <- png_info(f)
ok(i$width == 1050 && i$height == 960 && i$dpi == 300,
   sprintf("PNG: 3.5 x 3.2 in at 300 dpi is %d x %d pixels, tagged %s dpi", i$width, i$height, i$dpi))
f6 <- tmp("png"); t2_render_figure(p, f6, 3.5, 3.2, 600, "png"); i6 <- png_info(f6)
ok(i6$width == 2100 && i6$height == 1920 && i6$dpi == 600, "PNG at 600 dpi: twice the pixels, same inches")
ft <- tmp("tiff"); t2_render_figure(p, ft, 3.5, 3.2, 300, "tiff"); ti <- tiff_info(ft)
ok(ti$magic == 42 && ti$width == 1050 && ti$height == 960 && ti$compression == 5 && round(ti$xres) == 300,
   sprintf("TIFF: %d x %d pixels, LZW compressed, %d dpi", ti$width, ti$height, round(ti$xres)))
fp <- tmp("pdf"); t2_render_figure(p, fp, 3.5, 3.2, 300, "pdf"); pi <- pdf_info(fp)
## (the cairo PDF device sizes its page in whole points: within 1/72 inch)
ok(pi$header == "%PDF-" && pi$pages == 1 && all(abs(pi$box - c(0, 0, 3.5 * 72, 3.2 * 72)) < 1),
   sprintf("PDF: one page of %.1f x %.1f points (3.5 x 3.2 in = 252 x 230.4)", pi$box[3], pi$box[4]))
ok(any(grepl("LiberationSans", pi$fonts)) && !any(grepl("Nimbus|DejaVu", pi$fonts)),
   sprintf("PDF embeds the chosen font (%s)", paste(pi$fonts, collapse = ", ")))
pc <- draw(list(x = "CD8A", y = "FOXP3"), family = "Caladea")
fc <- tmp("pdf"); t2_render_figure(pc, fc, 3.5, 3.2, 300, "pdf")
ok(any(grepl("Caladea", pdf_info(fc)$fonts)), "the Cambria-compatible font is used when chosen")
ok(all(vapply(c("Liberation Sans", "Caladea"), function(fam)
     grepl(normalizePath("fonts"), systemfonts::match_fonts(fam)$path, fixed = TRUE), NA)),
   "both fonts come from the app's own fonts/ directory")

cat("\n== the preview is the figure ==\n")
## the download at 300 dpi, shrunk to 100 dpi, against a preview drawn at 100 dpi
fl <- tmp("png"); t2_render_figure(p, fl, 3.5, 3.2, 100, "png")
lo <- png::readPNG(fl)[, , 1:3]; hi <- png::readPNG(f)[, , 1:3]
shrink <- function(a, k) {
  out <- array(0, c(dim(a)[1] / k, dim(a)[2] / k, 3))
  for (ch in 1:3) for (di in 1:k) for (dj in 1:k)
    out[, , ch] <- out[, , ch] + a[seq(di, dim(a)[1], k), seq(dj, dim(a)[2], k), ch]
  out / k^2
}
sm <- shrink(hi, 3)
ok(identical(dim(sm), dim(lo)), "a 100 dpi preview and the shrunken 300 dpi file have the same pixel size")
blur <- function(a) { n <- dim(a); (a[1:(n[1]-1), 1:(n[2]-1), ] + a[2:n[1], 1:(n[2]-1), ] + a[1:(n[1]-1), 2:n[2], ] + a[2:n[1], 2:n[2], ]) / 4 }
cr <- cor(as.vector(blur(lo)), as.vector(blur(sm)))
ok(cr > 0.95, sprintf("same layout at both resolutions (image correlation %.3f)", cr))
## a different size is a different picture: the check above is not vacuous
fo <- tmp("png"); t2_render_figure(p, fo, 3.5 * 1.25, 3.2 * 1.25, 80, "png")
ot <- png::readPNG(fo)[, , 1:3]
ok(identical(dim(ot), dim(lo)) && cor(as.vector(blur(ot)), as.vector(blur(lo))) < cr - 0.05,
   "the same plot at another physical size does NOT match (layout depends on inches, not pixels)")
fg <- sanitize_t2_figure(list(pub_width = 7, pub_height = 4.75, pub_units = "in", pub_dpi = 600))
ok(t2_preview_dpi(fg, "fit") < 600 && t2_preview_dpi(fg, "fit") * 7 <= 1600 && t2_preview_dpi(fg, "pixels") == 600 &&
   t2_preview_dpi(d, "fit") == 300,
   "fit-to-window previews are capped in pixels; pixel-for-pixel uses the real resolution")

cat("\n== print-scale defaults, source line, wrapping ==\n")
th <- p$theme
ok(calc_element("axis.text.y", th)$size == 6 && calc_element("plot.title", th)$size == 8 &&
   calc_element("legend.text", th)$size == 6 && calc_element("plot.caption", th)$size == 5 &&
   all(c(calc_element("axis.text.y", th)$size, calc_element("plot.title", th)$size) >= 5 &
       c(calc_element("axis.text.y", th)$size, calc_element("legend.text", th)$size) <= 7),
   "preset text sizes are within the 5-7 pt (8 pt title) journals ask for")
ok(identical(calc_element("text", th)$family, "Liberation Sans") && identical(th$legend.position, "bottom") &&
   as.numeric(grid::convertUnit(th$legend.key.size, "pt")) == 8,
   "font, compact legend keys and a bottom legend for the half-width figure")
ok(identical(p$labels$caption, T2_CITATION), "the source line is the T2 citation")
ok(is.null(draw(list(x = "CD8A", y = "FOXP3"), source = FALSE)$labels$caption), "and can be switched off")
long <- draw(list(x = c("CD8A", "CD8B", "CD3E", "CD3D", "GZMB", "PRF1"), y = "FOXP3"))
ok(grepl("\n", long$labels$title) && max(nchar(strsplit(long$labels$title, "\n")[[1]])) < 75,
   "a long title is wrapped to the figure's width")
sl <- draw(list(x = "CD8A", y = "FOXP3"), preset = "slide")
ok(calc_element("axis.text.y", sl$theme)$size == 16 && calc_element("plot.title", sl$theme)$size == 24,
   "the slide preset uses slide-scale text")
tw <- draw(list(x = "CD8A", y = "FOXP3", color = "sample_type"),
           extra_gg = list(`theme|legend.position` = "right", legend.ncol = "1", `theme|axis.text.x|angle` = 0))
ok(identical(tw$theme$legend.position, "right") && calc_element("axis.text.x", tw$theme)$angle == 0,
   "the user's own settings override the preset's")

## "Show legend" off must win over a legend position, including the one the
## half-width preset sets by default (it did not: the preset's "bottom" won)
drawn <- function(obj) {
  g <- ggplotGrob(if (inherits(obj, "ggsurvplot")) obj$plot else obj)
  any(grepl("guide-box", g$layout$name) & vapply(g$grobs, function(x) !inherits(x, "zeroGrob"), NA))
}
ok(drawn(p) && !drawn(draw(list(x = "CD8A", y = "FOXP3", color = "sample_type", show_legend = FALSE))),
   "Show legend off hides the legend in the half-width preset (which positions it at the bottom)")
ok(!drawn(draw(list(x = "CD8A", y = "FOXP3", color = "sample_type", show_legend = FALSE),
               extra_gg = list(`theme|legend.position` = "top"))) &&
   !drawn(draw(list(x = "OS", y = "MKI67", cohort = "LUAD", show_legend = FALSE))) &&
   drawn(draw(list(x = "OS", y = "MKI67", cohort = "LUAD"))),
   "...also against a user-chosen legend position, and on survival figures")

cat("\n== survival figures ==\n")
km <- draw(list(x = "OS", y = "MKI67", cohort = "LUAD"))
ok(inherits(km, "ggsurvplot") && identical(km$plot$labels$caption, T2_CITATION), "Kaplan-Meier figure builds, with source line")
for (fmt in c("png", "tiff", "pdf")) {
  f <- tmp(fmt); r <- tryCatch({ t2_render_figure(km, f, 3.5, 3.2, 300, fmt); TRUE }, error = function(e) conditionMessage(e))
  detail <- if (!isTRUE(r)) r else if (fmt == "png") sprintf("%d x %d px", png_info(f)$width, png_info(f)$height)
            else if (fmt == "tiff") sprintf("%d x %d px", tiff_info(f)$width, tiff_info(f)$height)
            else sprintf("%d page(s)", pdf_info(f)$pages)
  good <- isTRUE(r) && (if (fmt == "pdf") pdf_info(f)$pages == 1 else if (fmt == "png") png_info(f)$width == 1050 else tiff_info(f)$width == 1050)
  ok(good, sprintf("Kaplan-Meier with risk table as %s: %s", toupper(fmt), detail))
}
ok(identical(km$table$scales$get_scales("y")$labels, rep("—", 3)),
   "risk-table row markers are plain dashes (not survminer's escaped ones)")
kf <- draw(list(x = "OS", y = "MKI67", cohort = c("LUAD", "LUSC"), facet = "cohort"), preset = "full_half")
f <- tmp("png"); t2_render_figure(kf, f, 7, 4.75, 300, "png")
ok(png_info(f)$width == 2100 && png_info(f)$height == 1425, "faceted Kaplan-Meier figure: 7 x 4.75 in")

cat("\n== text-element switches and the filter caption ==\n")
sw <- sanitize_t2_figure(list())
ok(all(unlist(sw[c("show_title", "show_subtitle", "show_caption", "source_line", "show_axis_titles")])), "every text element is on by default")
sw <- sanitize_t2_figure(list(pub_show_title = FALSE, pub_show_subtitle = "FALSE", pub_show_caption = FALSE,
                              pub_source = FALSE, pub_show_axis_titles = FALSE))
ok(!any(unlist(sw[c("show_title", "show_subtitle", "show_caption", "source_line", "show_axis_titles")])), "each switch turns its element off")
ok(sanitize_t2_figure(list(pub_show_title = "junk", pub_show_axis_titles = NA))$show_title, "a junk switch value means on")
pf <- draw(list(x = "CD8A", y = "FOXP3", color = "sample_type"))
ok(!is.null(pf$labels$title) && !is.null(pf$labels$subtitle) && !is.null(pf$labels$caption) && identical(pf$labels$caption, T2_CITATION),
   "all on: title, subtitle and the source line are on the figure")
pt <- t2_apply_text_switches(pf, title = FALSE, subtitle = TRUE, axis_titles = TRUE)
ok(is.null(pt$labels$title) && !is.null(pt$labels$subtitle), "title off: no title, subtitle stays")
ps <- t2_apply_text_switches(pf, title = TRUE, subtitle = FALSE, axis_titles = FALSE)
ok(!is.null(ps$labels$title) && is.null(ps$labels$subtitle) && inherits(ps$theme$axis.title, "element_blank"),
   "subtitle off, axis titles off (blank axis.title)")
fa <- tmp("png"); t2_render_figure(ps, fa, 3.5, 3.2, 100, "png"); ok(file.exists(fa) && file.size(fa) > 1000, "a figure with switched-off elements renders")
pn <- draw(list(x = "CD8A", y = "FOXP3"), source = FALSE)
ok(is.null(pn$labels$caption), "source line off, nothing to put in the caption: no caption")
fcap <- "Filtered: Primary tumors only; cohorts BRCA, LUAD"
rr <- t2_figure_object(quiet(fun_plot1(utils::modifyList(list(cohort = "all", nonormal = FALSE, allComplete = TRUE, smooth = "TRUE", show_legend = TRUE),
                                         c(T2_FIG_PRESETS$half_third$style, list(x = "CD8A", y = "FOXP3"))),
                      reactive = FALSE, ctx = t2_plot_ctx(b), caption = "", filter_caption = fcap, fig_width = 3.5)))
ok(grepl("Filtered: Primary tumors only", gsub("\n", " ", rr$labels$caption), fixed = TRUE) && !grepl(T2_CITATION, rr$labels$caption, fixed = TRUE),
   "the Filtered line is the caption, without the source line when that is off")
rr2 <- t2_figure_object(quiet(fun_plot1(list(x = "CD8A", y = "FOXP3", cohort = "all", allComplete = TRUE), reactive = FALSE, ctx = t2_plot_ctx(b),
                       caption = T2_CITATION, filter_caption = fcap)))
ok(grepl("Filtered: Primary", rr2$labels$caption, fixed = TRUE) && grepl(T2_CITATION, rr2$labels$caption, fixed = TRUE),
   "Filtered line and source line together, one under the other")
kmc <- quiet(fun_plot1(list(x = "OS", y = "MKI67", cohort = "all", allComplete = TRUE), reactive = FALSE, ctx = t2_plot_ctx(b),
                       filter_caption = fcap, caption = ""))
ok(grepl("Filtered: Primary", kmc$plot$labels$caption, fixed = TRUE), "the Kaplan-Meier plot carries the Filtered line too")
kmt <- t2_apply_text_switches(kmc, title = FALSE, subtitle = FALSE, axis_titles = FALSE)
ok(inherits(kmt, "ggsurvplot") && is.null(kmt$plot$labels$title) && is.null(kmt$plot$labels$subtitle) &&
   inherits(kmt$plot$theme$axis.title, "element_blank") && inherits(kmt$table$theme$axis.title, "element_blank"),
   "switches also strip the Kaplan-Meier curve and its risk table")
fk <- tmp("png"); t2_render_figure(kmt, fk, 7, 4.75, 100, "png"); ok(file.size(fk) > 1000, "the stripped Kaplan-Meier figure renders")

cat("\n== the not-detected caption ==\n")
cx <- list(menu = data.frame(name = c("A.prot", "B.prot", "C.prot", "X.phospho"), type = c("prot", "prot", "prot", "phospho")),
           type_labels = c(prot = "protein", phospho = "phosphosite"))
ok(identical(t2_fill_caption(list(fill = "zero", filled = c(A.prot = 1357L), tested_n = c(A.prot = 1549L)), cx),
             "Not-detected protein values set to 0 (1,357 of 1,549 tested samples)"), "one probe: the sentence, the word from type_labels")
ok(identical(t2_fill_caption(list(fill = "floor", filled = c(A.prot = 10L), tested_n = c(A.prot = 20L)), cx),
             "Not-detected protein values set to the detection floor, per cohort (10 of 20 tested samples)"), "floor wording")
ok(identical(t2_fill_caption(list(fill = "zero", filled = c(A.prot = 1L, X.phospho = 2L), tested_n = c(A.prot = 5L, X.phospho = 6L)), cx),
             "Not-detected protein/phosphosite values set to 0: A.prot (1 of 5), X.phospho (2 of 6)"), "two probes: a clause each")
ok(identical(t2_fill_caption(list(fill = "zero", filled = c(A.prot = 1000L, B.prot = 2000L, C.prot = 3L), tested_n = c(A.prot = 5L, B.prot = 6L, C.prot = 7L)), cx),
             "3,003 not-detected values set to 0 (3 variables)"), "more than two: the total")
ok(identical(t2_fill_caption(list(fill = "zero", filled = integer(0), tested_n = integer(0)), cx), "") && identical(t2_fill_caption(NULL, cx), ""), "nothing filled: no caption")
pnd <- quiet(fun_plot1(list(x = "CD8A", y = "FOXP3", cohort = "all", allComplete = TRUE), reactive = FALSE, ctx = t2_plot_ctx(b), caption = T2_CITATION))
ok(!is.null(pnd$fill) && identical(pnd$fill$options, "na"), "TCGA: the plot result carries the answer's fill options (na only)")
bc <- load_dataset_bundle("cptac")
pz <- t2_figure_object(quiet(fun_plot1(list(x = "CLDN6", y = "CLDN6.prot", cohort = "all", allComplete = TRUE), reactive = FALSE,
                                       ctx = t2_plot_ctx(bc, fill = "zero"), caption = T2_CITATION, filter_caption = "Filtered: x", fig_width = 7)))
ok(grepl("Filtered: x", pz$labels$caption, fixed = TRUE) && grepl("Not-detected protein values set to 0", gsub("\n", " ", pz$labels$caption)) && grepl(T2_CITATION, pz$labels$caption, fixed = TRUE),
   "figure: Filtered line, not-detected line and source line")
pz2 <- t2_figure_object(quiet(fun_plot1(list(x = "CLDN6", y = "CLDN6.prot", cohort = "all", allComplete = TRUE), reactive = FALSE,
                                        ctx = t2_plot_ctx(bc, fill = "zero"), caption = "", fill_caption = FALSE)))
ok(is.null(pz2$labels$caption), "Publish with the Caption switch off: no not-detected line either")

ok(identical(t2_fill_caption(list(fill = "zero", filled = c(A.prot = 387L), tested_n = c(A.prot = 404L), basis = "shown"), cx),
             "Not-detected protein values set to 0 (387 of 404 samples shown)"), "plot counts: 'N of M samples shown'")
ok(identical(t2_fill_summary(list(fill = "zero", filled = c(A.prot = 387L), tested_n = c(A.prot = 404L), basis = "shown")),
             "A.prot: 387 not-detected values set to 0 among 404 samples shown"), "Data Summary line with plot counts")
fdf <- data.frame(sample = letters[1:5], A.prot = c(0, 0, 3, NA, 0))
attr(fdf, "fill_options") <- c("na", "zero"); attr(fdf, "fill") <- "zero"; attr(fdf, "filled") <- c(A.prot = 99L); attr(fdf, "tested_n") <- c(A.prot = 999L)
attr(fdf, "filled_rows") <- list(A.prot = c(TRUE, TRUE, FALSE, FALSE, FALSE))
fi <- t2_fill_of(fdf)
ok(identical(unname(fi$filled), 2L) && identical(unname(fi$tested_n), 4L) && fi$basis == "shown", "t2_fill_of: counts from the frame's own rows (2 set, 4 with a value), not the dataset's")
attr(fdf, "filled_rows") <- NULL
ok(t2_fill_of(fdf)$basis == "dataset" && unname(t2_fill_of(fdf)$filled) == 99L, "no frame attribute: the answer's dataset-wide counts are the fallback")

cat("\n== t2_filter_caption ==\n")
bb <- list(mycohorts = c(a = "BRCA", b = "LUAD", c = "COAD", d = "OV", e = "GBM"))
ok(identical(t2_filter_caption(list(group = NULL, exclusions = character(0)), bb, "all"), ""), "unfiltered: no caption")
ok(identical(t2_filter_caption(list(group = "Primary tumors only", exclusions = "Tumor samples only"), bb, "all"),
             "Filtered: Primary tumors only; Tumor samples only"), "presets by label")
ok(identical(t2_filter_caption(list(), bb, c("BRCA", "LUAD")), "Filtered: cohorts BRCA, LUAD"), "up to 3 cohorts: the names")
ok(identical(t2_filter_caption(list(), bb, c("BRCA", "LUAD", "COAD", "OV")), "Filtered: 4 of 5 cohorts"), "more cohorts: N of M")
ok(identical(t2_filter_caption(list(), bb, unname(bb$mycohorts)), ""), "every cohort chosen is no filter")
ok(identical(t2_filter_caption(list(), bb, "all", rules = c("CD8A >= 2", "tumtype: BRCA"), n_kept = 100, n_base = 1000),
             "Filtered: CD8A >= 2 and tumtype: BRCA"), "a few Filter-tab rules in words")
ok(identical(t2_filter_caption(list(), bb, "all", rules = paste("v", 1:5, ">= 1"), n_kept = 1234, n_base = 5000),
             "Filtered: 1,234 of 5,000 samples kept"), "many rules: N of M samples kept")
ok(identical(t2_filter_caption(list(), bb, "all", nonormal = TRUE, noheme = TRUE), "Filtered: no normals; no heme"), "nonormal / noheme")
ok(identical(t2_filter_caption(list(), list(part_label = "GTEx (Toil)"), "all"), "Filtered: GTEx (Toil)"), "a part of a collection is named")

cat("\n== presets ==\n")
ok(all(vapply(T2_FIG_PRESETS, function(pr) {
     w <- .t2_to_in(pr$width, pr$units); h <- .t2_to_in(pr$height, pr$units)
     w >= T2_FIG_MIN_IN && w <= T2_FIG_MAX_IN && h >= T2_FIG_MIN_IN && h <= T2_FIG_MAX_IN &&
       pr$dpi %in% T2_FIG_DPI && w * h * pr$dpi^2 <= T2_FIG_MAX_PIXELS &&
       all(names(pr$style) %in% names(T2_STYLE)) &&
       all(mapply(function(id, v) v %in% T2_STYLE[[id]]$choices, names(pr$style), pr$style)) &&
       length(t2_validate_tweaks(pr$gg)) == length(pr$gg)
   }, NA)), "every preset is within the limits, on the menus, and uses only registered settings")
ok(T2_FIG_PRESETS$nature1$width == 89 && T2_FIG_PRESETS$nature2$width == 183 &&
   T2_FIG_PRESETS$nature2$height <= 170, "Nature presets: 89 and 183 mm wide, no taller than 170 mm")
ok(!file.exists("Rplots.pdf"), "no stray Rplots.pdf")
finish("test_figure_export")
