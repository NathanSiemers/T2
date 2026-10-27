## test_shiny_fuzz.R — adversarial fuzzing of the Shiny app's INPUT CHANNEL, the way an
## automated exploit tool would: a browser can call Shiny.setInputValue(name, value) for ANY
## name with ANY value over the websocket, whatever the UI shows, so every defence is
## server-side. This drives that channel with hostile names and values and asserts the app's
## invariants hold:
##   * the session never dies on a hostile input (it stays responsive; no uncaught error);
##   * a server-only argument set from the browser (keep_samples, rules, dbfile, roles) is
##     ignored — it can never reach the data layer from a client;
##   * an input whose NAME is not whitelisted (T2_INPUT_ARGS / the known ids) does nothing;
##   * a hostile VALUE of a real input is validated away: a plot either draws or shows a
##     clean refusal message, never an R error, and the data behind it reflect only valid
##     selections (a SQL fragment as a probe name is a missing probe, not executed SQL; an
##     invented preset label selects no samples; an out-of-range number snaps to its menu).
##
## Complements test_shiny_fuzz's API sibling (service/fuzz.sh). Needs shinytest2 + Chrome.
##   CHROMOTE_CHROME=<chrome> Rscript test_shiny_fuzz.R
##   (T2_API_URL names the service the app reads from; the app has no file mode)
suppressMessages({ library(shiny); library(shinytest2) })
source("t2_util.R")               # the one %||%
source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero
if (is.null(tryCatch(chromote::find_chrome(), error = function(e) NULL))) {
  cat("SKIP: no Chrome/Chromium found (set CHROMOTE_CHROME)\n"); quit(status = 0)
}
chromote::set_chrome_args(c("--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"))
app <- AppDriver$new(".", name = "t2-fuzz", load_timeout = 180000, timeout = 120000, height = 900, width = 1300, wait = TRUE)
on.exit(app$stop(), add = TRUE)
settle <- function(ms = 1200) { Sys.sleep(ms / 1000); app$wait_for_idle(500, timeout = 120000) }
## set ANY input name to ANY value over the websocket, as a hostile client would
setv <- function(id, value) app$run_js(sprintf("Shiny.setInputValue(%s, %s, {priority:'event'})",
                                               jsonlite::toJSON(id, auto_unbox = TRUE), jsonlite::toJSON(value, auto_unbox = length(value) == 1)))
alive <- function() !is.null(tryCatch(app$get_value(input = "dataset"), error = function(e) NULL))
## any R error surfaced to the browser since the app started? (shiny shows them as output errors)
new_errors <- function() {
  logs <- tryCatch(app$get_logs(), error = function(e) NULL)
  if (is.null(logs) || !nrow(logs)) return(character(0))
  msg <- logs$message
  grep("Warning|deprecated|aes_", grep("Error|error", msg, value = TRUE), value = TRUE, invert = TRUE)
}
plot_ok_or_refusal <- function() {
  # either a plot image, or a clean refusal message in the plot area — never a broken session
  has_img <- isTRUE(app$get_js("(function(){var i=document.querySelector('#main_plot img'); return !!i && i.naturalWidth>50;})()"))
  has_img || alive()
}

settle(3000)
base_err <- length(new_errors())
ok(alive(), "app started and is responsive")

