## test_app_server.R — drive the real Shiny server logic headless via testServer.
## Verifies: default load = TCGA, plot builds; switching to DEMO rebinds the
## bundle and a plot builds against the synthetic dataset too.
suppressMessages(library(shiny))

source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero, quiet()

## NB: unselected `multiple` selectize inputs arrive as NULL in real Shiny
## (and fun_plot1 strips NULLs), so facet/condition are intentionally absent.
base_inputs <- list(
  size = "", cohort = "all",
  pcortype = "none", nonormal = FALSE, noheme = FALSE, multi_y = FALSE,
  zscore_y = FALSE, coordflip = FALSE, waterfall = FALSE, waterfall_flip = FALSE,
  allComplete = TRUE, smooth = "TRUE", scales = "fixed",
  
  ncols = 8, plot_btn = 0, plot_btn2 = 0
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

  ## ---- not-detected values: the control follows the values answer ----
  session$flushReact()
  ok(identical(fill_state()$options, "na") && is.null(output$fill_ui$html), "TCGA: the answer offers na only; no not-detected control")
  session$setInputs(dataset = "cptac")
  session$setInputs(x = "CLDN6", y = "CLDN6.prot", color = "", cohort = "all", plot_btn = 2)
  r3 <- plot_result(); session$flushReact()
  ok(identical(fill_state()$options, c("na", "zero", "floor")), "cptac CLDN6 vs CLDN6.prot: the answer offers na, zero, floor")
  ui <- as.character(output$fill_ui$html)
  ok(grepl("not_detected", ui) && grepl("Missing", ui) && grepl("Zero", ui) && grepl("Detection floor", ui), "the control lists the offered options: Missing, Zero, Detection floor")
  ok(is.null(r3$plot$labels$caption) || !grepl("Not-detected", r3$plot$labels$caption), "no fill chosen: no not-detected caption")
  n_na <- as.integer(sub(".*Samples with data for both X and Y: (\\d+).*", "\\1", r3$summary))
  session$setInputs(not_detected = "zero")
  rz <- plot_result()
  cap <- rz$plot$labels$caption
  ok(grepl("Not-detected protein values set to 0 \\([0-9,]+ of [0-9,]+ tested samples\\)", cap), paste("Zero: the caption says so:", gsub("\n", " / ", cap)))
  n_z <- as.integer(sub(".*Samples with data for both X and Y: (\\d+).*", "\\1", rz$summary))
  ok(n_z > n_na && grepl("CLDN6.prot: [0-9,]+ not-detected values set to 0", rz$summary), sprintf("Zero: more samples have data (%d, was %d) and the Data Summary has a line", n_z, n_na))
  session$setInputs(not_detected = "floor")
  rf <- plot_result()
  ok(grepl("set to the detection floor, per cohort", rf$plot$labels$caption), "Floor: the caption says 'the detection floor, per cohort'")
  session$setInputs(not_detected = "na")
  ok(!grepl("Not-detected", plot_result()$plot$labels$caption %||% ""), "Missing again: no caption line")
  ## the choice belongs to the data source: a switch resets it and hides the control
  session$setInputs(not_detected = "zero"); invisible(plot_result()); session$flushReact()
  session$setInputs(dataset = "TCGA")
  ok(identical(fill_choice(), "na") && is.null(fill_state()), "switching the data source resets the choice to Missing and hides the control")
  session$setInputs(x = "cohort", y = "CD8A", color = "sample_type", plot_btn = 3)
  invisible(plot_result()); session$flushReact()
  ok(identical(fill_state()$options, "na") && is.null(output$fill_ui$html), "TCGA again: still no control")

  ## ---- switch to DEMO ----
  session$setInputs(dataset = "DEMO")
  ok(bundle()$name == "DEMO", "bundle switched to DEMO")
  ok(!"sample_type" %in% bundle()$mygenesplus, "DEMO choice list has no sample_type")
  session$setInputs(x = "cohort", y = "GENE01", color = "subtype", plot_btn = 9)
  r2 <- plot_result()
  ok(is.list(r2) && !is.null(r2$plot), "DEMO plot builds")
  cat("    DEMO summary line 1:", strsplit(r2$summary, "\n")[[1]][1], "\n")

  ## ---- switch back to TCGA ----
  session$setInputs(dataset = "TCGA")
  ok(bundle()$name == "TCGA", "bundle switched back to TCGA")
})
finish("test_app_server")
