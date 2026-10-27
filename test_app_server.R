## test_app_server.R — drive the real Shiny server logic headless via testServer.
## Verifies: default load = TCGA, plot builds; switching to DEMO rebinds the
## bundle and a plot builds against the synthetic dataset too.
suppressMessages(library(shiny))

source("t2_test_helpers.R")
`%||%` <- function(a, b) if (is.null(a)) b else a   # ok() counts failures, finish() exits non-zero, quiet()

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

  ## ---- B6: "all" next to a named cohort means all ----
  session$setInputs(cohort = c("all", "BRCA"))
  ok(identical(sanitize_t2_input(input, bundle())$cohort, "all"), "cohort: 'all' with BRCA reduces to 'all'")
  session$setInputs(cohort = c("BRCA", "LUAD"))
  ok(identical(sanitize_t2_input(input, bundle())$cohort, c("BRCA", "LUAD")), "cohort: named cohorts stay as they are")
  session$setInputs(cohort = "all")
  ## ---- B9: a vector where one value is expected must not error the observers ----
  r_err <- tryCatch({ session$setInputs(multi_y = c(TRUE, FALSE)); session$setInputs(dataset = c("TCGA", "cptac")); "" },
                    error = function(e) conditionMessage(e))
  ok(identical(r_err, ""), paste("vector-valued multi_y / dataset inputs do not raise", r_err))
  session$setInputs(multi_y = FALSE, dataset = "TCGA")

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
  ok(grepl("Not-detected protein values set to 0 \\([0-9,]+ of [0-9,]+ samples shown\\)", cap), paste("Zero: the caption says so:", gsub("\n", " / ", cap)))
  n_z <- as.integer(sub(".*Samples with data for both X and Y: (\\d+).*", "\\1", rz$summary))
  ok(n_z > n_na && grepl("CLDN6.prot: [0-9,]+ not-detected values set to 0 among [0-9,]+ samples shown", rz$summary), sprintf("Zero: more samples have data (%d, was %d) and the Data Summary has a line", n_z, n_na))
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
  ## ---- PUBLISH-UNIFY step 3: one shared appearance state ----
  session$setInputs(tabs = "publish", x = "cohort", y = "CD8A", color = "sample_type", title_size = 20, pub_preset = "slide")
  s_pub <- pub_spec()
  ok(!is.null(s_pub) && identical(s_pub$inp$title_size, 20), "pub_spec carries the SHARED title_size (unified style)")
  ok(identical(pub_preset()$style$title_size, 24) && !is.null(pub_spec()$gg$smooth.linewidth),
     "the preset's gg stays the publish-only base under the shared tweaks")
  ## the preset observer writes the shared (unprefixed) ids: it must run clean for a style-carrying preset
  r_pre <- tryCatch({ session$setInputs(pub_preset = "nature2"); session$flushReact(); "" }, error = function(e) conditionMessage(e))
  ok(identical(r_pre, ""), paste("choosing a preset runs the shared-id writer without error", r_pre))
  ## live restyle: a style change after a plot redraws, debounced; none before the first Plot press
  session$setInputs(tabs = "plot", plot_btn = 20)
  invisible(plot_result()); session$flushReact()
  k0 <- plot_clicks(); b0 <- style_bump()
  session$setInputs(title_size = 12)
  session$elapse(1000); session$flushReact()
  ok(style_bump() == b0 + 1 && plot_clicks() == k0 + 1, "a style change after a plot bumps plot_clicks (debounced redraw)")
  b1 <- style_bump(); session$elapse(2000); session$flushReact()
  ok(style_bump() == b1, "with no further change there is no further redraw (no loop)")
  ## ---- PUBLISH-UNIFY step 6: per-role quantize tokens ----
  session$setInputs(dataset = "DEMO")
  bq <- bundle()
  tk <- t2_quant_token("GENE01", 3)
  sq <- sanitize_t2_input(list(x = tk, y = tk, size = tk, condition = tk), bq)
  ok(identical(sq$x, tk) && identical(sq$y, tk) && identical(sq$size, tk) && identical(sq$condition, tk),
     "sanitizer keeps a valid token in x, y, size and condition")
  sb <- sanitize_t2_input(list(x = "t2q::9::GENE01", y = "t2q::3::NOSUCH", size = "t2q::3::NOSUCH", condition = c("t2q::9::GENE01", "t2q::3::NOSUCH")), bq)
  ok(is.null(sb$x) && is.null(sb$y) && is.null(sb$condition) && !nzchar(sb$size %||% ""),
     "the sanitizer drops malformed / unknown tokens in x, y, size and condition")
  ## survival (TCGA): a Y token is demoted; a color token keeps the existing refusal
  session$setInputs(dataset = "TCGA", tabs = "plot")
  ts <- t2_quant_token("CD8A", 3)
  rv <- fun_plot1(sanitize_t2_input(list(x = "OS", y = ts, cohort = "all"), bundle()), reactive = FALSE, ctx = t2_plot_ctx(bundle()))
  ok(inherits(rv, "ggsurvplot") && grepl("groups have no meaning as y", attr(rv, "t2summary") %||% ""), "survival: a Y token is demoted with the notice")
  rv2 <- fun_plot1(sanitize_t2_input(list(x = "OS", y = "CD8A", color = t2_quant_token("MKI67", 3), cohort = "all"), bundle()), reactive = FALSE, ctx = t2_plot_ctx(bundle()))
  ok(grepl("quantized variables are not a survival marker", rv2$warning %||% ""), "survival: a color token keeps its refusal")
})
finish("test_app_server")