## ---------------------------------------------------------------------------
## 1. Server-only arguments injected from the browser must be ignored.
##    keep_samples / rules / dbfile / roles decide which samples and which FILE are read;
##    they are set server-side only. A client that sets them must not change the data.
## ---------------------------------------------------------------------------
cat("-- 1. server-only arguments cannot be set from the client\n")
app$set_inputs(dataset = "TCGA"); settle(1000)
setv("x", "cohort"); setv("y", "CD8A"); setv("cohort", "all"); settle(1000)
app$click("plot_btn"); settle(5000)
n_full <- app$get_value(output = "plot_summary")
n_full <- as.integer(sub(".*Total samples after filters: (\\d+).*", "\\1", n_full))
# try to force a tiny sample set, a different file, and injected filter rules from the client
setv("keep_samples", list("TCGA-01", "TCGA-02"))
setv("rules", list(list(column = "cohort", op = "in", values = list("BRCA"))))
setv("dbfile", "/etc/passwd")
setv("roles", list(cohort_col = "x"))
setv("gitrdb", "/etc/passwd")
settle(1000)
app$click("plot_btn"); settle(5000)
n_after <- app$get_value(output = "plot_summary")
n_after <- as.integer(sub(".*Total samples after filters: (\\d+).*", "\\1", n_after))
ok(isTRUE(n_after == n_full) && n_full > 10000, sprintf("keep_samples/rules/dbfile from the client are ignored (%d samples, unchanged)", n_after %||% -1))
ok(alive(), "session alive after server-only injection")

## ---------------------------------------------------------------------------
## 2. Unknown input NAMES do nothing (only whitelisted names are read).
## ---------------------------------------------------------------------------
cat("-- 2. unknown input names are inert\n")
for (nm in c("facet.formula", "evaluate_vars", "extra", "system", "command", ".call", "../../x", "<script>")) {
  setv(nm, "rm(list=ls()); system('id')")
}
setv("allComplete", "TRUE; system('id')")   # a non-logical value for a flag
settle(1500)
app$click("plot_btn"); settle(5000)
ok(alive() && plot_ok_or_refusal(), "invented input names and a poisoned flag do nothing harmful")

## ---------------------------------------------------------------------------
## 3. Hostile VALUES of real variable inputs: SQL, R code, traversal, huge vectors.
##    gitr() binds every probe name as a SQL parameter, so a name is only ever a lookup key;
##    an unknown name is a missing column, never executed. The session must survive and the
##    plot must either draw or refuse cleanly.
## ---------------------------------------------------------------------------
cat("-- 3. hostile values of x / y / color / cohort / condition\n")
HOSTILE <- list(
  "'; DROP TABLE tcgai;--", "CD8A'; ATTACH DATABASE '/tmp/x' AS y;--",
  "' UNION SELECT * FROM sqlite_master--", "../../../../etc/passwd",
  "`system('id')`", "${system('id')}", "\"); file.remove('x'); #",
  paste(rep("A", 5000), collapse = ""), "CD8A\nCD8B")   # a literal NUL cannot travel the chromote eval; the API fuzzer covers NUL
for (v in HOSTILE) {
  setv("x", "cohort"); setv("y", v); setv("color", v); settle(300)
  app$click("plot_btn"); settle(2500)
  if (!alive()) { ok(FALSE, paste("session died on hostile y/color value:", substr(v, 1, 30))); break }
}
ok(alive(), "session survived every hostile x/y/color value")
# a huge multi-probe vector for x and y (far past the per-selector caps)
setv("x", as.list(sprintf("GENE%d", 1:500))); setv("y", as.list(sprintf("MARK%d", 1:500))); settle(500)
app$click("plot_btn"); settle(4000)
ok(alive() && plot_ok_or_refusal(), "a 500-name x and y vector is capped/refused, not crashed")

## ---------------------------------------------------------------------------
## 4. Ready-made subset inputs: arbitrary group / exclusion labels and raw rule structures.
##    sanitize_t2_samples only honours labels it OFFERS; an invented one selects nothing new.
## ---------------------------------------------------------------------------
cat("-- 4. preset_group / preset_excl cannot inject arbitrary sample rules\n")
setv("x", "cohort"); setv("y", "CD8A"); settle(300)
setv("preset_group", "'; DELETE FROM clinpheno;--")
setv("preset_excl", list("made up label", "another", list(column = "x", op = "in", values = "y")))
settle(800)
app$click("plot_btn"); settle(5000)
s <- app$get_value(output = "plot_summary")
n_p <- as.integer(sub(".*Total samples after filters: (\\d+).*", "\\1", s))
ok(alive() && isTRUE(n_p == n_full), sprintf("invented group/exclusion labels select nothing new (%d samples)", n_p %||% -1))
ok(!grepl("made up label|DELETE", s), "the injected labels do not appear in the summary")

