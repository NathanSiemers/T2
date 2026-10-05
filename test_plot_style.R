## test_plot_style.R — the Appearance settings and the ggplot tweak registry
## (plot_style.R): every registered setting must apply to a real plot without
## error, and nothing but validated values may get through.
##   Rscript test_plot_style.R        (from the app directory)
suppressMessages({
  source("global.R"); source("database_connection_shiny.R")
  source("lib.R"); source("input_validation.R")
})
grDevices::pdf(NULL)     # building grobs needs a device; never write Rplots.pdf
ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")
quiet <- function(expr) { utils::capture.output(v <- suppressWarnings(suppressMessages(expr))); v }
builds <- function(p) {            # the plot can actually be drawn
  tryCatch({ quiet(ggplot2::ggplotGrob(p)); TRUE }, error = function(e) conditionMessage(e))
}

cat("== registry ==\n")
ok(length(T2_TWEAKS) > 300, sprintf("%d settings registered", length(T2_TWEAKS)))
ok(all(vapply(T2_TWEAKS, function(t) all(nzchar(c(t$id, t$group, t$label, t$gg, t$kind))), NA)),
   "every setting has an id, group, label, ggplot name and kind")
ok(identical(unname(vapply(T2_TWEAKS, `[[`, "", "id")), names(T2_TWEAKS)), "ids are the registry keys")
ok(setequal(unlist(lapply(t2_tweak_choices(), unname)), names(T2_TWEAKS)),
   "the search box offers every setting exactly once")
## a default that the validator itself would refuse could never be re-selected
has_def <- Filter(function(t) !is.null(t$default) && t$kind != "text", T2_TWEAKS)
def_ok <- vapply(has_def, function(t) !is.null(t2_validate_tweak(t, t$default)), NA)
if (!all(def_ok)) print(names(def_ok)[!def_ok])
ok(all(def_ok), sprintf("all %d displayed defaults are themselves valid values", length(has_def)))
ok(all(vapply(T2_TWEAKS, function(t) length(t2_tweak_menu(t)) >= 2 || t$kind == "text", NA)),
   "every non-text setting has a menu")
ok(T2_TWEAKS[["theme|axis.text.x|angle"]]$default == 90 &&
   T2_TWEAKS[["theme|plot.title|size"]]$default == t2_style_default("title_size"),
   "defaults come from T2's own theme (x labels at 90 degrees, title size)")

## a value to try for each setting: something other than its default
try_value <- function(t) {
  if (t$kind == "text") return("Custom <b>label</b> $x^2$")
  m <- t2_tweak_menu(t)
  m <- setdiff(m, c(as.character(t$default), "blank", "transparent"))
  m[ceiling(length(m) / 2)]
}

cat("\n== every theme setting applies to a plot ==\n")
set.seed(1)
df <- data.frame(x = rnorm(60), y = rnorm(60), g = rep(c("a", "b", "c"), 20),
                 f = rep(c("p", "q"), each = 30))
p0 <- ggplot(df, aes(x, y, colour = g)) + geom_point() + facet_wrap(vars(f)) +
  labs(title = "T", subtitle = "S", caption = "C") + t2_base_theme()
ok(isTRUE(builds(p0)), "reference plot builds")
theme_ids <- grep("^theme\\|", names(T2_TWEAKS), value = TRUE)
res <- vapply(theme_ids, function(id) {
  gg <- t2_validate_tweaks(stats::setNames(list(try_value(T2_TWEAKS[[id]])), id))
  if (length(gg) != 1) return("did not validate")
  b <- builds(p0 + t2_tweak_theme(gg))
  if (isTRUE(b)) "" else b
}, "")
if (any(nzchar(res))) print(res[nzchar(res)])
ok(!any(nzchar(res)), sprintf("all %d theme settings apply one at a time", length(theme_ids)))
all_gg <- t2_validate_tweaks(lapply(T2_TWEAKS[theme_ids], try_value))
ok(length(all_gg) == length(theme_ids) && isTRUE(builds(p0 + t2_tweak_theme(all_gg))),
   "all theme settings apply together")
## the theme really changes
th <- t2_base_theme() + t2_tweak_theme(list(`theme|axis.text.x|angle` = 45, `theme|legend.position` = "bottom",
                                            `theme|panel.grid.major|linewidth` = 0, `theme|plot.title|size` = 0,
                                            `theme|plot.margin|left` = 40, `theme|legend.key.size` = 30))
ok(calc_element("axis.text.x", th)$angle == 45 && identical(th$legend.position, "bottom") &&
   inherits(th$panel.grid.major, "element_blank") && inherits(th$plot.title, "element_blank") &&
   as.numeric(th$plot.margin)[4] == 40 && as.numeric(th$plot.margin)[1] == T2_TWEAKS[["theme|plot.margin|top"]]$default &&
   as.numeric(grid::convertUnit(th$legend.key.size, "pt")) == 30,
   "values land in the theme (angle, position, 0 = removed, one margin side, unit)")

