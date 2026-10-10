## test_app_browser.R — the parts of the tabbed UI / Filter tab that only exist
## in a real browser: tab switching, Thanos panels being inserted into the page,
## the selectize round trip that pushes Select-tab variables into the Filter
## tab, and the per-dataset panel sets. Complements test_app_thanos.R (which
## checks the data path headless).
##
## Needs shinytest2 + a Chrome/Chromium binary:
##   CHROMOTE_CHROME=/path/to/chrome Rscript test_app_browser.R [screenshot_dir]
## Skips (exit 0) when no browser is available.
suppressMessages({ library(shiny); library(shinytest2) })

ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")
if (is.null(tryCatch(chromote::find_chrome(), error = function(e) NULL))) {
  cat("SKIP: no Chrome/Chromium found (set CHROMOTE_CHROME)\n"); quit(status = 0)
}
chromote::set_chrome_args(c("--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"))
shot_dir <- commandArgs(trailingOnly = TRUE)[1]
shot <- function(name) {
  if (is.na(shot_dir)) return(invisible())
  app$get_screenshot(file.path(shot_dir, paste0(name, ".png")))
}

app <- AppDriver$new(".", name = "t2-thanos", load_timeout = 180000, timeout = 120000,
                     height = 1100, width = 1500, wait = TRUE)
on.exit(app$stop(), add = TRUE)
settle <- function(ms = 1500) { Sys.sleep(ms / 1000); app$wait_for_idle(500, timeout = 120000) }
js <- function(code) app$get_js(code)
n_panels <- function(ds) js(sprintf(
  "document.querySelectorAll('#th_%s-panels > .thanos-panel').length", ds))
visible <- function(sel) js(sprintf(
  "(function(){var e=document.querySelector(\"%s\"); return !!e && e.offsetParent !== null;})()", sel))

## ---- start-up: Select tab, defaults populated ----
settle(3000)
ok(identical(app$get_value(input = "tabs"), "select"), "app opens on the Select tab")
ok(identical(app$get_value(input = "dataset"), "TCGA"), "TCGA is the default dataset")
x0 <- app$get_value(input = "x"); y0 <- app$get_value(input = "y"); c0 <- app$get_value(input = "color")
cat("    defaults: x =", x0, " y =", y0, " color =", c0, "\n")
ok(visible("#plot_btn") && !visible("#main_plot"), "Select controls visible, plot hidden")
shot("1_select")

## ---- the Select tab's variables were pushed into the Filter tab ----
want0 <- unique(c(x0, y0, c0))
vars <- app$get_value(input = "th_TCGA-vars")
cat("    Filter columns:", paste(vars, collapse = ", "), "\n")
ok(setequal(vars, want0), "default X / Y / color arrive as Filter columns (server-side selectize round trip)")
ok(n_panels("TCGA") == length(want0), "one Thanos panel per pushed variable is in the page")

## ---- Filter tab: histograms draw, universe count shown ----
app$set_inputs(tabs = "filter"); settle()
ok(visible("#th_TCGA-panels") && !visible("#th_DEMO-panels"),
   "Filter tab shows TCGA's panel set only")
h <- app$get_value(output = "th_TCGA-plot_CD8A")
ok(is.list(h) && nzchar(h$src %||% ""), "CD8A histogram rendered on first visit to the tab")
cnt0 <- app$get_value(output = "filter_count")
cat("    ", cnt0, "\n")
ok(grepl("12,804 of 12,804", cnt0), "count shows the full universe before filtering")
shot("2_filter_initial")

## ---- move the CD8A slider: count drops, plot NOT redrawn ----
rng <- js("(function(){var s=$('#th_TCGA-filter_CD8A').data('ionRangeSlider'); return [s.result.min, s.result.max];})()")
lo <- unlist(rng)[1] + 0.55 * diff(unlist(rng)); hi <- unlist(rng)[1] + 0.85 * diff(unlist(rng))
app$set_inputs(`th_TCGA-filter_CD8A` = c(lo, hi)); settle()
cnt1 <- app$get_value(output = "filter_count")
cat("    ", cnt1, "\n")
n1 <- as.numeric(gsub(",", "", sub(" of.*", "", cnt1)))
ok(n1 > 0 && n1 < 12804, "slider filter reduces the selected count")
flt <- app$get_value(input = "th_TCGA-filter_CD8A")

