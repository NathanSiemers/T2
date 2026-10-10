## test_browser_suite.R — the Shiny app walked through in a real (headless) browser,
## with a screenshot of every step, like the iPhone app's UI suite: the Select tab and
## its ready-made subsets, box / scatter / survival / count plots, a part of a collection
## as data source, the Filter tab, Publish, About. Checks are of WORKING flows (an image
## rendered, a count changed, a text appeared); whether a screen looks right is judged
## from the pictures.
##
##   CHROMOTE_CHROME=<chrome-headless-shell> Rscript test_browser_suite.R [screenshot_dir]
##   (T2_DATASETS_DIR for other database copies; T2_API_URL to run the app over the
##   service; T2_CONTACT_URL to show the contact form — it is never submitted here)
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
shot <- function(name) if (!is.na(shot_dir)) app$get_screenshot(file.path(shot_dir, paste0(name, ".png")))
settle <- function(ms = 1500) { Sys.sleep(ms / 1000); app$wait_for_idle(500, timeout = 120000) }
js <- function(code) app$get_js(code)
setv <- function(id, value) app$run_js(sprintf("Shiny.setInputValue(%s, %s, {priority: 'event'})", jsonlite::toJSON(id, auto_unbox = TRUE), jsonlite::toJSON(value, auto_unbox = length(value) == 1)))
text_of <- function(id) js(sprintf("(function(){var e=document.getElementById('%s'); return e ? e.innerText : '';})()", id))
img_ok <- function(id) js(sprintf("(function(){var i=document.querySelector('#%s img'); return !!i && i.naturalWidth > 100;})()", id))
choices <- function(id) unlist(js(sprintf("Array.from(document.querySelectorAll('#%s input')).map(function(e){return e.value})", id)))
plot_now <- function(btn = "plot_btn", wait = 6000) { app$click(btn); settle(wait); app$wait_for_idle(1000, timeout = 120000) }

## ---- 01 the Select tab as it opens ----
settle(3000)
ok(identical(app$get_value(input = "tabs"), "select"), "opens on the Select tab")
ok(identical(app$get_value(input = "dataset"), "TCGA"), "TCGA is the default data set")
co <- app$get_value(input = "cohort")
ok(length(co) == 9 && "COAD" %in% co, sprintf("opens on the nine default cohorts (%s...)", paste(head(co, 3), collapse = ", ")))
ok(setequal(choices("preset_group"), c("", "Primary tumors only", "Metastatic samples only", "Normal tissue only")),
   "the Samples radio offers TCGA's three groups and 'All samples'")
ok(setequal(choices("preset_excl"), c("Tumor samples only", "Exclude tumors of heme origin")), "two exclusions offered")
ok(grepl("sample_type", text_of("var_help")) && grepl("cohort", text_of("var_help")), "the chosen clinical variables are explained")
shot("01-select")

## ---- 02 the default plot: box plot by cohort ----
plot_now()
ok(identical(app$get_value(input = "tabs"), "plot") && img_ok("main_plot"), "Plot: the default box plot is drawn")
s <- app$get_value(output = "plot_summary")
ok(grepl("Total samples after filters", s) && grepl("Samples: TCGA Pan-Cancer 2018\\.", s), "the summary names the sample choice (whole collection)")
shot("02-plot-default")

## ---- 03 ready-made subsets: a group, then an exclusion that still applies ----
app$set_inputs(tabs = "select"); settle(500)
app$set_inputs(preset_group = "Primary tumors only"); settle(1500)
ex <- choices("preset_excl")
ok(!("Tumor samples only" %in% ex) && "Exclude tumors of heme origin" %in% ex,
   "within 'Primary tumors only' the pointless exclusion disappears, heme stays")
app$set_inputs(preset_excl = "Exclude tumors of heme origin"); settle(500)
shot("03-select-presets")
plot_now()
s <- app$get_value(output = "plot_summary")
ok(grepl("Samples: TCGA Pan-Cancer 2018; Primary tumors only; Exclude tumors of heme origin", s), "the plot summary names group and exclusion")
n_primary <- as.integer(sub(".*Total samples after filters: (\\d+).*", "\\1", s))
ok(n_primary > 0 && n_primary < 12804, sprintf("fewer samples than the whole collection (%d)", n_primary))
shot("04-plot-presets")

