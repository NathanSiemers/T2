## test_app_interactions.R
## PERMANENT UI-interaction matrix - run via ops/test.sh app on every UI round. Crosses the Select-tab plot options and asserts every combination draws or refuses with a plain warning, never an uncaught error.
## Section A: a 64-cell factorial core (multi_y x y-form x color x waterfall x coordflip) with a generic oracle,
##            three more axes (facet, zscore_y, condition) cycled Latin-square-style across the cells.
## Section B: targeted pins with specific assertions (UI-REWORK: quanta colors, probe_quanta, waterfall, coordflip ...).
##   Rscript test_app_interactions.R        (from the app directory, against the dev service)
suppressMessages(library(shiny))
source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero
`%||%` <- function(a, b) if (is.null(a)) b else a

testServer(shiny::shinyAppDir("."), {
  session$setInputs(dataset = "TCGA", tabs = "select", cohort = "all", preset_group = "", preset_excl = character(0),
                    surv_max_days = 1825)       # settle the default bundle first (as test_app_analysis.R does), then switch
  session$setInputs(dataset = "DEMO")
  b <- bundle(); h <- th_for(b)
  ok(b$name == "DEMO" && length(h$backend$samples) == 60, "DEMO active, 60 samples")
  CAT <- "cohort"; CAT2 <- "growth_media"      # DEMO categoricals (5 and 2 levels)

  pn <- 0
  plot_with <- function(...) { pn <<- pn + 1; do.call(session$setInputs, c(list(...), list(plot_btn = pn))); plot_result() }
  try_plot <- function(desc, ...) {
    res <- tryCatch(plot_with(...), error = function(e) e)
    ok(!inherits(res, "error"), paste(desc, "- no uncaught R error", if (inherits(res, "error")) conditionMessage(res) else ""))
    draws <- is.list(res) && (inherits(res$plot, "ggplot") || inherits(res, "ggsurvplot") || inherits(res$plot, "ggsurvplot") ||
               (is.character(res$warning) && nzchar(res$warning)))
    ok(draws, paste(desc, "- draws, or refuses with a plain warning"))
    res
  }
  reset_inputs <- function() session$setInputs(x = CAT, y = "GENE01", color = "", size = "",
      facet = character(0), condition = character(0), pcortype = "none", multi_y = FALSE, zscore_y = FALSE,
      coordflip = FALSE, waterfall = FALSE, waterfall_flip = FALSE, cohort = "all")
  reset_inputs()
  has_flip <- function(r) inherits(r$plot$coordinates, "CoordFlip")
  tok <- function(g, k = 3) t2_quant_token(g, k)

  ## ================= Section A: factorial core =================
  cells <- expand.grid(multi_y = c(FALSE, TRUE), yform = c("plain", "token"), color = c("none", "cat", "token", "default"),
                       waterfall = c(FALSE, TRUE), flip = c(FALSE, TRUE), stringsAsFactors = FALSE)
  for (i in seq_len(nrow(cells))) {
    cl <- cells[i, ]; n <- i - 1
    f <- (n %% 2 + n %/% 16) %% 2 == 1
    z <- ((n %/% 2) + (n %/% 8)) %% 2 == 1
    cd <- ((n %/% 4) + (n %/% 32)) %% 2 == 1
    ytok <- cl$yform == "token"
    y <- if (cl$multi_y) c(if (ytok) tok("GENE01") else "GENE01", "GENE02") else if (ytok) tok("GENE01") else "GENE01"
    color <- switch(cl$color, none = "", cat = CAT2, token = tok("GENE03"),
                    default = if (ytok && cl$multi_y) "probe_quanta" else if (cl$multi_y) "probe" else if (ytok) "quanta" else "")
    reset_inputs()
    label <- sprintf("A%02d multi_y=%s y=%s color=%s waterfall=%s flip=%s facet=%s zscore=%s cond=%s", i, cl$multi_y, cl$yform,
                     color, cl$waterfall, cl$flip, f, z, cd)
    try_plot(label, x = if (cl$waterfall) CAT else "GENE04", y = y, color = color,
             facet = if (f) CAT else character(0), zscore_y = z,
             condition = if (cd) "GENE05" else character(0), pcortype = if (cd) "y" else "none",
             waterfall = cl$waterfall, coordflip = cl$flip, multi_y = cl$multi_y)
  }

  ## ================= Section B: targeted pins =================
  reset_inputs()
  ty2 <- tok("GENE02"); lab2 <- t2_quant_label("GENE02", 3)

  ## 1. quanta default
  r1 <- try_plot("B1 quanta", x = "GENE04", y = ty2, color = "quanta")
  ok(inherits(r1$plot, "ggplot") && lab2 %in% names(r1$plot$data) && lab2 == "GENE02 (tertiles)", "B1 quanta: derived column 'GENE02 (tertiles)' is in the plot data")
  ok(is.factor(r1$plot$data[[lab2]]) && nlevels(r1$plot$data[[lab2]]) == 3, "B1 quanta: three levels")
  ok(grepl("the groups color the plot", r1$warning %||% "", fixed = TRUE), "B1 quanta: warning says 'the groups color the plot'")
  ok(is.numeric(r1$plot$data[["GENE02"]]), "B1 quanta: the y column is continuous")
  n_q <- table(r1$plot$data[[lab2]])

  ## 2. override with a real categorical color
  r2 <- try_plot("B2 override", x = "GENE04", y = ty2, color = CAT)
  ok(inherits(r2$plot, "ggplot") && grepl("groups have no meaning as y", r2$warning %||% "", fixed = TRUE),
     "B2 override: color = categorical gives the 'groups have no meaning as y' notice")

  ## 3. probe_quanta
  r3 <- try_plot("B3 probe_quanta", x = "GENE04", y = c(tok("GENE01"), "GENE02"), color = "probe_quanta", multi_y = TRUE)
  d3 <- r3$plot$data; lv3 <- levels(d3$probe_quanta)
  ok(inherits(r3$plot, "ggplot") && "probe_quanta" %in% names(d3) && "probe" %in% names(d3), "B3 probe_quanta: both columns present")
  ok(length(lv3) >= 1 && length(lv3) <= 6 && all(grepl("^GENE0[12] / ", lv3)) && any(startsWith(lv3, "GENE01 / ")),
     paste("B3 probe_quanta: levels look like 'GENE01 / <group>' (", paste(lv3, collapse = "; "), ")"))
  ok(inherits(r3$plot$facet, "FacetNull"), "B3 probe_quanta: no automatic facet")

  ## 4. probe_quanta refusal degrades to probe coloring
  r4 <- tryCatch(plotter(x = "GENE04", y = c(tok("GENE01"), "GENE02"), color = "probe_quanta", multi_y = TRUE,
                         ctx = t2_plot_ctx(b, keep = h$backend$samples[1:8])), error = function(e) e)
  ok(!inherits(r4, "error") && inherits(r4$plot, "ggplot") && grepl("probe x group coloring dropped", r4$warning %||% "", fixed = TRUE) &&
       "probe" %in% names(r4$plot$data) && !("probe_quanta" %in% names(r4$plot$data)),
     "B4 probe_quanta on 8 samples: draws colored by probe, warning 'probe x group coloring dropped'")

  ## 5. the fixed accident
  r5 <- try_plot("B5 multi_y one Y + probe", x = "GENE04", y = "GENE01", color = "probe", multi_y = TRUE)
  ok(inherits(r5$plot, "ggplot") && !("probe" %in% names(r5$plot$data)), "B5 multi_y with ONE Y and color = probe: draws, color dropped")

  ## 6. multi_y_fill
  r6 <- try_plot("B6 multi_y_fill", x = CAT, y = c("GENE01", "GENE02"), color = CAT2, multi_y = TRUE)
  fv <- names(r6$plot$facet$params$facets %||% r6$plot$facet$params$rows)
  ok(inherits(r6$plot, "ggplot") && "probe" %in% fv, paste("B6 multi_y + categorical color: the facet gains probe (", paste(fv, collapse = ","), ")"))
  ok(!is.null(r6$fill), "B6 multi_y + categorical color: fill info present")

  ## 7. waterfall valid
  reset_inputs()
  r7 <- try_plot("B7 waterfall", x = CAT, y = "GENE01", waterfall = TRUE)
  d7 <- r7$plot$data
  exp7 <- names(sort(tapply(d7$GENE01, as.character(d7[[CAT]]), median, na.rm = TRUE)))
  ok(inherits(r7$plot, "ggplot") && identical(levels(d7[[CAT]]), exp7), "B7 waterfall: x levels ordered by median y")
  r7f <- try_plot("B7 waterfall flip", x = CAT, y = "GENE01", waterfall = TRUE, waterfall_flip = TRUE)
  ok(inherits(r7f$plot, "ggplot") && identical(levels(r7f$plot$data[[CAT]]), rev(exp7)), "B7 waterfall_flip: the order is reversed")
  session$setInputs(waterfall_flip = FALSE)

  ## 8. waterfall invalid
  r8 <- try_plot("B8 waterfall numeric x", x = "GENE04", y = "GENE01", waterfall = TRUE)
  ok(grepl("Waterfall needs a categorical X", r8$warning %||% "", fixed = TRUE), "B8 waterfall with a numeric X: plain warning")

  ## 9. waterfall x quanta
  r9 <- try_plot("B9 waterfall x quanta", x = CAT, y = ty2, color = "quanta", waterfall = TRUE)
  ok(inherits(r9$plot, "ggplot") && lab2 %in% names(r9$plot$data), "B9 waterfall x quanta: draws with the derived color column")
  session$setInputs(waterfall = FALSE)

  ## 10. coordflip
  rf_a <- plot_with(x = "GENE04", y = "GENE01", color = "", coordflip = TRUE)
  rf_b <- plot_with(x = CAT, y = "GENE01", coordflip = TRUE)
  rf_c <- plot_with(x = CAT, y = "GENE01", waterfall = TRUE, coordflip = TRUE)
  rf_d <- plot_with(x = "GENE04", y = ty2, color = "quanta", waterfall = FALSE, coordflip = TRUE)
  ok(has_flip(rf_a), "B10 coordflip on a scatter")
  ok(has_flip(rf_b), "B10 coordflip on a box (categorical x)")
  ok(has_flip(rf_c), "B10 coordflip on a waterfall")
  ok(has_flip(rf_d), "B10 coordflip on the quanta plot")
  session$setInputs(coordflip = FALSE, waterfall = FALSE)
  ok(!has_flip(plot_with(x = "GENE04", y = "GENE01", color = "")), "B10 without coordflip: no flip")

  ## 11. condition x quanta: groups cut from RAW values
  r11 <- try_plot("B11 condition x quanta", x = "GENE04", y = ty2, color = "quanta", condition = "GENE05", pcortype = "y")
  ok(inherits(r11$plot, "ggplot") && lab2 %in% names(r11$plot$data) && nlevels(r11$plot$data[[lab2]]) == nlevels(r1$plot$data[[lab2]]) &&
       identical(as.vector(table(r11$plot$data[[lab2]])), as.vector(n_q)),
     "B11 condition x quanta: same groups and group sizes as without the condition (raw-value cut)")
  session$setInputs(condition = character(0), pcortype = "none")

  ## 12. zscore_y x quanta
  r12 <- try_plot("B12 zscore x quanta", x = "GENE04", y = ty2, color = "quanta", zscore_y = TRUE)
  ok(inherits(r12$plot, "ggplot") && identical(as.vector(table(r12$plot$data[[lab2]])), as.vector(n_q)),
     "B12 zscore_y x quanta: groups unchanged (raw-value cut)")
  session$setInputs(zscore_y = FALSE)

  ## 13. sanitizer
  ok(identical(sanitize_t2_input(list(color = "quanta", y = ty2), b)$color, "quanta") &&
       identical(sanitize_t2_input(list(color = "probe_quanta", y = ty2), b)$color, "probe_quanta"),
     "B13 the sanitizer accepts color = quanta / probe_quanta")
  r13 <- try_plot("B13 quanta on plain y", x = "GENE04", y = "GENE01", color = "quanta")
  ok(inherits(r13$plot, "ggplot") && grepl("nothing to color by", r13$warning %||% "", fixed = TRUE), "B13 color = quanta with a plain Y: 'nothing to color by'")

  ## 14. auto-replot (debounced data_bump); a first Plot press has happened
  ## (the debounced data_state skips its FIRST emission after a dataset switch, so let that one pass before testing)
  reset_inputs()
  for (k in 1:2) { session$elapse(1200); session$flushReact() }
  r14a <- plot_with(x = "GENE04", y = "GENE01")
  for (k in 1:2) { session$elapse(1200); session$flushReact() }
  d0 <- data_bump()
  session$setInputs(y = "GENE06")
  for (k in 1:3) { session$elapse(1200); session$flushReact() }
  r14b <- tryCatch(plot_result(), error = function(e) NULL)
  ok(!is.null(r14b) && "GENE06" %in% names(r14b$plot$data) && !("GENE01" %in% names(r14b$plot$data)),
     "B14 auto-replot: changing y alone (no button) re-executes plot_result after the debounce")
  ok(data_bump() == d0 + 1, "B14 data_bump advanced exactly once")
  ok(!is.null(r14a$plot$data), "B14 the first plot existed before the change")

  ## 15. table download with color = quanta
  tb <- tryCatch(fun_table1(sanitize_t2_input(list(x = "GENE04", y = ty2, color = "quanta", cohort = "all"), b), ctx = t2_plot_ctx(b)),
                 error = function(e) e)
  ok(is.data.frame(tb) && "GENE02" %in% names(tb) && !any(c("quanta", "probe", "probe_quanta") %in% names(tb)) && !any(grepl("t2q::", names(tb))),
     "B15 fun_table1 with color = quanta: source columns only, no specials")

  ## 16. KM guard
  tt <- tte_names(b)
  if (length(tt)) {
    reset_inputs()
    for (col in c("quanta", "probe", "")) {
      r16 <- try_plot(paste0("B16 KM color='", col, "'"), x = tt[1], y = "GENE01", color = col)
    }
    r16m <- try_plot("B16 KM color=quanta, y token", x = tt[1], y = ty2, color = "quanta")
  } else cat("  (B16 skipped: DEMO has no time-to-event endpoints)\n")
})
finish("test_app_interactions")