## ---- Cohort on the Select tab narrows the Filter tab's universe, filter kept ----
app$run_js("Shiny.setInputValue('preset_excl', ['Tumor samples only'])"); settle()
cnt2 <- app$get_value(output = "filter_count")
cat("    ", cnt2, "\n")
ok(grepl("of 11,329", cnt2), "'Tumor samples only' shrinks the universe shown on the Filter tab")
ok(isTRUE(all.equal(app$get_value(input = "th_TCGA-filter_CD8A"), flt)),
   "the slider setting is untouched by the universe change")
app$run_js("Shiny.setInputValue('preset_excl', [])"); settle()

## ---- a NEW Select-tab variable is added without wiping existing filters ----
app$run_js("Shiny.setInputValue('size', 'FOXP3')"); settle(2500)
vars2 <- app$get_value(input = "th_TCGA-vars")
cat("    Filter columns:", paste(vars2, collapse = ", "), "\n")
ok(setequal(vars2, c(want0, "FOXP3")), "new variable (far down the 135k list) is added to Filter columns")
ok(n_panels("TCGA") == length(want0) + 1, "its panel is inserted; the others are still there")
ok(isTRUE(all.equal(app$get_value(input = "th_TCGA-filter_CD8A"), flt)),
   "existing CD8A slider filter survived the selectize reload")
ok(identical(app$get_value(output = "filter_count"), cnt1), "selected count unchanged by adding a column")
shot("3_filter_active")

## ---- a column added by hand in the Filter tab, with an id needing encoding ----
app$run_js("(function(){var s=$('#th_TCGA-vars')[0].selectize; s.addOption({value:'TP53.mut',label:'TP53.mut'}); s.addItem('TP53.mut');})()")
settle(2500)
ok("TP53.mut" %in% app$get_value(input = "th_TCGA-vars") && n_panels("TCGA") == length(want0) + 2,
   "user-added column 'TP53.mut' gets a panel")
ok(js("!!document.getElementById('th_TCGA-panel_TP53-2Emut')"), "its element id is the encoded one")

## ---- Plot button on the Filter tab: jumps to Plot, draws, reports the filter ----
app$click("plot_btn3"); settle(4000)
ok(identical(app$get_value(input = "tabs"), "plot"), "Filter-tab Plot button switches to the Plot tab")
p <- app$get_value(output = "main_plot")
ok(is.list(p) && nzchar(p$src %||% ""), "main plot rendered")
st <- app$get_value(output = "filter_status")
cat("    ", st, "\n")
ok(grepl("samples pass", st) && grepl("CD8A in \\[", st), "the active filter is shown above the plot")
ok(grepl(format(n1, big.mark = ""), gsub(",", "", st), fixed = TRUE), "its sample count matches the Filter tab")
shot("4_plot")

## ---- the other two Plot buttons also land on the Plot tab ----
app$set_inputs(tabs = "appearance"); settle(500)
ok(visible("#plot_btn2") && visible("#surv_max_days") && !visible("#plot_btn"),
   "Appearance tab holds the fiddly options")
shot("5_appearance")
ok(js("document.querySelectorAll('.gg-name').length") >= 12,
   "Appearance settings carry their ggplot name underneath")
ok(identical(app$get_value(input = "title_size"), "16") && identical(app$get_value(input = "plot_height"), "700"),
   "menus show real values (title 16 pt, plot 700 px)")
ok(js("document.querySelector('#main_plot img').height") == 700, "the plot was drawn 700 px tall")

## ---- the searchable ggplot settings ----
pick <- function(ids) {
  app$run_js(sprintf("$('#tweak_pick')[0].selectize.setValue(%s)", jsonlite::toJSON(ids)))
  settle(1500)
}
ok(js("Object.keys($('#tweak_pick')[0].selectize.options).length") > 300,
   "the search box holds every registered ggplot setting")
pick(c("theme|axis.text.x|angle", "point.shape", "labs.title"))
ok(identical(app$get_value(input = "tw_theme_axis_text_x_angle"), "90") &&
   identical(app$get_value(input = "tw_point_shape"), "19") &&
   identical(app$get_value(input = "tw_labs_title"), ""),
   "picked settings appear as inputs, filled with their defaults")