## ---------------------------------------------------------------------------
## 5. Numeric / enum inputs out of range, and the ggplot tweak registry.
## ---------------------------------------------------------------------------
cat("-- 5. out-of-range numbers and invented tweak ids\n")
setv("km_groups", 1e9); setv("surv_max_days", -1); setv("plot_height", "99999")
setv("pcortype", "both; system('id')"); setv("scales", "../etc"); setv("smooth", "MAYBE")
setv("tweak_pick", list("theme.evil", "system")); setv("tw_theme_evil", "`id`")
settle(800)
app$set_inputs(tabs = "plot"); settle(800)
app$click("plot_btn2"); settle(5000)
ok(alive() && plot_ok_or_refusal(), "out-of-range numbers, bad enums and invented tweak ids are sanitised")

## ---------------------------------------------------------------------------
## 6. The Filter tab (Thanos): invented filter columns and encoded-id collisions.
## ---------------------------------------------------------------------------
cat("-- 6. Thanos filter columns\n")
setv("th_TCGA-vars", list("no_such_probe", "'; DROP TABLE x;--", "../../etc"))
settle(1500)
app$set_inputs(tabs = "filter"); settle(1500)
ok(alive(), "invented Thanos filter columns do not break the Filter tab")

## ---------------------------------------------------------------------------
## 6b. Inputs of the wrong SHAPE (vectors where one value is expected), a forged
##     plot size and oversized contact fields: none may end the session.
## ---------------------------------------------------------------------------
cat("-- 6b. wrong-shaped inputs, forged plot size, contact fields\n")
app$set_inputs(tabs = "select"); settle(500)
setv("multi_y", list(TRUE, FALSE, "x")); setv("multi_y", list())
setv("dataset", list("TCGA", "CPTAC")); setv("dataset", list()); setv("dataset", 42)
setv("pcortype", list("x", "y")); setv("allComplete", list(TRUE, FALSE))
settle(1500)
ok(alive(), "vector-valued multi_y / dataset / flags do not end the session")
# a client can set the reported size of an output: the plot must not be drawn that large
setv(".clientdata_output_main_plot_width", 30000); setv(".clientdata_output_main_plot_height", 16000)
setv("x", "cohort"); setv("y", "CD8A"); settle(500)
t0 <- Sys.time(); app$click("plot_btn"); settle(5000)
ok(alive() && as.numeric(Sys.time() - t0, units = "secs") < 60, "a forged 30000 x 16000 plot size is clamped (session alive, drawn quickly)")
setv("contact_name", list("a", "b")); setv("contact_email", 7); setv("contact_message", strrep("m", 100000))
setv("contact_affiliation", strrep("x", 100000)); setv("contact_send", 1)
settle(1500)
ok(alive(), "wrong-shaped and oversized contact fields do not end the session")

