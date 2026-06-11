## test_app_server.R — drive the real Shiny server logic headless via testServer.
## Verifies: default load = TCGA, plot builds; switching to DEMO rebinds the
## bundle and a plot builds against the synthetic dataset too.
suppressMessages(library(shiny))

ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")

## NB: unselected `multiple` selectize inputs arrive as NULL in real Shiny
## (and fun_plot1 strips NULLs), so facet/condition are intentionally absent.
base_inputs <- list(
  size = "", cohort = "all",
  pcortype = "none", nonormal = FALSE, noheme = FALSE, multi_y = FALSE,
  zscore_y = FALSE, coordflip = FALSE, waterfall = FALSE, waterfall_flip = FALSE,
  allComplete = TRUE, smooth = "TRUE", scales = "fixed", alpha = 0.12,
  static.size = 0.5, static.strip = 0.5, static.labels = 0.6,
  static.titles = 0.6, ncols = 8, plot_btn = 0, plot_btn2 = 0
)

testServer(shiny::shinyAppDir("."), {
  ## ---- default: TCGA ----
  do.call(session$setInputs, c(base_inputs,
          list(dataset = "TCGA", x = "cohort", y = "CD8A", color = "sample_type")))
  ok(bundle()$name == "TCGA", "default bundle is TCGA")
  session$setInputs(plot_btn = 1)
  r1 <- plot_result()
  ok(is.list(r1) && !is.null(r1$plot), "TCGA plot builds")
  cat("    TCGA summary line 1:", strsplit(r1$summary, "\n")[[1]][1], "\n")

  ## ---- switch to DEMO ----
  session$setInputs(dataset = "DEMO")
  ok(bundle()$name == "DEMO", "bundle switched to DEMO")
  ok(!"sample_type" %in% bundle()$mygenesplus, "DEMO choice list has no sample_type")
  session$setInputs(x = "cohort", y = "GENE01", color = "subtype", plot_btn = 2)
  r2 <- plot_result()
  ok(is.list(r2) && !is.null(r2$plot), "DEMO plot builds")
  cat("    DEMO summary line 1:", strsplit(r2$summary, "\n")[[1]][1], "\n")

  ## ---- switch back to TCGA ----
  session$setInputs(dataset = "TCGA")
  ok(bundle()$name == "TCGA", "bundle switched back to TCGA")
})
cat("== app server test done ==\n")