cat("\n== layer / scale / label settings apply through plotter() ==\n")
b <- load_dataset_bundle("DEMO")
genes <- head(b$mygenes, 2)
run <- function(x, gg = list(), ...) {
  quiet(plotter(x = x, y = genes[2], color = "subtype", cohort = "all", nonormal = FALSE,
                smooth = "TRUE", dbfile = b$path, roles = b$roles, gg = gg, ...))
}
layer_ids <- setdiff(names(T2_TWEAKS), theme_ids)
for (xv in list(scatter = genes[1], boxplot = "cohort")) {
  res <- vapply(layer_ids, function(id) {
    gg <- t2_validate_tweaks(stats::setNames(list(try_value(T2_TWEAKS[[id]])), id))
    if (length(gg) != 1) return("did not validate")
    r <- tryCatch(run(xv, gg), error = function(e) list(err = conditionMessage(e)))
    if (!is.null(r$err)) return(r$err)
    bb <- builds(r$plot); if (isTRUE(bb)) "" else bb
  }, "")
  if (any(nzchar(res))) print(res[nzchar(res)])
  ok(!any(nzchar(res)), sprintf("all %d layer/scale/label settings apply (%s plot)", length(layer_ids), xv))
}
r <- run(genes[1], list(point.shape = "17", point.stroke = 2, smooth.method = "loess", smooth.se = "FALSE",
                        median.show = "FALSE", labs.title = "My title", labs.caption = "My caption",
                        colour.palette = "viridis", scale.y.trans = "sqrt"))
geoms <- vapply(r$plot$layers, function(l) class(l$geom)[1], "")
pt <- r$plot$layers[[which(geoms == "GeomPoint")]]
ok(pt$aes_params$shape == 17 && pt$aes_params$stroke == 2 && !("GeomQuantile" %in% geoms) &&
   identical(r$plot$labels$title, "My title") && identical(r$plot$labels$caption, "My caption"),
   "layer settings reach the layers (shape, stroke, no median line, title, caption)")

cat("\n== the fixed Appearance settings are real ggplot values ==\n")
r <- run(genes[1], point_size = 4, alpha = 0.5, title_size = 20, subtitle_size = 9, axis_title_size = 13,
         axis_text_size = 7, strip_size = 6, legend_size = 5)
pt <- r$plot$layers[[1]]
th <- r$plot$theme
ok(pt$aes_params$size == 4 && pt$aes_params$alpha == 0.5, "point size and alpha are passed to geom_point as given")
ok(calc_element("plot.title", th)$size == 20 && calc_element("plot.subtitle", th)$size == 9 &&
   calc_element("axis.title.x", th)$size == 13 && calc_element("axis.text.y", th)$size == 7 &&
   calc_element("strip.text", th)$size == 6 && calc_element("legend.text", th)$size == 5 &&
   calc_element("legend.title", th)$size == 5,
   "font sizes are the point sizes chosen, with no hidden scaling")
r0 <- run("cohort", point_size = 0, title_size = 0, subtitle_size = 0, axis_title_size = 0,
          axis_text_size = 0, strip_size = 0, legend_size = 0, show_legend = FALSE, facet = "subtype")
g0 <- vapply(r0$plot$layers, function(l) class(l$geom)[1], "")
ok(isTRUE(builds(r0$plot)) && !("GeomPoint" %in% g0) && "GeomBoxplot" %in% g0 &&
   inherits(calc_element("plot.title", r0$plot$theme), "element_blank") &&
   inherits(calc_element("axis.text.x", r0$plot$theme), "element_blank") &&
   identical(r0$plot$theme$legend.position, "none"),
   "0 switches things off: no points, no titles, no axis text; legend hidden")
s <- sanitize_t2_input(list(point_size = "3.1", title_size = "999", alpha = "abc", plot_height = "650",
                            show_legend = "FALSE"), b)
ok(s$point_size == 3 && s$title_size == 40 && s$alpha == t2_style_default("alpha") &&
   s$plot_height %in% c(600, 700) && identical(s$show_legend, FALSE),
   "Appearance inputs snap to their menus; junk falls back to the default")
ok(all(names(T2_STYLE) %in% names(s)) && !("plot_height" %in% T2_INPUT_ARGS),
   "every Appearance menu is sanitized; plot_height is not a plotter argument")

cat("\n== nothing unvalidated gets through ==\n")
evil <- c("1; system('id')", "system('id')", "`rm -rf /`", "1e999", "NaN", "Inf", "-Inf", "",
          "<script>alert(1)</script>", "function() 1", "red; DROP TABLE x", "#12345", "#GGGGGG",
          "c(1,2)", "1 2", "TRUE; q()", "..", "NULL", "NA")
