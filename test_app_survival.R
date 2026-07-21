## test_app_survival.R — verify the Kaplan-Meier survival view through the REAL
## Shiny app server (testServer), the same path the app takes when a user picks
## a time-to-event endpoint for X. Also confirms scatter plots are unaffected.
suppressMessages(library(shiny))

ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")

base_inputs <- list(
  size = "", cohort = "all", pcortype = "none", nonormal = FALSE, noheme = FALSE,
  multi_y = FALSE, zscore_y = FALSE, coordflip = FALSE, waterfall = FALSE,
  waterfall_flip = FALSE, allComplete = TRUE, smooth = "TRUE", scales = "fixed",
  alpha = 0.12, static.size = 0.5, static.strip = 0.5, static.labels = 0.6,
  static.titles = 0.6, ncols = 8, plot_btn = 0, plot_btn2 = 0
)

testServer(shiny::shinyAppDir("."), {
  ## ---- single-panel survival: X = OS endpoint, Y = MKI67 marker ----
  do.call(session$setInputs, c(base_inputs,
          list(dataset = "TCGA", x = "OS", y = "MKI67", color = "")))
  session$setInputs(plot_btn = 1)
  r <- plot_result()
  ok(inherits(r, "ggsurvplot"), "OS ~ MKI67 -> Kaplan-Meier (ggsurvplot)")
  ok(!is.null(attr(r, "t2summary")), "survival stats attached (summary panel)")
  cat("    ", attr(r, "t2summary"), "\n")
  rendered <- tryCatch({ invisible(output$main_plot); TRUE }, error = function(e) { cat("    render err:", conditionMessage(e), "\n"); FALSE })
  ok(rendered, "main_plot renders the KM object without error")

  ## ---- faceted survival via the 'Graph for each:' control ----
  session$setInputs(cohort = c("BRCA", "LUAD", "KIRC"), facet = "tumtype", plot_btn = 2)
  r2 <- plot_result()
  ok(inherits(r2, "ggplot") && !inherits(r2, "ggsurvplot"), "faceted endpoint -> KM grid (ggplot)")

  ## ---- missing Y marker -> empty (app guards it), no crash ----
  session$setInputs(y = "", cohort = "all", facet = "", plot_btn = 3)
  r3 <- plot_result()
  ok(is.null(r3), "no Y marker -> empty plot (guarded), not a crash")

  ## ---- scatter still works when X is a normal gene ----
  session$setInputs(x = "CD8A", y = "MKI67", plot_btn = 4)
  r4 <- plot_result()
  ok(is.list(r4) && !is.null(r4$plot), "normal scatter still builds")
})
cat("== survival app-server test done ==\n")
