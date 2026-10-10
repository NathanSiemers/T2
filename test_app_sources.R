## test_app_sources.R — data sources (parts of a collection) and ready-made
## sample subsets (presets) in the real app server, headless via testServer.
## What is checked is the DATA PATH: which samples reach the plot, the Filter
## tab and the download for a chosen source, group and exclusions. Expected
## sets are computed independently from the raw clinical table.
##   T2_DATASETS_DIR=<dir with a tcgatargetgtex.db that declares its parts> Rscript test_app_sources.R
suppressMessages(library(shiny))
ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")
quiet <- function(expr) { utils::capture.output(v <- expr); v }
same_set <- function(a, b) setequal(as.character(a), as.character(b))

base_inputs <- list(size = "", cohort = "all", pcortype = "none", preset_group = "", multi_y = FALSE,
  zscore_y = FALSE, coordflip = FALSE, waterfall = FALSE, waterfall_flip = FALSE,
  allComplete = TRUE, smooth = "TRUE", scales = "fixed", ncols = 8, plot_btn = 0, plot_btn2 = 0, plot_btn3 = 0)

testServer(shiny::shinyAppDir("."), {
  set1 <- function(name, value) do.call(session$setInputs, stats::setNames(list(value), name))
  clicks <- 0
  press <- function() { clicks <<- clicks + 1; set1("plot_btn", clicks) }

  ## ---------------------------------------------------------------- the menu
  srcs <- list_sources()
  ok("tcgatargetgtex|GTEx" %in% srcs && "tcgatargetgtex|TARGET" %in% srcs && "TCGA" %in% srcs,
     "the Data set menu lists the whole collections and the parts of TCGA-TARGET-GTEx")
  ok(sum(grepl("^TCGA\\b", names(srcs))) >= 1 && any(grepl(": GTEx$", names(srcs))),
     "parts are labelled '<collection>: <part>'")

  ## ------------------------------------------------- TCGA: groups and exclusions
  do.call(session$setInputs, c(base_inputs, list(dataset = "TCGA", x = "cohort", y = "CD8A", color = "sample_type")))
  b <- bundle()
  ok(identical(b$key, "TCGA") && length(b$source$rules) == 0, "the whole TCGA collection is the default source")
  ok(same_set(b$source$groups, c("Primary tumors only", "Metastatic samples only", "Normal tissue only")) &&
     same_set(b$source$exclusions, c("Tumor samples only", "Exclude tumors of heme origin")),
     "TCGA offers its database presets as 3 groups and 2 exclusions")
  clin <- b$clin
  st <- as.character(clin$sample_type)
  ## a group
  session$setInputs(preset_group = "Primary tumors only")
  ch <- t2_filter_choices(b$source, b$presets, clin, "Primary tumors only")
  ok(!("Tumor samples only" %in% ch$exclusions) && "Exclude tumors of heme origin" %in% ch$exclusions,
     "within 'Primary tumors only', 'Tumor samples only' changes nothing and is not offered; heme is")
  s <- sanitize_t2_samples(input, b)
  ok(identical(s$group, "Primary tumors only") && length(s$exclusions) == 0, "sanitized sample choice: the group, no exclusions")
  session$setInputs(preset_excl = c("Tumor samples only", "Exclude tumors of heme origin"))
  s <- sanitize_t2_samples(input, b)
  ok(identical(s$exclusions, "Exclude tumors of heme origin"), "an exclusion that is not offered for the group is dropped")
  press()
  r <- plot_result()
  primary <- st %in% c("Primary Tumor", "Primary Blood Derived Cancer - Peripheral Blood")
  heme <- clin$cohort %in% c("LAML", "THYM", "DLBC")
  expected <- clin$sample[primary & !heme]
  ok(all(r$plot$data$sample %in% expected) && nrow(r$plot$data) > 9000,
     sprintf("plot holds only primary, non-heme samples (%d)", nrow(r$plot$data)))
  ok(grepl("Samples: TCGA Pan-Cancer 2018; Primary tumors only; Exclude tumors of heme origin", output$plot_summary, fixed = TRUE),
     "the plot summary names the sample choice")
  csv <- read.csv(output$downloadData, check.names = FALSE)
  ok(same_set(csv$sample, expected), sprintf("the download holds exactly those samples (%d)", nrow(csv)))
  ## the Thanos universe follows
  h <- th_for(b)
  ok(!is.null(h) && sum(h$base()) == length(expected), "the Filter tab's universe is the same sample set")
  ## back to everything
  session$setInputs(preset_group = "", preset_excl = character(0))
  press()
  ok(nrow(plot_result()$plot$data) > length(expected), "clearing the choice brings the other samples back")

  ## ------------------------------------------------------------- a part: GTEx
  session$setInputs(dataset = "tcgatargetgtex|GTEx")
  b <- bundle()
  ok(identical(b$key, "tcgatargetgtex|GTEx") && identical(b$source$label, "GTEx") && grepl(": GTEx$", b$label),
     "switching to the GTEx part: source bundle, labelled")
  clin <- b$clin
  gtex <- clin$study == "GTEX"
  ok(all(unname(b$mycohorts) %in% unique(clin$cohort[gtex])) && length(b$mycohorts) == length(unique(clin$cohort[gtex])),
     sprintf("the cohort menu holds exactly the GTEx tissues (%d)", length(b$mycohorts)))
  h_cols <- th_for(b)$backend$get_columns()
  ok("study" %in% b$source$single_level_columns && !("study" %in% h_cols),
     "'study' has one value within GTEx: not offered as a filter column")
  ok(length(b$source$groups) == 0 && same_set(b$source$exclusions, c("Exclude cell lines", "Exclude tumors of heme origin")),
     "within GTEx: no groups (its 'normal tissues' preset is the cell-line exclusion), two exclusions")
  info <- th_for(b)$backend$get_column_info("sample_type")
  ok(same_set(info$levels, c("Normal Tissue", "Cell Line")), "a categorical filter column lists only the levels present in GTEx")
  session$setInputs(x = "cohort", y = "CD8A", color = "sample_type")
  press()
  r <- plot_result()
  ok(all(r$plot$data$sample %in% clin$sample[gtex]) && nrow(r$plot$data) > 7000,
     sprintf("plot holds GTEx samples only (%d)", nrow(r$plot$data)))
  session$setInputs(preset_excl = "Exclude cell lines")
  press()
  r <- plot_result()
  ok(all(r$plot$data$sample %in% clin$sample[gtex & clin$sample_type != "Cell Line"]) && nrow(r$plot$data) > 7000,
     sprintf("'Exclude cell lines' within GTEx (%d)", nrow(r$plot$data)))
  ok(sum(th_for(b)$base()) == sum(gtex & clin$sample_type != "Cell Line"), "the Filter tab's universe is GTEx without cell lines")
  ok(!identical(th_for(b), h), "the part has its own Thanos instance")

  ## ------------------------------------------------- sticky picks on a switch
  session$setInputs(preset_excl = character(0), y = "FOXP3", color = "sample_type", facet = "gender")
  session$setInputs(dataset = "tcgatargetgtex|TARGET")
  b <- bundle()
  ok(identical(b$source$label, "TARGET"), "switched to TARGET")
  ## the browser would now report the repopulated selectors; emulate what apply_bundle_choices sent
  ## (gender exists in TARGET; FOXP3 exists; sample_type has several levels)
  sel <- apply_bundle_choices(b, keep = list(x = "cohort", y = "FOXP3", color = "sample_type", facet = "gender", cohort = NULL))
  ok(identical(sel$y, "FOXP3") && identical(sel$color, "sample_type") && identical(sel$facet, "gender"),
     "picks that exist in the new source are carried over")
  sel <- apply_bundle_choices(b, keep = list(color = "study"))
  ok(identical(sel$color, ""), "a single-level column of the part is not carried as colour")

  ## ------------------------------------------------------- default cohorts
  session$setInputs(dataset = "TCGA")
  b <- bundle()
  sel <- apply_bundle_choices(b)
  ok(same_set(sel$cohort, b$defaults$cohorts) && length(sel$cohort) == 9, "TCGA opens on its nine default cohorts")
  sel <- apply_bundle_choices(b, keep = list(cohort = c("BRCA", "nonsense")))
  ok(identical(sel$cohort, "BRCA"), "a carried cohort choice is kept where it exists")
})
