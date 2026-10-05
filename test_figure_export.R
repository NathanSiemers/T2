## test_figure_export.R — publication figures (figure_export.R): the files have
## exactly the size asked for, the preview shows what the download contains,
## the limits hold, and the bundled fonts are really used.
##   Rscript test_figure_export.R        (from the app directory)
suppressMessages({
  source("global.R"); source("database_connection_shiny.R")
  source("lib.R"); source("input_validation.R")
})
grDevices::pdf(NULL)
ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")
quiet <- function(expr) { utils::capture.output(v <- suppressWarnings(suppressMessages(expr))); v }
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
  r <- quiet(fun_plot1(inp, reactive = FALSE, dbfile = b$path, roles = b$roles, dataset_label = b$label,
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
cat("== figure export test done ==\n")