## ---- 04 a scatter plot, picked by search ----
app$set_inputs(tabs = "select"); settle(500)
app$set_inputs(preset_group = "", preset_excl = character(0)); settle(500)
setv("x", "CD8A"); setv("y", "FOXP3"); settle(1500)
plot_now()
ok(img_ok("main_plot"), "scatter plot CD8A vs FOXP3 drawn")
ok(grepl("FOXP3", app$get_value(output = "plot_summary")), "summary lists the Y variable")
shot("05-plot-scatter")

## ---- 05 a part of a collection as data source: GTEx ----
app$set_inputs(tabs = "select"); settle(500)
setv("dataset", "tcgatargetgtex|GTEx"); settle(4000)
ok(identical(app$get_value(input = "dataset"), "tcgatargetgtex|GTEx"), "switched to TCGA-TARGET-GTEx (Toil): GTEx")
ok(grepl("\u2014 GTEx", text_of("app_title")), "the page title names the part")
ok(length(choices("preset_group")) == 0 && setequal(choices("preset_excl"), c("Exclude cell lines", "Exclude tumors of heme origin")),
   "within GTEx: no groups, the two exclusions")
ok(identical(app$get_value(input = "x"), "CD8A") && identical(app$get_value(input = "y"), "FOXP3"), "X and Y were carried over (sticky picks)")
shot("06-select-gtex")
app$set_inputs(tabs = "filter"); settle(2500)
cnt <- app$get_value(output = "filter_count")
ok(grepl("of 7,862", cnt), paste("the Filter tab's universe is the GTEx part:", cnt))
vars <- app$get_value(input = "th_tcgatargetgtex_GTEx-vars")
ok(length(vars) >= 2 && !("study" %in% vars), "its panels are the picked variables; 'study' (one value in GTEx) is not one")
shot("07-filter-gtex")
app$set_inputs(tabs = "select"); settle(500)
app$set_inputs(preset_excl = "Exclude cell lines"); settle(500)
setv("x", "cohort"); settle(1000)
plot_now(wait = 8000)
s <- app$get_value(output = "plot_summary")
ok(img_ok("main_plot") && grepl("Samples: GTEx; Exclude cell lines", s), "GTEx tissues without cell lines, plotted and named")
ok(as.integer(sub(".*Total samples after filters: (\\d+).*", "\\1", s)) <= 7429, "at most the 7,429 normal tissues")
shot("08-plot-gtex")

## ---- 06 back to TCGA: survival curves, then a count display ----
app$set_inputs(tabs = "select"); settle(500)
setv("dataset", "TCGA"); settle(4000)
setv("x", "OS"); setv("y", "MKI67"); settle(1500)
plot_now(wait = 8000)
ok(img_ok("main_plot") && grepl("MKI67", app$get_value(output = "plot_summary")), "Kaplan-Meier plot by MKI67 tertiles drawn")
shot("09-plot-survival")
app$set_inputs(tabs = "select"); settle(500)
setv("x", "sample_type"); setv("y", "gender"); setv("color", ""); settle(1500)
plot_now()
ok(img_ok("main_plot"), "two categorical variables: the count display is drawn")
shot("10-plot-counts")

## ---- 07 Publish: the live preview ----
app$set_inputs(tabs = "select"); settle(500)
setv("x", "cohort"); setv("y", "CD8A"); setv("color", "sample_type"); settle(1500)
app$set_inputs(tabs = "publish"); settle(7000)
ok(img_ok("pub_preview") && grepl("in", app$get_value(output = "pub_readout")), "Publish preview rendered with its readout")
shot("11-publish")

## ---- 08 About: data types, clinical variables, contact form ----
app$set_inputs(tabs = "about"); settle(1500)
ok(js("document.querySelectorAll('#datatypes tr').length") > 10, "the data-type table is there")
ok(js("document.querySelectorAll('#clinical_help tr').length") > 20, "the clinical variables are explained on About")
has_contact <- isTRUE(js("!!document.getElementById('contact_send')"))
ok(has_contact == nzchar(Sys.getenv("T2_CONTACT_URL", Sys.getenv("T2_API_URL", ""))), "the contact form is shown exactly when an endpoint is configured")
shot("12-about")

cat(sprintf("\n== browser suite done: %s ==\n", if (FAILS == 0) "ALL PASS" else paste(FAILS, "FAILED")))
quit(status = if (FAILS == 0) 0 else 1)
