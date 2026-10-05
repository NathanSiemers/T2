## test_app_thanos.R — the Filter tab (Thanos) wired into the real app server,
## driven headless via testServer. What is checked is the DATA PATH: which
## samples end up in the plot / KM curve / download for a given combination of
## Select-tab filters and Filter-tab (Thanos) filters. Expected sample sets are
## computed independently with gitr(), never through the code under test.
##
## Not covered here (needs a browser): tab switching, panel insertion into the
## page, the selectize round trip of add_vars(), layout.
##   Rscript test_app_thanos.R        (from the app directory)
suppressMessages(library(shiny))

ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")
quiet <- function(expr) { utils::capture.output(v <- expr); v }
same_set <- function(a, b) setequal(as.character(a), as.character(b))

base_inputs <- list(
  size = "", cohort = "all",
  pcortype = "none", nonormal = FALSE, noheme = FALSE, multi_y = FALSE,
  zscore_y = FALSE, coordflip = FALSE, waterfall = FALSE, waterfall_flip = FALSE,
  allComplete = TRUE, smooth = "TRUE", scales = "fixed",
  
  ncols = 8, plot_btn = 0, plot_btn2 = 0, plot_btn3 = 0
)

testServer(shiny::shinyAppDir("."), {
  ok(HAVE_THANOS, "Thanos available in the app")
  vid <- thanos$thanos_vid
  th_in <- function(ds, kind, v) paste0(t2_thanos_id(ds), "-", kind, "_", vid(v))
  set1 <- function(name, value) do.call(session$setInputs, stats::setNames(list(value), name))
  clicks <- c(plot_btn = 0, plot_btn2 = 0, plot_btn3 = 0)
  press <- function(btn) { clicks[btn] <<- clicks[btn] + 1; set1(btn, unname(clicks[btn])) }

  ## ------------------------------------------------------------------ TCGA
  do.call(session$setInputs, c(base_inputs,
          list(dataset = "TCGA", x = "CD8A", y = "FOXP3", color = "sample_type")))
  b <- bundle()
  h <- th_for(b)
  ok(!is.null(h) && identical(th_for(b), h), "one Thanos instance per dataset, reused")

  ## independent truth: everything the scatter plot could show
  g <- quiet(gitr(c("CD8A", "FOXP3", "sample_type", "gender", "TP53.mut"),
                  dbfile = b$path, roles = b$roles))
  g$sample <- as.character(g$sample)
  plottable <- complete.cases(g[, c("sample", "cohort", "sample_type", "CD8A", "FOXP3")])

  ok(is.null(tryCatch(plot_result(), error = function(e) NULL)),
     "nothing is plotted before a Plot button is pressed")

  ## ---- no Thanos filters: same samples as the app without a Filter tab ----
  press("plot_btn")
  r0 <- plot_result()
  ok(is.list(r0) && !is.null(r0$plot), "plot builds (Select tab button)")
  ok(same_set(r0$plot$data$sample, g$sample[plottable]),
     sprintf("no filters: plot holds exactly the unfiltered samples (%d)", nrow(r0$plot$data)))
  ok(is.null(plot_snapshot$keep), "no filters: nothing extra is passed to the plotter")
  ok(grepl("no additional filtering", output$plot_summary), "summary says no Filter-tab filtering")

  ## ---- a slider filter on CD8A ----
  q <- as.numeric(round(quantile(g$CD8A, c(0.4, 0.8), na.rm = TRUE), 1))
  set1(paste0(t2_thanos_id("TCGA"), "-vars"), c("CD8A", "gender"))
  set1(th_in("TCGA", "filter", "CD8A"), q)
  in_rng <- !is.na(g$CD8A) & g$CD8A >= q[1] & g$CD8A <= q[2]
  ok(h$th$n_selected() == sum(in_rng | is.na(g$CD8A)),
     sprintf("Thanos count follows the slider (%d samples, NA kept by default)", h$th$n_selected()))
  ok(identical(plot_result(), r0), "changing a filter does NOT redraw until Plot is pressed")

  press("plot_btn3")
  r1 <- plot_result()
  ok(same_set(r1$plot$data$sample, g$sample[plottable & in_rng]),
     sprintf("Filter-tab Plot button: plot holds exactly the CD8A-filtered samples (%d)",
             nrow(r1$plot$data)))
  ok(grepl("CD8A in \\[", output$plot_summary) && grepl("samples pass", output$filter_status),
     "the active filter is reported with the plot")

  ## ---- add a checkbox filter (gender), then drop its NAs ----
  lev <- sort(unique(na.omit(as.character(g$gender))))
  set1(th_in("TCGA", "filter", "gender"), lev[1])
  is_lev <- !is.na(g$gender) & as.character(g$gender) == lev[1]
  press("plot_btn2")
  r2 <- plot_result()
  ok(same_set(r2$plot$data$sample, g$sample[plottable & in_rng & (is_lev | is.na(g$gender))]),
     sprintf("Appearance-tab Plot button: CD8A + gender=%s filters applied (%d)", lev[1], nrow(r2$plot$data)))
  set1(th_in("TCGA", "na", "gender"), FALSE)
  press("plot_btn")
  r3 <- plot_result()
  ok(same_set(r3$plot$data$sample, g$sample[plottable & in_rng & is_lev]),
     "unticking 'include NA' drops the samples with no gender")

  ## ---- Select-tab pre-filters define the Thanos universe, live ----
  co <- unname(b$mycohorts)[1:2]
  session$setInputs(cohort = co, nonormal = TRUE)
  pre <- g$cohort %in% co & !(as.character(g$sample_type) %in% b$roles$normal_label)
  ok(h$th$n_selected() == sum(pre & (in_rng | is.na(g$CD8A)) & is_lev),
     sprintf("cohort + Exclude Non-tumor shrink the Thanos universe live (%d selected)", h$th$n_selected()))
  ok(grepl(format(sum(pre), big.mark = ","), output$filter_count, fixed = TRUE),
     "Filter tab count shows the universe size")
  ok(identical(isolate(h$th$filters())$CD8A, q), "the user's filter settings survive a cohort change")
  press("plot_btn")
  r4 <- plot_result()
  ok(same_set(r4$plot$data$sample, g$sample[plottable & pre & in_rng & is_lev]),
     sprintf("plot = cohort + non-tumor + Thanos filters (%d)", nrow(r4$plot$data)))

  ## ---- download: the table behind the plot ----
  ## every sample passing the Select-tab and Filter-tab filters. Unlike the
  ## plot it keeps rows with a missing value (here: CD8A is NA, let through by
  ## the filter's "include NA"), so the table shows what was not drawable.
  csv <- read.csv(output$downloadData, check.names = FALSE)
  passing <- pre & (in_rng | is.na(g$CD8A)) & is_lev
  ok(same_set(csv$sample, g$sample[passing]),
     sprintf("Download Table holds exactly the samples passing all filters (%d rows)", nrow(csv)))
  ok(all(r4$plot$data$sample %in% csv$sample), "every plotted sample is in the download")

  ## ---- a column whose name needs id-encoding (TP53.mut) ----
  session$setInputs(cohort = "all", nonormal = FALSE)
  set1(paste0(t2_thanos_id("TCGA"), "-vars"), "TP53.mut")
  ok(h$th$n_selected() == nrow(g), "removing filter columns removes their filters")
  set1(th_in("TCGA", "filter", "TP53.mut"), "1")
  set1(th_in("TCGA", "na", "TP53.mut"), FALSE)
  mut <- !is.na(g$TP53.mut) & as.character(g$TP53.mut) == "1"
  press("plot_btn")
  r5 <- plot_result()
  ok(same_set(r5$plot$data$sample, g$sample[plottable & mut]),
     sprintf("categorical filter on 'TP53.mut' (encoded id) applied (%d)", nrow(r5$plot$data)))

  ## ---- survival (Kaplan-Meier) path honours the filters too ----
  session$setInputs(x = "OS", y = "MKI67", noheme = TRUE)
  press("plot_btn")
  r6 <- plot_result()
  ok(inherits(r6, "ggsurvplot"), "survival plot builds with a Thanos filter active")
  km <- attr(r6, "km_data")
  heme <- g$cohort %in% b$roles$heme_values
  ok(all(km$sample %in% g$sample[mut & !heme]) && nrow(km) > 100,
     sprintf("KM samples are all TP53-mutant and non-heme (%d)", nrow(km)))
  session$setInputs(noheme = FALSE)
  set1(paste0(t2_thanos_id("TCGA"), "-vars"), character(0))
  press("plot_btn")
  km_all <- attr(plot_result(), "km_data")
  ok(nrow(km_all) > nrow(km) && is.null(plot_snapshot$keep),
     sprintf("removing all filters restores the full KM cohort (%d)", nrow(km_all)))

  ## ---- unknown / client-invented column names are ignored ----
  set1(paste0(t2_thanos_id("TCGA"), "-vars"), c("CD8A", "no_such_probe; DROP TABLE x"))
  ok(identical(isolate(h$th$selected_vars()), "CD8A"), "invented filter column is ignored")
  set1(th_in("TCGA", "filter", "CD8A"), q)
  n_tcga <- h$th$n_selected()

  ## --------------------------------------------- dataset switch: TCGA -> DEMO
  ## fields of one dataset need not exist in another: each dataset has its own
  ## Thanos instance, so a TCGA filter can never be applied to DEMO
  session$setInputs(dataset = "DEMO")
  bd <- bundle()
  ok(bd$name == "DEMO", "switched to DEMO")
  hd <- th_for(bd)
  ok(!identical(hd, h) && hd$backend$n_rows() == 60, "DEMO has its own Thanos instance (60 samples)")
  ok(length(isolate(hd$th$selected_vars())) == 0 && hd$th$n_selected() == 60,
     "DEMO starts with no filters: the TCGA CD8A filter did not follow")
  ok(!("CD8A" %in% hd$backend$get_columns()), "CD8A is not a DEMO field")
  set1(paste0(t2_thanos_id("DEMO"), "-vars"), c("CD8A", "GENE01"))
  ok(identical(isolate(hd$th$selected_vars()), "GENE01"),
     "a TCGA-only field cannot be selected for filtering in DEMO")
  session$setInputs(x = "cohort", y = "GENE01", color = "subtype", cohort = "all")
  set1(paste0(t2_thanos_id("DEMO"), "-vars"), character(0))
  press("plot_btn")
  rd <- plot_result()
  ok(is.list(rd) && !is.null(rd$plot) && nrow(rd$plot$data) == 60 && is.null(plot_snapshot$keep),
     "DEMO plot builds with all 60 samples")
  gd <- quiet(gitr("GENE01", dbfile = bd$path, roles = bd$roles))
  med <- round(median(gd$GENE01), 2)
  set1(paste0(t2_thanos_id("DEMO"), "-vars"), "GENE01")
  set1(th_in("DEMO", "filter", "GENE01"), c(med, round(max(gd$GENE01), 2) - 0.01))
  press("plot_btn3")
  rd2 <- plot_result()
  ok(nrow(rd2$plot$data) < 60 && nrow(rd2$plot$data) > 0 &&
     all(rd2$plot$data$GENE01 >= med),
     sprintf("DEMO filter applied in DEMO (%d of 60 samples)", nrow(rd2$plot$data)))
  ## the main-page variable push only ever offers fields of the active dataset
  session$elapse(600)
  ok(all(isolate(hd$th$selected_vars()) %in% hd$backend$get_columns()),
     "variables pushed from the Select tab are all DEMO fields")

  ## ------------------------------------------------------------ back to TCGA
  session$setInputs(dataset = "TCGA")
  ok(bundle()$name == "TCGA" && identical(th_for(bundle()), h), "back on TCGA, same instance")
  ok(identical(isolate(h$th$filters())$CD8A, q) && h$th$n_selected() == n_tcga,
     "TCGA filters were kept while DEMO was active")
  ok(identical(isolate(hd$th$filters())$GENE01[1], med),
     "DEMO filters are kept too, and stay with DEMO")
  session$setInputs(x = "CD8A", y = "FOXP3", color = "sample_type")
  press("plot_btn")
  r7 <- plot_result()
  ok(same_set(r7$plot$data$sample, g$sample[plottable & in_rng]),
     "TCGA plot uses TCGA's own filters after the round trip")
})
cat("== app thanos test done ==\n")