num <- T2_TWEAKS[["theme|axis.text.x|angle"]]; enm <- T2_TWEAKS[["theme|legend.position"]]
col <- T2_TWEAKS[["theme|panel.background|fill"]]; txt <- T2_TWEAKS[["labs.title"]]
ok(all(vapply(evil, function(v) is.null(t2_validate_tweak(num, v)), NA)), "numeric settings accept numbers only")
ok(all(vapply(evil, function(v) is.null(t2_validate_tweak(enm, v)), NA)), "list settings accept listed values only")
ok(all(vapply(evil, function(v) is.null(t2_validate_tweak(col, v)), NA)), "colour settings accept colour names / #hex only")
ok(is.null(t2_validate_tweak(num, 100000)) && is.null(t2_validate_tweak(num, -1000)) &&
   t2_validate_tweak(num, "33.5") == 33.5 && t2_validate_tweak(num, " 45 ") == 45,
   "typed numbers are accepted inside the setting's range only")
ok(identical(t2_validate_tweak(col, "#1A2b3C"), "#1A2b3C") && identical(t2_validate_tweak(col, "steelblue"), "steelblue") &&
   identical(t2_validate_tweak(col, "#1A2B3C80"), "#1A2B3C80"), "colour names and #hex (with alpha) pass")
long <- paste(rep("x", 500), collapse = "")
tv <- t2_validate_tweak(txt, paste0("line1\nline2\t", long))
ok(nchar(tv) == 200 && !grepl("[[:cntrl:]]", tv), "free text is length-capped and stripped of control characters")
r <- run(genes[1], list(labs.title = "system('id'); `x` <b>$(rm)</b>"))
ok(identical(r$plot$labels$title, "system('id'); `x` <b>$(rm)</b>") && isTRUE(builds(r$plot)),
   "free text is drawn literally, never evaluated")
ok(length(t2_validate_tweaks(list(`theme|no.such.element|size` = 5, `theme(axis.text=element_blank())` = 1,
                                  `point.shape` = "99", `theme|plot.title|size` = "12; q()"))) == 0,
   "unknown setting ids and bad values are dropped")
## fun_plot1 re-validates whatever it is handed
r <- quiet(fun_plot1(list(x = genes[1], y = genes[2]), reactive = FALSE, dbfile = b$path, roles = b$roles,
                     gg = list(`theme|plot.title|size` = "30", `theme|evil` = "x", point.shape = "system('id')",
                               labs.x = "Custom X")))
ok(calc_element("plot.title", r$plot$theme)$size == 30 && identical(r$plot$labels$x, "Custom X") &&
   r$plot$layers[[1]]$aes_params$shape == 19,
   "fun_plot1 applies valid tweaks and silently drops invalid ones")
inp <- list(tweak_pick = c("theme|legend.position", "point.shape", "theme|not.real", "labs.y"),
            tw_theme_legend_position = "bottom", tw_point_shape = "4", tw_labs_y = "",
            tw_theme_not_real = "x", tw_theme_plot_title_size = "40")
sg <- sanitize_t2_tweaks(inp)
ok(identical(sg, list(`theme|legend.position` = "bottom", point.shape = "4")),
   "only picked, registered settings with a usable value are read from the browser")

cat("\n== survival plots take fonts, legend and theme settings ==\n")
bt <- load_dataset_bundle("TCGA")
km <- quiet(fun_plot1(list(x = "OS", y = "MKI67", cohort = "LUAD", title_size = 22, show_legend = FALSE),
                      reactive = FALSE, dbfile = bt$path, roles = bt$roles,
                      gg = list(`theme|axis.text.x|angle` = 45, labs.title = "KM title")))
ok(inherits(km, "ggsurvplot") && calc_element("plot.title", km$plot$theme)$size == 22 &&
   identical(km$plot$theme$legend.position, "none") && calc_element("axis.text.x", km$plot$theme)$angle == 45 &&
   identical(km$plot$labels$title, "KM title") && !is.null(attr(km, "km_data")),
   "Kaplan-Meier plot: title size, hidden legend, a theme tweak and a custom title")
kf <- quiet(fun_plot1(list(x = "OS", y = "MKI67", cohort = c("LUAD", "LUSC"), facet = "cohort", strip_size = 18),
                      reactive = FALSE, dbfile = bt$path, roles = bt$roles))
ok(inherits(kf, "ggplot") && calc_element("strip.text", kf$theme)$size == 18 && !is.null(attr(kf, "km_data")) &&
   !is.null(attr(kf, "t2summary")),
   "faceted Kaplan-Meier plot keeps its summary and takes the strip size")

cat("== plot style test done ==\n")
