## test_browser_suite.R — the Shiny app walked through in a real (headless) browser,
## with a screenshot of every step, like the iPhone app's UI suite: the Select tab and
## its ready-made subsets, box / scatter / survival / count plots, a part of a collection
## as data source, the Filter tab, Publish, About. Checks are of WORKING flows (an image
## rendered, a count changed, a text appeared); whether a screen looks right is judged
## from the pictures.
##
##   CHROMOTE_CHROME=<chrome-headless-shell> Rscript test_browser_suite.R [screenshot_dir]
##   (T2_API_URL names the service the app reads from (required: no file mode); T2_CONTACT_URL to show the contact form — it is never submitted here)
## Against a RUNNING site instead of the local code:  T2_SITE_URL=https://www.fiveprime.org/T2T/
## (then inputs are set but server values are read from the page only).
suppressMessages({ library(shiny); library(shinytest2) })
ok <- function(cond, msg) { cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n"); if (!isTRUE(cond)) FAILS <<- FAILS + 1 }
FAILS <- 0
if (is.null(tryCatch(chromote::find_chrome(), error = function(e) NULL))) {
  cat("SKIP: no Chrome/Chromium found (set CHROMOTE_CHROME)\n"); quit(status = 0)
}
chromote::set_chrome_args(c("--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"))
shot_dir <- commandArgs(trailingOnly = TRUE)[1]
if (!is.na(shot_dir)) dir.create(shot_dir, showWarnings = FALSE, recursive = TRUE)
site <- Sys.getenv("T2_SITE_URL", "")
app <- if (nzchar(site)) {
  AppDriver$new(site, name = "t2-site", load_timeout = 180000, timeout = 120000, height = 1000, width = 1400)
} else {
  AppDriver$new(".", name = "t2-suite", load_timeout = 180000, timeout = 120000, height = 1000, width = 1400, wait = TRUE)
}
on.exit(app$stop(), add = TRUE)
LIVE <- nzchar(site)      # a production site has no Shiny test mode: read everything from the page
shot <- function(name) if (!is.na(shot_dir)) app$get_screenshot(file.path(shot_dir, paste0(name, ".png")))
## an input's current value: from the server in test mode, from the widget on a live site
input_value <- function(id) {
  if (!LIVE) return(app$get_value(input = id))
  v <- app$get_js(sprintf("(function(){var e=$('#%s'); if(e.length && e[0].selectize) return e[0].selectize.getValue();
    var r=$('input[name=\"%s\"]:checked'); if(r.length) return r.map(function(){return this.value}).get();
    if(e.length) return e.val(); return null;})()", id, id))
  v <- unlist(v); if (is.null(v)) return(NULL); v[nzchar(v)]
}
## an output's text: the server's value in test mode, the rendered text on a live site
output_text <- function(id) if (LIVE) text_of(id) else app$get_value(output = id)
tab_value <- function() if (LIVE) app$get_js("$('#tabs li.active a').attr('data-value')") else app$get_value(input = "tabs")
## set inputs: through the test channel in test mode; on a live site straight into the page
## (a tab by clicking it, the rest by Shiny.setInputValue) -- set_inputs() would wait on the
## test-mode channel the site does not have
set_input <- function(...) {
  vals <- list(...)
  if (!LIVE) return(do.call(app$set_inputs, vals))
  for (id in names(vals)) {
    v <- vals[[id]]
    if (id == "tabs") {
      app$run_js(sprintf("$('#tabs a[data-value=%s]').tab('show')", jsonlite::toJSON(v, auto_unbox = TRUE)))
    } else if (id %in% c("preset_group", "preset_excl")) {
      ## radios / checkboxes: change the elements themselves and let Shiny report them, as a
      ## user would (setting the input alone leaves the boxes as they were, and a redrawn
      ## widget then reports its old ticks back, racing a "clear")
      app$run_js(sprintf("(function(){var w=%s; $('input[name=\"%s\"]').each(function(){this.checked = w.indexOf(this.value) >= 0;}).trigger('change');})()",
                         jsonlite::toJSON(as.character(v)), id))
    } else setv(id, v)
    settle(800)        # one change at a time, the server's answer in between
  }
  invisible()
}
settle <- function(ms = 1500) { Sys.sleep(ms / 1000); app$wait_for_idle(500, timeout = 120000) }
js <- function(code) app$get_js(code)
setv <- function(id, value) app$run_js(sprintf("Shiny.setInputValue(%s, %s, {priority: 'event'})", jsonlite::toJSON(id, auto_unbox = TRUE), jsonlite::toJSON(value, auto_unbox = length(value) == 1)))
text_of <- function(id) js(sprintf("(function(){var e=document.getElementById('%s'); return e ? e.innerText : '';})()", id))
img_ok <- function(id) js(sprintf("(function(){var i=document.querySelector('#%s img'); return !!i && i.naturalWidth > 100;})()", id))
choices <- function(id) unlist(js(sprintf("Array.from(document.querySelectorAll('#%s input')).map(function(e){return e.value})", id)))
plot_now <- function(btn = "plot_btn", wait = 6000) { app$click(btn); settle(wait); app$wait_for_idle(1000, timeout = 120000) }

## ---- 01 the Select tab as it opens ----
settle(3000)
ok(identical(tab_value(), "select"), "opens on the Select tab")
ok(identical(input_value("dataset"), "TCGA"), "TCGA is the default data set")
co <- input_value("cohort")
ok(length(co) == 9 && "COAD" %in% co, sprintf("opens on the nine default cohorts (%s...)", paste(head(co, 3), collapse = ", ")))
ok(setequal(choices("preset_group"), c("", "Primary tumors only", "Metastatic samples only", "Normal tissue only")),
   "the Samples radio offers TCGA's three groups and 'All samples'")
ok(setequal(choices("preset_excl"), c("Tumor samples only", "Exclude tumors of heme origin")), "two exclusions offered")
ok(grepl("sample_type", text_of("var_help")) && grepl("cohort", text_of("var_help")), "the chosen clinical variables are explained")
shot("01-select")

## ---- 02 the default plot: box plot by cohort ----
plot_now()
ok(identical(tab_value(), "plot") && img_ok("main_plot"), "Plot: the default box plot is drawn")
s <- output_text("plot_summary")
ok(grepl("Total samples after filters", s) && grepl("Samples: TCGA Pan-Cancer 2018\\.", s), "the summary names the sample choice (whole collection)")
shot("02-plot-default")

## ---- 03 ready-made subsets: a group, then an exclusion that still applies ----
set_input(tabs = "select"); settle(500)
set_input(preset_group = "Primary tumors only"); settle(1500)
ex <- choices("preset_excl")
ok(!("Tumor samples only" %in% ex) && "Exclude tumors of heme origin" %in% ex,
   "within 'Primary tumors only' the pointless exclusion disappears, heme stays")
set_input(preset_excl = "Exclude tumors of heme origin"); settle(500)
shot("03-select-presets")
plot_now()
s <- output_text("plot_summary")
ok(grepl("Samples: TCGA Pan-Cancer 2018; Primary tumors only; Exclude tumors of heme origin", s), "the plot summary names group and exclusion")
n_primary <- as.integer(sub(".*Total samples after filters: (\\d+).*", "\\1", s))
ok(n_primary > 0 && n_primary < 12804, sprintf("fewer samples than the whole collection (%d)", n_primary))
shot("04-plot-presets")

## ---- 04 a scatter plot, picked by search ----
set_input(tabs = "select"); settle(500)
set_input(preset_group = "", preset_excl = character(0)); settle(500)
setv("x", "CD8A"); setv("y", "FOXP3"); settle(1500)
plot_now()
ok(img_ok("main_plot"), "scatter plot CD8A vs FOXP3 drawn")
ok(grepl("FOXP3", output_text("plot_summary")), "summary lists the Y variable")
shot("05-plot-scatter")

## ---- 05 a part of a collection as data source: GTEx ----
set_input(tabs = "select"); settle(500)
setv("dataset", "tcgatargetgtex|GTEx"); settle(4000)
ok(identical(input_value("dataset"), "tcgatargetgtex|GTEx") || (LIVE && grepl("\u2014 GTEx", text_of("app_title"))), "switched to TCGA-TARGET-GTEx (Toil): GTEx")
ok(grepl("\u2014 GTEx", text_of("app_title")), "the page title names the part")
ok(length(choices("preset_group")) == 0 && setequal(choices("preset_excl"), c("Exclude cell lines", "Exclude tumors of heme origin")),
   "within GTEx: no groups, the two exclusions")
ok(identical(input_value("x"), "CD8A") && identical(input_value("y"), "FOXP3"), "X and Y were carried over (sticky picks)")
shot("06-select-gtex")
set_input(tabs = "filter"); settle(2500)
cnt <- output_text("filter_count")
ok(grepl("of 7,862", cnt), paste("the Filter tab's universe is the GTEx part:", cnt))
vars <- input_value("th_tcgatargetgtex_GTEx-vars")
ok(length(vars) >= 2 && !("study" %in% vars), "its panels are the picked variables; 'study' (one value in GTEx) is not one")
shot("07-filter-gtex")
set_input(tabs = "select"); settle(500)
set_input(preset_excl = "Exclude cell lines"); settle(500)
setv("x", "cohort"); settle(1000)
plot_now(wait = 8000)
s <- output_text("plot_summary")
ok(img_ok("main_plot") && grepl("Samples: GTEx; Exclude cell lines", s), "GTEx tissues without cell lines, plotted and named")
ok(as.integer(sub(".*Total samples after filters: (\\d+).*", "\\1", s)) <= 7429, "at most the 7,429 normal tissues")
shot("08-plot-gtex")

## ---- 06 back to TCGA: survival curves, then a count display ----
set_input(tabs = "select"); settle(500)
setv("dataset", "TCGA"); settle(4000)
setv("x", "OS"); setv("y", "MKI67"); settle(1500)
plot_now(wait = 8000)
ok(img_ok("main_plot") && grepl("MKI67", output_text("plot_summary")), "Kaplan-Meier plot by MKI67 tertiles drawn")
shot("09-plot-survival")
set_input(tabs = "select"); settle(500)
setv("x", "sample_type"); setv("y", "gender"); setv("color", ""); settle(1500)
plot_now()
ok(img_ok("main_plot"), "two categorical variables: the count display is drawn")
shot("10-plot-counts")

## ---- 07 Publish: the live preview ----
set_input(tabs = "select"); settle(500)
setv("x", "cohort"); setv("y", "CD8A"); setv("color", "sample_type"); settle(1500)
set_input(tabs = "publish"); settle(7000)
ok(img_ok("pub_preview") && grepl("in", output_text("pub_readout")), "Publish preview rendered with its readout")
shot("11-publish")
## a switch per text element; the citation reminder shows when the source line goes
ok(all(vapply(c("pub_show_title", "pub_show_subtitle", "pub_show_caption", "pub_source", "pub_show_axis_titles"),
              function(id) isTRUE(js(sprintf("!!document.getElementById('%s') && document.getElementById('%s').checked", id, id))), NA)),
   "Publish: a checkbox per text element, all on by default")
set_input(pub_show_title = FALSE, pub_show_axis_titles = FALSE, pub_source = FALSE); settle(5000)
ok(img_ok("pub_preview") && isTRUE(js("$('.t2-cite').text().indexOf('You have removed the source line') >= 0")),
   "Publish: title, axis titles and source line off: the figure still renders and the citation reminder shows")
shot("11b-publish-text-off")
set_input(pub_show_title = TRUE, pub_show_axis_titles = TRUE, pub_source = TRUE); settle(1000)

## ---- 07b not-detected values: only where the values answer offers them (CPTAC proteome) ----
ok(!isTRUE(js("!!document.getElementById('not_detected')")), "TCGA: no not-detected control on the Plot tab")
set_input(tabs = "select"); settle(500)
setv("dataset", "cptac"); settle(5000)
setv("x", "CLDN6"); setv("y", "CLDN6.prot"); setv("color", ""); settle(1500)
plot_now(wait = 8000)
ok(img_ok("main_plot") && isTRUE(js("!!document.getElementById('not_detected')")), "cptac CLDN6 vs CLDN6.prot: the Not-detected values control appears")
ok(setequal(choices("not_detected"), c("na", "zero", "floor")), "it offers exactly what the answer listed: Missing, Zero, Detection floor")
n0 <- as.integer(sub(".*Samples with data for both X and Y: (\\d+).*", "\\1", output_text("plot_summary")))
set_input(not_detected = "zero"); settle(8000)
s <- output_text("plot_summary")
ok(grepl("not-detected values set to 0", s) && as.integer(sub(".*Samples with data for both X and Y: (\\d+).*", "\\1", s)) > n0,
   "Zero: the plot is drawn again with more samples and the Data Summary says so")
shot("13-plot-cptac-zero")
setv("dataset", "TCGA"); settle(4000); set_input(tabs = "plot"); settle(500)
ok(!isTRUE(js("!!document.getElementById('not_detected')")), "switching to TCGA hides the control")

## ---- 08 About: data types, clinical variables, contact form ----
set_input(tabs = "about"); settle(1500)
ok(js("document.querySelectorAll('#datatypes tr').length") > 10, "the data-type table is there")
ok(js("document.querySelectorAll('#clinical_help tr').length") > 20, "the clinical variables are explained on About")
has_contact <- isTRUE(js("!!document.getElementById('contact_send')"))
ok(has_contact == nzchar(Sys.getenv("T2_CONTACT_URL", Sys.getenv("T2_API_URL", ""))), "the contact form is shown exactly when an endpoint is configured")
ok(grepl("Survival curves: choose OS, PFI, DSS or DFI as X (Kaplan-Meier by groups of Y)", text_of("about_survival_hint"), fixed = TRUE),
   "About: the survival hint names TCGA's time-to-event variables")
ok(grepl("TCGA (The Cancer Genome Atlas) and other genomic databases", js("document.body.innerText"), fixed = TRUE), "About: the T2 paragraph names TCGA and other genomic databases")
shot("12-about")

cat(sprintf("\n== browser suite done: %s ==\n", if (FAILS == 0) "ALL PASS" else paste(FAILS, "FAILED")))
quit(status = if (FAILS == 0) 0 else 1)