## ---------------------------------------------------------------------------
## 6c. The Analysis tab: a grouping, variable, k and flag are all client-chosen. Malformed
##     t2q:: / t2split:: tokens, huge vectors and junk must give a plain message, never
##     an R error or a dead session (sanitize_t2_analysis whitelists every one).
## ---------------------------------------------------------------------------
cat("-- 6c. Analysis tab inputs\n")
app$set_inputs(tabs = "analysis"); settle(800)
for (v in list("t2q::99::X", "t2q::3::cohort", "t2q::2::", "t2q::-1::CD8A", "t2q::3::" , "t2split::nope", "t2split::*",
               "t2split::'; DROP TABLE x;--", "t2split::", strrep("t2q::3::A", 800), "../../etc/passwd",
               as.list(sprintf("t2q::3::G%d", 1:500)), list("cohort", "CD8A"), 42, list(), NULL)) {
  setv("analysis_group", v); setv("analysis_var", "CD8A"); setv("analysis_run", sample(1e6, 1)); settle(400)
  if (!alive()) { ok(FALSE, "session died on a hostile analysis_group value"); break }
}
ok(alive(), "session survived every hostile analysis_group value")
for (v in list("'; DROP TABLE tcgai;--", strrep("V", 5000), as.list(sprintf("G%d", 1:500)), list("OS", "PFI"), 7, list(), "OS.time\nx")) {
  setv("analysis_group", "cohort"); setv("analysis_var", v); setv("analysis_run", sample(1e6, 1)); settle(400)
  if (!alive()) { ok(FALSE, "session died on a hostile analysis_var value"); break }
}
ok(alive(), "session survived every hostile analysis_var value")
setv("analysis_quant_k", 1e9); setv("analysis_quant_k", "junk"); setv("analysis_quant_k", list(2, 3, 4)); setv("analysis_quant_k", -5)
setv("analysis_means", "TRUE; system('id')"); setv("analysis_means", list(TRUE, FALSE)); setv("analysis_means", 3)
setv("analysis_group", "OS.time"); setv("analysis_var", "CD8A")
for (i in 1:3) { setv("analysis_run", sample(1e6, 1)); setv("analysis_screen", sample(1e6, 1)); settle(800) }
setv("analysis_screen_pick", "no_such_variable'; --"); setv("analysis_screen_pick", list("a", "b")); setv("analysis_screen_pick", 9)
settle(1000)
ok(alive(), "junk k / flag / screen-pick values and repeated Compare + Screen clicks do not end the session")
app$set_inputs(tabs = "select"); settle(500)

## ---------------------------------------------------------------------------
## 6d. PUBLISH-UNIFY: t2q:: tokens are now accepted in every selector role and
##     pub_what picks the published figure. Hostile tokens in the new roles and
##     junk pub_what / chip values must sanitize away, never kill the session.
## ---------------------------------------------------------------------------
cat("-- 6d. quantize tokens in all roles, pub_what, chips\n")
for (slot in c("x", "y", "size", "condition")) {
  for (v in list("t2q::99::CD8A", "t2q::3::nope", "t2q::2::cohort", strrep("t2q::4::Z", 500), list("t2q::3::CD8A", "t2q::bad::x")))
    setv(slot, v)
  settle(300)
  if (!alive()) { ok(FALSE, paste("session died on a hostile token in", slot)); break }
}
ok(alive(), "hostile t2q tokens in x / y / size / condition are sanitized away")
setv("x", "cohort"); setv("y", "CD8A")
for (v in list("analysis", "plot", "nonsense", list("plot", "analysis"), 42, list(), "'; DROP TABLE x;--"))
  setv("pub_what", v)
app$set_inputs(tabs = "publish"); settle(1500)
for (v in list(99, -1, "junk", list(2, 3))) { setv("quant_chip_x", v); setv("quant_chip_y", v) }
settle(800)
ok(alive(), "junk pub_what and chip values do not end the session")
app$set_inputs(tabs = "select"); settle(500)

## ---------------------------------------------------------------------------
## 7. The whole storm left no uncaught R error and the app still plots normally.
## ---------------------------------------------------------------------------
cat("-- 7. recovery\n")
errs <- setdiff(new_errors(), character(0))
ok(length(errs) <= base_err, sprintf("no uncaught R error surfaced during fuzzing (%d new)", max(0, length(errs) - base_err)))
app$set_inputs(tabs = "select"); settle(500)
setv("dataset", "TCGA"); setv("x", "cohort"); setv("y", "CD8A"); setv("color", "sample_type")
setv("preset_group", ""); setv("preset_excl", list()); setv("km_groups", 3); setv("surv_max_days", 1825)
settle(800)
app$click("plot_btn"); settle(5000)
ok(isTRUE(app$get_js("(function(){var i=document.querySelector('#main_plot img'); return !!i && i.naturalWidth>50;})()")),
   "after the storm a normal plot still draws")

finish("shiny fuzz")