app$set_inputs(tw_theme_axis_text_x_angle = "45", tw_labs_title = "A custom title", plot_height = "500",
               legend_size = "0")
## a typed number that is not on the menu
app$run_js("(function(){var s=$('#tw_theme_axis_text_x_angle')[0].selectize; s.createItem('33');})()")
settle(800)
ok(identical(app$get_value(input = "tw_theme_axis_text_x_angle"), "33"), "a typed number is accepted by the widget")
pick(c("theme|axis.text.x|angle", "point.shape", "labs.title", "theme|legend.position"))
ok(identical(app$get_value(input = "tw_theme_axis_text_x_angle"), "33") &&
   identical(app$get_value(input = "tw_labs_title"), "A custom title") &&
   identical(app$get_value(input = "tw_theme_legend_position"), "right"),
   "adding another setting keeps the values already entered")
shot("5b_appearance_tweaks")
app$click("plot_btn2"); settle(4000)
ok(identical(app$get_value(input = "tabs"), "plot"), "Appearance-tab Plot button switches to the Plot tab")
ok(js("document.querySelector('#main_plot img').height") == 500, "Plot height setting resizes the plot (500 px)")
shot("5c_plot_tweaked")
pick(character(0))
app$set_inputs(plot_height = "700", legend_size = "11")
app$set_inputs(tabs = "select"); settle(500)
app$click("plot_btn"); settle(4000)
ok(identical(app$get_value(input = "tabs"), "plot"), "Select-tab Plot button switches to the Plot tab")

## ---- Publish tab: a figure of a real size, live preview, download ----
img <- function() js("(function(){var i=document.querySelector('#pub_preview img'); return i ? [i.naturalWidth, i.naturalHeight, i.clientWidth, i.clientHeight] : null;})()")
app$set_inputs(tabs = "publish"); settle(6000)
i0 <- unlist(img())
cat("    preview image:", paste(i0, collapse = " "), "|", app$get_value(output = "pub_readout"), "\n")
ok(length(i0) == 4 && i0[1] == 1050 && i0[2] == 960,
   "the preview is the default figure itself: 3.5 x 3.2 in at 300 dpi = 1050 x 960 px")
ok(grepl("3.50 x 3.20 in", app$get_value(output = "pub_readout")) && grepl("1,050 x 960 pixels", app$get_value(output = "pub_readout")),
   "the readout states size, resolution and pixels")
ok(identical(app$get_value(input = "pub_title_size"), "8") && identical(app$get_value(input = "pub_axis_text_size"), "6") &&
   identical(app$get_value(input = "title_size"), "16"),
   "the figure has its own print-scale sizes; the Appearance tab's are untouched")
ok(visible("#t2_citation") && grepl("Nathan O. Siemers", js("document.getElementById('t2_citation').innerText")),
   "the citation is shown")
shot("8_publish")
## a preset fills in size, resolution and slide-scale sizes
app$set_inputs(pub_preset = "slide"); settle(6000)
i1 <- unlist(img())
ok(identical(app$get_value(input = "pub_title_size"), "24") && app$get_value(input = "pub_width") == 13.33 &&
   identical(app$get_value(input = "pub_dpi"), "150"),
   "choosing the slide preset fills in 13.33 x 7.5 in, 150 dpi and slide-scale text")
ok(abs(i1[1] / i1[2] - 13.33 / 7.5) < 0.01 && i1[3] <= 1100, "the preview redraws at the new shape, fitted to the window")
## custom size + zoom modes
app$set_inputs(pub_preset = "full_half"); settle(5000)
app$set_inputs(pub_dpi = "600", pub_format = "tiff"); settle(5000)
i2 <- unlist(img())
ok(i2[1] <= 1600 && abs(i2[1] / i2[2] - 7 / 4.75) < 0.01 && grepl("4,200 x 2,850 pixels", app$get_value(output = "pub_readout")),
   "a 600 dpi figure previews with fewer pixels (same shape); the readout shows the real 4,200 x 2,850")
