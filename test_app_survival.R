## test_app_survival.R — verify the Kaplan-Meier survival view through the REAL
## Shiny app server (testServer), the same path the app takes when a user picks
## a time-to-event endpoint for X. Also confirms scatter plots are unaffected.
suppressMessages(library(shiny))

source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero, quiet()

base_inputs <- list(
  size = "", cohort = "all", pcortype = "none", nonormal = FALSE, noheme = FALSE,
  multi_y = FALSE, zscore_y = FALSE, coordflip = FALSE, waterfall = FALSE,
  waterfall_flip = FALSE, allComplete = TRUE, smooth = "TRUE", scales = "fixed",
 
  ncols = 8, plot_btn = 0, plot_btn2 = 0
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

  ## ---- multiple Y probes -> median-z signature ----
  session$setInputs(x = "OS", y = c("MKI67", "TOP2A"), cohort = "all", facet = "", plot_btn = 3)
  r3 <- plot_result()
  ok(inherits(r3, "ggsurvplot") && length(attr(r3, "stats")$markers) == 2,
     "multiple Y -> median-z signature")

  ## ---- 'Remove influences of' adjusts the marker (covariate residualization) ----
  session$setInputs(y = "CD8A", condition = "StromalScore.estimate", pcortype = "y", plot_btn = 4)
  r4 <- plot_result()
  ok(inherits(r4, "ggsurvplot") && !is.null(attr(r4, "stats")$adjusted_for),
     "Remove influences of -> covariate-adjusted marker")

  ## ---- missing Y marker -> empty (app guards it), no crash ----
  session$setInputs(y = "", condition = "", pcortype = "none", plot_btn = 5)
  r5 <- plot_result()
  ok(is.null(r5), "no Y marker -> empty plot (guarded), not a crash")

  ## ---- scatter still works when X is a normal gene ----
  session$setInputs(x = "CD8A", y = "MKI67", plot_btn = 6)
  r6 <- plot_result()
  ok(is.list(r6) && !is.null(r6$plot), "normal scatter still builds")

  ## ---- the time-to-event variables are the data set's own (/meta tte_variables) ----
  session$setInputs(dataset = "tcgatargetgtex")
  b <- bundle()
  ok(length(b$tte) == 0 && is.null(sanitize_t2_input(list(x = "OS", y = "CD8A"), b)$x),
     "a data set without time-to-event variables does not accept OS as X")
  ## the survival hint: the dataset's own tte names, only when it has some
  ok(is.null(t2_survival_hint(b)), "no time-to-event variables: no survival hint")
  session$setInputs(dataset = "TCGA")
  ok(identical(t2_survival_hint_text(bundle()$tte), "Survival curves: choose OS, PFI, DSS or DFI as X (Kaplan-Meier by groups of Y)"),
     "TCGA hint: choose OS, PFI, DSS or DFI as X (Kaplan-Meier by groups of Y)")
  hh <- as.character(t2_survival_hint(bundle()))
  ok(grepl("OS: Overall Survival", hh, fixed = TRUE) && grepl("t2-survival-hint", hh, fixed = TRUE), "the hint carries the labels of the variables")
  ok(grepl("choose OS, PFI, DSS or DFI as X", as.character(output$about_survival_hint$html), fixed = TRUE) &&
     grepl("t2-hint-x", as.character(output$x_survival_hint$html), fixed = TRUE),
     "the hint shows on the About tab and under the X selector")
  session$setInputs(dataset = "cptac")
  b <- bundle()
  ok(identical(t2_survival_hint_text(b$tte), "Survival curves: choose OS or PFI as X (Kaplan-Meier by groups of Y)"), "cptac hint: OS or PFI")
  ok(identical(tte_names(b), c("OS", "PFI")) && identical(sanitize_t2_input(list(x = "PFI", y = "CD8A"), b)$x, "PFI") &&
     is.null(sanitize_t2_input(list(x = "DSS", y = "CD8A"), b)$x),
     "cptac offers OS and PFI as X, not TCGA's DSS")
  session$setInputs(x = "OS", y = "CD8A", color = "", cohort = "all", facet = "", condition = "", plot_btn = 20)
  rc <- plot_result()
  ok(inherits(rc, "ggsurvplot") && grepl("^OS", attr(rc, "t2summary")), "cptac: OS ~ CD8A -> Kaplan-Meier from the dataset's own OS / OS.time")
  ok(grepl("Time (days)", rc$plot$labels$x, fixed = TRUE), "the time axis is labelled with the declared unit")
  session$setInputs(dataset = "DEMO", x = "OS", y = "GENE01", plot_btn = 21)
  rd <- plot_result()
  ok(inherits(rd, "ggsurvplot") && grepl("Overall Survival", rd$plot$labels$title), "DEMO: the label of its tte entry titles the plot (Overall Survival)")

  ## ---- B3: a sparse marker (60% equal values) merges cut points: the groups are
  ## named by position among the surviving cuts, the count is the real one, and a
  ## grouping with a group under 5 samples is refused ----
  set.seed(7)
  sparse <- c(rep(0, 60), rnorm(40, 5))
  qg <- t2_quantile_groups(sparse, 3)
  ok(!is.null(qg$grp) && qg$n == 2 && identical(levels(qg$grp), c("Low", "High")),
     "sparse marker, 3 asked: 2 groups named Low/High (not Low/Mid)")
  ok(identical(levels(t2_quantile_groups(rnorm(100), 3)$grp), c("Low", "Mid", "High")), "a continuous marker keeps Low/Mid/High")
  ok(identical(levels(t2_quantile_groups(rnorm(100), 4)$grp), paste0("Q", 1:4)), "4 groups: Q1..Q4")
  tiny <- c(rep(0, 50), rep(1, 47), 2, 3, 4)
  ok(!is.null(t2_quantile_groups(tiny, 3)$refused), "a grouping that leaves a group with fewer than 5 samples is refused")
  ## ---- B5: a covariate fit that is not possible says so ----
  adj <- residualize_on(rnorm(50), data.frame(f = factor(rep("a", 50))))
  ok(identical(attr(adj, "adjusted"), FALSE) && length(adj) == 50, "one-level factor condition: residualize_on reports adjusted = FALSE")
  ok(is.null(attr(residualize_on(rnorm(50), data.frame(z = rnorm(50))), "adjusted")), "a possible fit carries no adjusted flag")
})
finish("test_app_survival")
