## t2_test_helpers.R -- the PASS/FAIL vocabulary and printing shared by sql_tests.R and
## dataset_contract_check.R (defined once, here).
##   a check returns PASS(detail) / FAIL(detail) / WARN(detail) / SKIP(detail);
##   t2_run_checks(list(list(group=, name=, fn=), ...)) runs them (an error is a FAIL, never an abort)
##   and returns data.frame(group, test, status, detail); t2_print_results(res, header) prints it.
PASS <- function(detail = "") list(ok = TRUE,  detail = detail)
FAIL <- function(detail = "") list(ok = FALSE, detail = detail)
SKIP <- function(detail = "") list(ok = NA,    detail = paste("SKIP:", detail))
## WARN: a noted condition that is NOT a failure; does not affect the overall verdict.
WARN <- function(detail = "") list(ok = TRUE, warn = TRUE, detail = detail)

t2_run_checks <- function(tests) {
  res <- data.frame(group = character(), test = character(), status = character(),
                    detail = character(), stringsAsFactors = FALSE)
  for (tt in tests) {
    r <- tryCatch(tt$fn(), error = function(e) FAIL(paste("ERROR:", conditionMessage(e))))
    status <- if (is.list(r) && isTRUE(r$warn)) "WARN"
              else if (is.list(r) && is.na(r$ok)) "SKIP"
              else if (isTRUE(r$ok)) "PASS" else "FAIL"
    res <- rbind(res, data.frame(group = tt$group, test = tt$name, status = status,
                                 detail = ifelse(is.null(r$detail), "", r$detail), stringsAsFactors = FALSE))
  }
  res
}

t2_print_results <- function(res, header) {
  cat(header)
  mark <- c(PASS = "  ok ", FAIL = "FAIL ", SKIP = "skip ", WARN = "warn ")
  for (i in seq_len(nrow(res)))
    cat(sprintf("%s [%-11s] %-52s %s\n", mark[res$status[i]], res$group[i], res$test[i], res$detail[i]))
  cat(sprintf("---- %d PASS / %d FAIL / %d WARN / %d SKIP ----\n", sum(res$status == "PASS"),
              sum(res$status == "FAIL"), sum(res$status == "WARN"), sum(res$status == "SKIP")))
}

## ---- the harness of the R tests (test_*.R): ok() counts, finish() exits non-zero, quiet() ----
##   ok(cond, msg)   prints "  PASS msg" / "  FAIL msg" and COUNTS the failures
##   finish(what)    prints the verdict line ("ALL PASS" / "n FAILED") and exits non-zero on a failure
##   quiet(expr)     the value of expr with its printed output and warnings suppressed
## A suite that only prints FAIL lines but exits 0 hides a failure from a script: use finish().
## Usage (from the repository root):   source("t2_test_helpers.R") ... finish("test_xyz")
.t2_test <- new.env(parent = emptyenv())
.t2_test$fails <- 0L
.t2_test$checks <- 0L

ok <- function(cond, msg) {
  pass <- isTRUE(cond)
  cat(if (pass) "  PASS " else "  FAIL ", msg, "\n")
  .t2_test$checks <- .t2_test$checks + 1L
  if (!pass) .t2_test$fails <- .t2_test$fails + 1L
  invisible(pass)
}

quiet <- function(expr) { utils::capture.output(v <- suppressWarnings(suppressMessages(expr))); v }

t2_test_failures <- function() .t2_test$fails

finish <- function(what = "") {
  f <- .t2_test$fails
  cat(sprintf("\n== %s: %s (%d checks) ==\n", if (nzchar(what)) what else "tests", if (f == 0) "ALL PASS" else paste(f, "FAILED"), .t2_test$checks))
  quit(save = "no", status = if (f == 0) 0L else 1L)
}

## What a dataset FILE declares in dataset_meta and types, read VERBATIM (lists are `|`
## lists, tte_variables is JSON): the values the service must serve as `handles`,
## `tte_variables`, `type_labels`, `about` and `default_cohorts` (DATASET-CONTRACT.md s.1-2).
## Returns list(handles = data.frame(name, role), tte = list of entries or NULL when the file
## declares none, type_labels = named chr, about = list, default_cohorts = chr, meta = list).
t2_file_declared <- function(path) {
  con <- DBI::dbConnect(RSQLite::SQLite(), dbname = path, flags = RSQLite::SQLITE_RO)
  on.exit(DBI::dbDisconnect(con))
  mt <- DBI::dbGetQuery(con, "SELECT key, value FROM dataset_meta")
  m <- stats::setNames(as.list(mt$value), mt$key)
  splitl <- function(s) { if (is.null(s) || is.na(s) || !nzchar(s)) return(character(0)); x <- trimws(strsplit(s, "|", fixed = TRUE)[[1]]); x[nzchar(x)] }
  has <- function(k) !is.null(m[[k]]) && !is.na(m[[k]]) && nzchar(m[[k]])
  handles <- data.frame(name = c(if (has("subtype_col")) "subtype", "cohort", if (has("sampletype_col")) m$sampletype_col),
                        role = c(if (has("subtype_col")) "subcohort", "cohort", if (has("sampletype_col")) "sample_type"),
                        stringsAsFactors = FALSE)
  tte <- if (has("tte_variables")) jsonlite::fromJSON(m$tte_variables, simplifyVector = FALSE) else NULL
  ty <- DBI::dbGetQuery(con, "SELECT * FROM types ORDER BY key")
  lab <- if ("label" %in% colnames(ty)) ty$label else rep(NA_character_, nrow(ty))
  type_labels <- stats::setNames(ifelse(is.na(lab), ty$type, lab), ty$type)
  about <- list(description = if (has("about")) m$about else "", citation = if (has("citation")) m$citation else "",
                attribution = if (has("attribution")) m$attribution else "", url = if (has("about_url")) m$about_url else "")
  list(handles = handles, tte = tte, type_labels = type_labels, about = about,
       default_cohorts = splitl(m$default_cohorts), meta = m)
}
