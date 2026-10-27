## test_app_analysis.R — the Analysis tab wired into the real app server, driven headless via
## testServer (pattern of test_app_thanos.R). Contract: T2Mobile/docs/ANALYSIS-SPEC.md.
## Expected numbers are R's own: a direct call of group_compare.R / stats on the same vectors.
##   Rscript test_app_analysis.R        (from the app directory, against the dev service)
suppressMessages(library(shiny))
source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero
`%||%` <- function(a, b) if (is.null(a)) b else a

testServer(shiny::shinyAppDir("."), {
  ok(HAVE_THANOS, "Thanos available in the app")
  vid <- thanos$thanos_vid
  th_in <- function(ds, kind, v) paste0(t2_thanos_id(ds), "-", kind, "_", vid(v))
  set1 <- function(name, value) do.call(session$setInputs, stats::setNames(list(value), name))
  runs <- 0; screens <- 0
  run <- function() { runs <<- runs + 1; session$setInputs(analysis_run = runs) }
  scr <- function() { screens <<- screens + 1; session$setInputs(analysis_screen = screens) }
  msg <- function(expr) tryCatch({ expr; NA_character_ }, error = function(e) conditionMessage(e))
  ## capture what the server sends to the selectizes (the mock session has no browser)
  sent <- list()
  assign("update_selectize_ranked", function(session, inputId, choices, selected = NULL, label = NULL)
           sent[[inputId]] <<- list(choices = choices, selected = selected), envir = environment(an_get))

  session$setInputs(dataset = "TCGA", tabs = "analysis", cohort = "all", preset_group = "", preset_excl = character(0),
                    surv_max_days = 1825)
  session$setInputs(dataset = "DEMO")
  b <- bundle(); h <- th_for(b)
  ok(b$name == "DEMO" && length(h$backend$samples) == 60, "DEMO active, 60 samples")
  cohort <- h$backend$get_column("cohort"); g1 <- h$backend$get_column("GENE01"); g2 <- h$backend$get_column("GENE02")
  all60 <- rep(TRUE, 60)

  ## ---- (a) categorical grouping x numeric variable ----
  session$setInputs(analysis_group = "cohort", analysis_var = "GENE01", analysis_means = FALSE)
  run()
  r <- analysis_result()
  gd <- t2_group_categorical(cohort, all60, levels = h$backend$get_column_info("cohort")$levels)
  rd <- t2_group_test(g1, gd$grp, "num")
  ok(!is.null(r$res$test) && identical(r$res$test$p, rd$test$p) && identical(r$res$method, rd$method),
     sprintf("(a) cohort x GENE01: %s, p = %s equals the direct call", r$res$method, fmtp(r$res$test$p)))
  ok(grepl(fmtp(r$res$test$p), output$analysis_stats, fixed = TRUE), "(a) the stats table shows the formatted p")
  ok(grepl("Kruskal", output$analysis_stats) || nlevels(gd$grp) == 2, "(a) 3+ groups use Kruskal-Wallis")
  ok(!is.null(output$analysis_plot), "(a) the plot renders")
  csv <- readLines(output$analysis_download)
  ok(grepl("cohort", csv[1]) && grepl("universe n = 60", csv[2]) && any(grepl("^\"term\",\"method\",\"statistic\"", csv)),
     "(a) the CSV carries the header lines, the groups block and the test block")

  ## ---- (b) quantized grouping x numeric ----
  session$setInputs(analysis_group = "GENE02", analysis_quant_k = 3, analysis_var = "GENE01")
  ok(grepl("analysis_quant_k", paste(output$analysis_quant_ui$html), fixed = TRUE), "(b) the k radio is offered for a numeric grouping")
  run(); rb <- analysis_result()
  gq <- t2_group_quantized(g2, all60, 3)
  ok(identical(rb$res$test$p, t2_group_test(g1, gq$grp, "num")$test$p) && identical(levels(rb$g$grp), gq$labels),
     sprintf("(b) tertiles of GENE02 (%s) x GENE01: p equals the direct call", paste(gq$labels, collapse = "/")))
  session$setInputs(analysis_group = "cohort")
  ok(is.null(output$analysis_quant_ui$html) || !grepl("analysis_quant_k", output$analysis_quant_ui$html), "(b) no k radio for a categorical grouping")

  ## ---- (c) means toggle ----
  session$setInputs(analysis_group = "GENE02", analysis_quant_k = 3, analysis_means = TRUE); run()
  ok(analysis_result()$res$method == "Welch one-way ANOVA", "(c) means on, 3 groups: Welch one-way ANOVA")
  session$setInputs(analysis_quant_k = 2); run()
  rc <- analysis_result()
  ok(rc$res$method == "Welch t-test" && identical(rc$res$test$p, t.test(g1 ~ t2_group_quantized(g2, all60, 2)$grp)$p.value),
     "(c) means on, 2 groups: Welch t-test, p equals t.test")
  session$setInputs(analysis_means = FALSE); run()
  ok(analysis_result()$res$method == "Wilcoxon rank-sum", "(c) means off, 2 groups: Wilcoxon rank-sum")

  ## ---- (d) time-to-event variable ----
  session$setInputs(analysis_group = "cohort", analysis_var = "OS"); run()
  rt <- analysis_result()
  ent <- b$tte$OS
  rdt <- t2_group_test(NULL, gd$grp, "tte", tte = list(time = h$backend$get_column(ent$time_col), event = h$backend$get_column(ent$event_col)),
                       max_days = 1825)
  ok(rt$res$method == "Log-rank" && identical(rt$res$test$p, rdt$test$p), sprintf("(d) OS by cohort: Log-rank, p = %s equals the direct call", fmtp(rt$res$test$p)))
  ok(!is.null(output$analysis_plot), "(d) the Kaplan-Meier plot renders")
  ## categorical test variable
  session$setInputs(analysis_group = "GENE02", analysis_quant_k = 2, analysis_var = "tissue_origin"); run()
  ok(analysis_result()$res$method %in% c("Pearson chi-squared", "Fisher exact"), "(d) a categorical variable gets a chi-squared / Fisher test")

  ## ---- (e) the screen ----
  session$setInputs(analysis_group = "cohort", analysis_means = FALSE); scr()
  sc <- screen_result()$table
  ok(is.data.frame(sc) && all(c("variable", "p", "p_bh", "note") %in% names(sc)) && !("cohort" %in% sc$variable) && nrow(sc) > 5,
     sprintf("(e) the screen ranks %d variables and leaves out the grouping's own column", nrow(sc)))
  pp <- sc$p[!is.na(sc$p)]
  ok(!is.unsorted(pp) && all(sc$p_bh[!is.na(sc$p)] >= pp - 1e-12) &&
     isTRUE(all.equal(sc$p_bh[!is.na(sc$p)], p.adjust(pp, "BH"))), "(e) ranked by p ascending, p_bh = BH over the tests with a p")
  ok(grepl(sc$variable[1], output$analysis_screen_table, fixed = TRUE), "(e) the screen table renders")
  sent$analysis_var <- NULL
  session$setInputs(analysis_screen_pick = sc$variable[2])
  ok(identical(sent$analysis_var$selected, sc$variable[2]), "(e) picking a row selects it as the variable to test")
  session$setInputs(analysis_var = sc$variable[2]); run()
  ok(is.na(msg(analysis_result())) || !grepl("Pick a grouping", msg(analysis_result())), "(e) the picked variable runs as the comparison")

  ## ---- (f) a hostile client ----
  for (bad in list("t2q::99::X", "t2split::nope", "t2split::*", "t2q::3::cohort", "t2q::2::", "", NA_character_, list("a", "b"),
                   strrep("x", 5000), "t2split::GENE01; DROP TABLE x")) {
    session$setInputs(analysis_group = bad, analysis_var = "GENE01"); run()
    m <- msg(analysis_result())
    ok(!is.na(m) && grepl("Pick a grouping", m), sprintf("(f) hostile analysis_group %s -> a plain message, no crash", substr(paste(unlist(bad), collapse = "|"), 1, 24)))
  }
  session$setInputs(analysis_group = "cohort", analysis_var = "no_such_var'; DROP", analysis_quant_k = "junk", analysis_means = "maybe"); run()
  ok(grepl("Pick a grouping", msg(analysis_result())), "(f) a hostile analysis_var is refused with the same message")
  session$setInputs(analysis_group = "GENE02", analysis_var = "GENE01", analysis_quant_k = 1e9, analysis_means = list(TRUE, FALSE)); run()
  ok(!is.null(analysis_result()$res$test), "(f) junk k / flag values still run on the menu default")
  ok(analysis_result()$a$grouping$k == 4,
     "(f) an out-of-range k snaps to the nearest menu value")

  ## ---- (h) quantized variables in ordinary plots (ANALYSIS step 6) ----
  ## (b was set up above: DEMO active; the plot reads its Select-tab inputs, sanitized)
  sent <- list()
  session$setInputs(tabs = "select", x = "cohort", y = "GENE01", color = "", facet = character(0), size = "",
                    condition = character(0), pcortype = "none", multi_y = FALSE, zscore_y = FALSE,
                    plot_btn = 0, plot_btn2 = 0, plot_btn3 = 0)
  pn <- 0
  plot_with <- function(...) { pn <<- pn + 1; do.call(session$setInputs, c(list(...), list(plot_btn = pn))); plot_result() }
  tok <- t2_quant_token("GENE02", 3); lab <- t2_quant_label("GENE02", 3)
  ok(identical(sanitize_t2_input(list(color = tok, facet = c(tok, "cohort", "t2q::3::cohort", "t2q::9::GENE02")), b)$facet, c(tok, "cohort")) &&
     identical(sanitize_t2_input(list(color = tok), b)$color, tok) &&
     identical(sanitize_t2_input(list(color = "t2q::3::cohort"), b)$color, ""),
     "(h) the sanitizer keeps a valid numeric token, drops bad ones (categorical source, k out of range)")
  rq <- plot_with(color = tok)
  ok(inherits(rq$plot, "ggplot") && grepl(lab, rq$summary, fixed = TRUE),
     sprintf("(h) color = %s plots; the summary names the derived variable '%s'", tok, lab))
  ok(inherits(rq$plot, "ggplot") && lab %in% names(rq$plot$data) && nlevels(rq$plot$data[[lab]]) == 3,
     "(h) the derived column has the three tertile groups")
  rf <- plot_with(color = "", facet = tok)
  ok(inherits(rf$plot, "ggplot") && lab %in% names(rf$plot$data) && !is.null(rf$plot$facet$params$facets %||% rf$plot$facet$params$rows),
     "(h) facet = token: one panel per tertile group")
  ## hostile: a token whose source is categorical never reaches the plotter; the plot equals the bare one
  rh <- plot_with(color = "t2q::3::cohort", facet = character(0))
  r0 <- plot_with(color = "", facet = character(0))
  ok(inherits(rh$plot, "ggplot") && identical(names(rh$plot$data), names(r0$plot$data)),
     "(h) a token over a categorical variable is dropped: the plot is the one without it")
  ## the plotter's own guard (the sanitizer bypassed): a categorical source is refused with a note
  rd <- plotter(x = "cohort", y = "GENE01", color = "t2q::3::cohort", ctx = t2_plot_ctx(b))
  ok(inherits(rd$plot, "ggplot") && !any(grepl("t2q::", names(rd$plot$data))), "(h) plotter(): an unusable token is ignored, with a note")
  ok(grepl("not a numeric variable", rd$warning %||% ""), "(h) the note says why")
  ## the chip: a numeric color pick shows it; choosing 3 rewrites color to the token
  session$setInputs(color = "GENE02")
  ok(grepl("quant_chip_color", paste(output$quant_chip_ui$html), fixed = TRUE), "(h) a numeric color pick shows the quantize chip")
  session$setInputs(quant_chip_color = "3")
  ok(identical(sent$color$selected, tok) && tok %in% sent$color$choices$value && sent$color$choices$label[match(tok, sent$color$choices$value)] == lab,
     "(h) the chip's 3 rewrites color to the token (the token is an extra menu row with its label)")
  session$setInputs(color = tok, quant_chip_color = "0")
  ok(identical(sent$color$selected, "GENE02"), "(h) 'values' rewrites the token back to the bare name")
  sent$color <- NULL; session$setInputs(color = tok, quant_chip_color = "3")
  ok(is.null(sent$color), "(h) a chip value equal to the current state rewrites nothing (no loop)")
  session$setInputs(color = "cohort")
  ok(!grepl("quant_chip_color", paste(output$quant_chip_ui$html), fixed = TRUE), "(h) a categorical color pick shows no chip")

  ## ---- (i)-(vi) PUBLISH-UNIFY step 6: per-role tokens on x / y / size / condition ----
  session$setInputs(tabs = "select", x = "GENE01", y = "GENE02", color = "", facet = character(0), size = "", condition = character(0))
  tx <- t2_quant_token("GENE01", 3); labx <- t2_quant_label("GENE01", 3)
  ty <- t2_quant_token("GENE02", 3)
  ok(grepl("quant_chip_x", paste(output$quant_chip_ui$html), fixed = TRUE), "(i) a numeric X pick shows the quantize chip")
  sent <- list(); session$setInputs(quant_chip_x = "3")
  ok(identical(sent$x$selected, tx), "(i) the X chip's 3 rewrites x to the token")
  session$setInputs(x = tx)
  rx <- plot_with(x = tx)
  ok(inherits(rx$plot, "ggplot") && grepl("(tertiles)", rx$summary, fixed = TRUE) && grepl("(tertiles)", rx$plot$labels$title %||% "", fixed = TRUE),
     "(i) an X token plots; summary and title carry '(tertiles)'")
  ry <- plot_with(x = "GENE01", y = ty)
  ok(inherits(ry$plot, "ggplot") && grepl("groups have no meaning as y", ry$warning %||% "") && "GENE02" %in% names(ry$plot$data) && !grepl("t2q::", ry$summary),
     "(ii) a Y token plots the source column with the notice")
  rs <- plot_with(x = "GENE01", y = "GENE02", size = tok)
  ok(inherits(rs$plot, "ggplot") && grepl("groups have no meaning as size", rs$warning %||% ""), "(ii) a size token is demoted with the notice")
  ## (iii) too few samples per group: the plot draws on the source column with the refusal notice
  rt <- plotter(x = tx, y = "GENE02", ctx = t2_plot_ctx(b, keep = h$backend$samples[1:8]))
  ok(inherits(rt$plot, "ggplot") && grepl("cannot be split", rt$warning %||% "") && "GENE01" %in% names(rt$plot$data),
     "(iii) a refused X cut falls back to the source column, with the refusal notice")
  ## (v) the Filter tab sees source names only
  session$setInputs(x = tx, y = ty, size = tok, condition = t2_quant_token("GENE02", 2), pcortype = "y")
  sv <- selected_vars()$vars
  ok(!any(grepl("t2q::", sv)) && all(c("GENE01", "GENE02") %in% sv), "(v) selected_vars holds source names only")
  ## (vi) the plotted table holds the source column
  tb <- fun_table1(sanitize_t2_input(list(x = tx, y = ty, size = tok, cohort = "all"), b), ctx = t2_plot_ctx(b))
  ok(all(c("GENE01", "GENE02") %in% names(tb)) && !any(grepl("t2q::", names(tb))), "(vi) the table download has the source columns, not tokens")
  session$setInputs(pcortype = "none", x = "cohort", y = "GENE01", size = "", condition = character(0))

  session$setInputs(tabs = "analysis", color = "", facet = character(0))      # back to the Analysis tab for (g)

  ## ---- (s) Select picks propagate into the Analysis menus (PUBLISH-UNIFY step 7, spec 9b) ----
  tte1 <- tte_names(b)[1]
  tk1 <- t2_quant_token("GENE01", 3)
  sent <- list()
  session$setInputs(tabs = "analysis", x = "GENE01", quant_chip_x = "3", color = "cohort", y = "GENE02", size = "",
                    facet = character(0), condition = character(0))
  session$setInputs(x = tk1)
  sp7 <- select_picks()
  tk2 <- t2_quant_token("GENE02", 3)       # y = a bare numeric: tokenized with the default k = 3
  ok(identical(sp7$groupings$value, c(tk1, tk2, "cohort")) && identical(sp7$vars, c("GENE01", "GENE02", "cohort")),
     "(s) select_picks: token + categorical (+ the y gene at k = 3) as groupings, source names + categorical as vars, in pick order")
  gm <- analysis_group_menu()
  nsp <- gm[!startsWith(gm$value, "t2split::"), ]
  ok(identical(nsp$value[1:3], c(tk1, tk2, "cohort")) && grepl("(tertiles)", nsp$label[1], fixed = TRUE) && grepl(" - from Select$", nsp$label[1]) &&
       identical(nsp$label[3], "cohort - from Select") && sum(gm$value == "cohort") == 1 && sum(gm$value == tk1) == 1,
     "(s) group menu: the token row is added and the categorical row moved to the front, labelled from Select, no duplicates")
  ok(nrow(gm) == length(b$mygenesplus) + 2 + sum(startsWith(gm$value, "t2split::")) && length(attr(gm, "names_lower")) == nrow(gm),
     "(s) group menu: exactly one extra row, names_lower stays aligned")
  vm <- sent$analysis_var$choices
  ok(identical(vm$value[1:3], c("GENE01", "GENE02", "cohort")) && all(grepl(" - from Select$", vm$label[1:3])) &&
       sum(vm$value == "GENE01") == 1 && !any(grepl("t2q::", vm$value)) && length(attr(vm, "names_lower")) == nrow(vm),
     "(s) var menu: the source names are moved to the front, labelled, not duplicated")
  ok(identical(sent$analysis_var$selected, "GENE01") || nzchar(sent$analysis_var$selected %||% ""), "(s) var menu: a default is selected")
  ## a run through the propagated token equals the direct call
  session$setInputs(analysis_group = tk1, analysis_var = "GENE02", analysis_means = FALSE); run()
  rp <- analysis_result()
  gd <- t2_group_quantized(g1, all60, 3)
  ok(identical(rp$res$test$p, t2_group_test(g2, gd$grp, "num")$test$p) && identical(rp$label, t2_quant_label("GENE01", 3)),
     "(s) a run via the propagated token equals the direct t2_group_test on t2_group_quantized")
  ## default selection: an invalid current variable falls to the first select-pick var; a valid one stays
  sent <- list(); session$setInputs(analysis_var = "no_such_var", size = "GENE03")      # a Select change rebuilds the menu
  ok(identical(sent$analysis_var$selected, "GENE01"), "(s) an invalid current variable defaults to the first select-pick var")
  sent <- list(); session$setInputs(analysis_var = "GENE03", size = "")
  ok(is.null(sent$analysis_var) || identical(sent$analysis_var$selected, "GENE03"), "(s) a valid current variable is kept")
  ## a tte endpoint picked as x: a test variable only
  session$setInputs(x = tte1, color = "", y = "")
  sp8 <- select_picks()
  ok(tte1 %in% sp8$vars && !(tte1 %in% sp8$groupings$value) && !any(grepl(paste0("^t2q::[0-9]::", tte1, "$"), analysis_group_menu()$value)) &&
       !any(grepl("from Select", analysis_group_menu()$label)),
     "(s) an x tte endpoint is a var row only, never a grouping row")
  ok(grepl(" - from Select$", sent$analysis_var$choices$label[match(tte1, sent$analysis_var$choices$value)]), "(s) the tte endpoint is fronted in the var menu")
  ## dropped picks do not appear
  session$setInputs(x = "t2q::3::NOPE", color = "t2q::9::GENE01", y = "GENE02'; DROP", size = "")
  sp9 <- select_picks()
  ok(length(sp9$groupings$value) == 0 && !any(grepl("NOPE|DROP|t2q::9", c(sp9$vars, analysis_group_menu()$value))),
     "(s) hostile / invalid picks the sanitizer drops never reach the menus")
  session$setInputs(x = "cohort", y = "GENE01", color = "", size = "")

  ## ---- (p) Publish the Analysis result (PUBLISH-UNIFY step 5) ----
  session$setInputs(analysis_group = "cohort", analysis_var = "GENE01", analysis_means = FALSE); run()
  r5 <- analysis_result()
  session$setInputs(tabs = "publish", pub_what = "plot")
  session$setInputs(pub_what = "analysis", pub_source = TRUE, pub_show_caption = TRUE)
  sp <- pub_spec()
  ok(!is.null(sp) && identical(sp$kind, "analysis") && is.null(sp$refusal), "(p) pub_what = analysis: pub_spec() is an analysis spec")
  pp <- pub_draw(sp)
  cap <- pp$labels$caption
  ok(inherits(pp, "ggplot") && is.character(cap), "(p) pub_draw returns a ggplot with a caption")
  ok(grepl(r5$label, gsub("\n", " ", cap), fixed = TRUE) || grepl(r5$label, cap, fixed = TRUE), "(p) the caption names the grouping")
  ok(grepl("universe n=", cap, fixed = TRUE), "(p) the caption has 'universe n='")
  ok(grepl(gsub("\n", " ", r5$res$test$method[1]), gsub("\\s+", " ", cap), fixed = TRUE) || grepl(r5$res$test$method[1], cap, fixed = TRUE),
     "(p) the caption names the method")
  ok(grepl("p = ", cap, fixed = TRUE), "(p) the caption has 'p = '")
  ok(grepl("Maintained filters", cap, fixed = TRUE), "(p) the caption has the maintained filters")
  ok(grepl(substr(T2_CITATION, 1, 30), gsub("\n", " ", cap), fixed = TRUE), "(p) the caption carries the citation")
  session$setInputs(pub_source = FALSE)
  c2 <- pub_draw(pub_spec())$labels$caption
  ok(!grepl(substr(T2_CITATION, 1, 30), gsub("\n", " ", c2 %||% ""), fixed = TRUE), "(p) pub_source = FALSE drops the citation")
  session$setInputs(pub_source = TRUE, pub_show_caption = FALSE)
  c3 <- pub_draw(pub_spec())$labels$caption %||% ""
  ok(!grepl("universe n=", c3, fixed = TRUE) && !grepl("p = ", c3, fixed = TRUE), "(p) pub_show_caption = FALSE drops the stats sentences")
  session$setInputs(pub_show_caption = TRUE)
  fn <- t2_figure_filename(NULL, pub_fig(), analysis = list(var = r5$a$var, label = r5$label))
  ok(grepl("^T2_analysis_", fn), sprintf("(p) the 3-arg filename: %s", fn))
  ## the two stats .txt handlers
  f1 <- tempfile(); f2 <- tempfile()
  t1 <- output$analysis_stats_txt; t2 <- output$pub_an_stats
  ok(!is.null(t1) && !is.null(t2), "(p) both .txt downloads produce a file")
  l1 <- readLines(t1); l2 <- readLines(t2)
  ok(identical(l1[1], l2[1]) && grepl("^# T2 analysis: DEMO", l1[1]), "(p) the two .txt downloads have the same first line")
  ## a dataset guard
  an_snap(modifyList(an_snap(), list(dataset = "OTHER")))
  sg <- pub_spec()
  ok(identical(sg$kind, "analysis") && grepl("made on OTHER", sg$refusal %||% ""), "(p) a snapshot from another dataset is refused")
  ## no snapshot
  an_snap(NULL)
  ok(is.null(pub_spec()), "(p) pub_what = analysis with no comparison: pub_spec() is NULL")
  ok(!is.na(msg(output$pub_an_stats)), "(p) no snapshot: the txt download refuses ('run a comparison first')")
  session$setInputs(pub_what = "plot")
  session$setInputs(tabs = "analysis", pub_what = "plot")
  run(); ok(!is.null(an_snap()), "(p) Compare refills the snapshot")

  ## ---- (g) with an active Thanos filter ----
  set1(paste0(t2_thanos_id("DEMO"), "-vars"), "GENE01")
  med <- round(median(g1), 2); hi <- round(max(g1), 2) - 0.01
  set1(th_in("DEMO", "filter", "GENE01"), c(med, hi))
  fr <- isolate(h$th$filters())$GENE01; med <- fr[1]; hi <- fr[2]       # the range Thanos actually holds
  menu <- analysis_group_menu()
  ok("t2split::GENE01" %in% menu$value && !("t2split::*" %in% menu$value) && any(grepl("^Split: GENE01", menu$label)),
     "(g) the filter split is offered (labelled by the filter), the whole-filter split is not with one filter")
  inr <- !is.na(g1) & g1 >= med & g1 <= hi
  session$setInputs(analysis_group = "t2split::GENE01", analysis_var = "GENE02", analysis_means = FALSE); run()
  rg <- analysis_result()
  gs <- t2_group_from_streams(list(selected = which(inr | is.na(g1)), excluded = which(!inr & !is.na(g1))), 60)
  ok(identical(rg$res$test$p, t2_group_test(g2, gs$grp, "num")$test$p) && identical(levels(rg$g$grp), c("Selected", "Excluded")),
     sprintf("(g) the filter split runs: Selected %d / Excluded %d, p equals the direct call", sum(rg$g$grp == "Selected", na.rm = TRUE), sum(rg$g$grp == "Excluded", na.rm = TRUE)))
  fs <- filter_state(b)
  loo <- an_grouping(b, h, list(kind = "split_loo", col = "GENE01"), fs)$g
  whole <- an_grouping(b, h, list(kind = "split_whole"), fs)$g
  ok(identical(loo$grp, whole$grp), "(g) watchlist 10: whole-filter split == leave-one-out split with exactly one active filter")
  ok(loo$n_universe == sum(fs$base), "(g) the leave-one-out universe is the Select-tab base (one filter)")
  ## two filters: the whole-filter split appears; the quantile universe keeps the filters
  set1(paste0(t2_thanos_id("DEMO"), "-vars"), c("GENE01", "cohort"))
  lev <- sort(unique(na.omit(as.character(cohort))))
  set1(th_in("DEMO", "filter", "cohort"), lev[1])
  set1(th_in("DEMO", "na", "cohort"), FALSE)
  menu2 <- analysis_group_menu()
  ok("t2split::*" %in% menu2$value && "t2split::cohort" %in% menu2$value, "(g) with two filters the whole-filter split is offered too")
  session$setInputs(analysis_group = "t2split::*", analysis_var = "GENE02"); run()
  rw <- analysis_result()
  ok(rw$g$n_universe == sum(filter_state(b)$base) && sum(rw$g$grp == "Selected", na.rm = TRUE) == sum(filter_state(b)$mask),
     "(g) whole-filter split: Selected = the filter mask, universe = base")
  session$setInputs(analysis_group = "GENE02", analysis_quant_k = 2); run()
  ok(analysis_result()$g$n_universe == sum(filter_state(b)$mask), "(g) a quantized grouping keeps every filter (universe = mask)")
  session$setInputs(analysis_group = "t2split::cohort"); scr()
  scf <- screen_result()$table
  ok(is.data.frame(scf) && nrow(scf) > 5, "(g) the screen runs under filters")
  ok(!("cohort" %in% scf$variable), "(g) the screen leaves out the split column")
  session$setInputs(analysis_group = "GENE02", analysis_quant_k = 2); scr()
  scq <- screen_result()$table
  ok("cohort" %in% scq$variable && all(grepl("^\\[filtered\\]", scq$note[scq$variable == "cohort"])) &&
     !any(grepl("^\\[filtered\\]", scq$note[scq$variable != "cohort"])),
     "(g) a variable in another active filter (cohort) is flagged [filtered]; the others are not")

})
finish("test_app_analysis")