app$set_inputs(pub_zoom = "pixels"); settle(6000)
i3 <- unlist(img())
ok(i3[1] == 4200 && i3[2] == 2850, "'Pixel for pixel' shows the full-resolution image")
app$set_inputs(pub_zoom = "print"); settle(5000)
ok(abs(unlist(img())[3] - 7 * 96) <= 2, "'Print size' shows it 7 CSS inches wide")
app$set_inputs(pub_zoom = "fit")
## source line off -> citation reminder
app$set_inputs(pub_source = FALSE); settle(4000)
ok(grepl("removed the source line", js("document.querySelector('.t2-cite').innerText")),
   "removing the source line brings up the citation reminder")
shot("8b_publish_full")
## the Publish tab's own ggplot settings, with the preset's default shown
app$run_js("$('#pub_tweak_pick')[0].selectize.setValue(['theme|legend.key.size','theme|legend.position'])"); settle(2000)
ok(identical(app$get_value(input = "pub_tw_theme_legend_key_size"), "8") &&
   identical(app$get_value(input = "pub_tw_theme_legend_position"), "right"),
   "the figure's own ggplot settings appear with the figure defaults (8 pt legend keys)")
## download = the full-resolution file, as specified
app$set_inputs(pub_preset = "half_third"); settle(5000)
app$set_inputs(pub_format = "png", pub_source = TRUE); settle(4000)
dl <- app$get_download("pub_download")
di <- dim(png::readPNG(dl))
cat("    downloaded:", basename(dl), paste(di[2:1], collapse = " x "), "px\n")
ok(di[2] == 1050 && di[1] == 960, "Plot: the downloaded PNG is 1050 x 960 px (3.5 x 3.2 in at 300 dpi)")
app$set_inputs(pub_format = "pdf"); settle(3000)
dlp <- app$get_download("pub_download")
ok(identical(rawToChar(readBin(dlp, "raw", 5)), "%PDF-"), "Plot: PDF download works")
app$run_js("$('#pub_tweak_pick')[0].selectize.setValue([])")
app$set_inputs(pub_format = "png")

## ---- About tab ----
app$set_inputs(tabs = "about"); settle(1500)
ok(js("document.querySelectorAll('#datatypes table tbody tr').length") > 5, "About tab shows the data-types table")
shot("6_about")

## ---- dataset switch: DEMO gets its own (empty of TCGA fields) panel set ----
app$set_inputs(tabs = "select"); settle(500)
app$set_inputs(dataset = "DEMO"); settle(4000)
dv <- app$get_value(input = "th_DEMO-vars")
cat("    DEMO x =", app$get_value(input = "x"), " y =", app$get_value(input = "y"),
    " | DEMO Filter columns:", paste(dv, collapse = ", "), "\n")
ok(length(dv) > 0 && !any(c("CD8A", "FOXP3", "TP53.mut", "sample_type") %in% dv),
   "DEMO's Filter columns are DEMO fields only (no TCGA carry-over)")
app$set_inputs(tabs = "filter"); settle()
ok(visible("#th_DEMO-panels") && !visible("#th_TCGA-panels"), "Filter tab now shows DEMO's panel set")
ok(grepl("60 of 60", app$get_value(output = "filter_count")), "DEMO universe is its 60 samples, unfiltered")
shot("7_filter_demo")
app$click("plot_btn3"); settle(4000)
ok(grepl("no additional filtering", app$get_value(output = "filter_status")),
   "DEMO plot is not affected by TCGA's filters")

## ---- and back: TCGA's filters are still there ----
app$set_inputs(tabs = "select"); settle(500)
app$set_inputs(dataset = "TCGA"); settle(4000)
app$set_inputs(tabs = "filter"); settle()
ok(visible("#th_TCGA-panels") && !visible("#th_DEMO-panels"), "back on TCGA: its panel set is shown again")
ok(isTRUE(all.equal(app$get_value(input = "th_TCGA-filter_CD8A"), flt)), "TCGA's CD8A filter was kept")

logs <- app$get_logs()
errs <- logs[logs$level == "error" | grepl("Error", logs$message), ]
ok(nrow(errs) == 0, "no errors in the browser console or R log")
if (nrow(errs)) print(errs)
cat("== browser test done ==\n")
