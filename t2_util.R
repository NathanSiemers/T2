## t2_util.R
## ============================================================================
## Small helpers shared by the app, the data layer and the tests. Sourced FIRST
## (global.R, and every test): nothing here depends on another T2 file.
##   %||%          one definition, NA-aware (there used to be six, with two meanings)
##   t2_role()     the value of a role key of a dataset's `roles`, or NULL
##   t2_cache()    a bounded cache that drops its oldest entry (was written five times)
##   t2_as_rules() the rules of a /meta preset or source as plain R lists
## ============================================================================

## a if it holds a value, else b. NULL, an empty vector and a single NA are "no value".
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

## The value of a role key (cohort_col, subtype_col, sampletype_col, ...) of a
## dataset's `roles`, or NULL when the dataset has no such role: absent, NA or "".
## `!is.null(t2_role(roles, "subtype_col"))` is the one "does it have a ..." test.
t2_role <- function(roles, key) {
  v <- roles[[key]]
  if (is.null(v) || length(v) != 1 || is.na(v) || !nzchar(v)) NULL else v
}

## A cache of at most `max` entries; when full, the oldest entry goes (insertion
## order, not use order: entries are immutable per key, so there is nothing to
## refresh). get(key) is NULL when absent -- do not store NULL.
##   $get(key)  $put(key, value)  $has(key)  $keys()  $clear()  $size()
t2_cache <- function(max = 100) {
  env <- new.env(parent = emptyenv())
  order <- character(0)
  list(
    get   = function(key) env[[key]],
    has   = function(key) !is.null(env[[key]]),
    put   = function(key, value) {
      if (is.null(env[[key]])) order <<- c(order, key)
      env[[key]] <- value
      if (length(order) > max) {
        drop <- order[seq_len(length(order) - max)]
        rm(list = drop, envir = env)
        order <<- order[-seq_along(drop)]
      }
      invisible(value)
    },
    keys  = function() order,
    clear = function() { rm(list = order, envir = env); order <<- character(0); invisible() },
    size  = function() length(order)
  )
}

## The rules of a preset or source as /meta delivers them (list(column, op, values))
## -> list(list(column, op, values = <character>)).
t2_as_rules <- function(rules) {
  lapply(rules, function(r) list(column = r$column, op = r$op, values = as.character(unlist(r$values))))
}

## The median of each row of a numeric matrix, ignoring NA (an all-NA row is NA).
## matrixStats::rowMedians is 190 x faster than apply(1, median) (12.8k x 10: 3 ms
## against 627 ms); it is used when the package is installed. The shiny image
## (shinyt2t:2026.10) does not have it yet, so there the apply() fallback runs --
## same values; add matrixStats to that image to get the speed.
t2_row_medians <- function(m) {
  m <- as.matrix(m)
  if (requireNamespace("matrixStats", quietly = TRUE)) as.numeric(matrixStats::rowMedians(m, na.rm = TRUE))
  else as.numeric(apply(m, 1, stats::median, na.rm = TRUE))
}

## ---- references (citations) ----------------------------------------------------------
## A reference record is a list(group, title, authors, journal, year, pmid, doi, url, note).
## The statistics the Shiny app itself computes are cited here in full: the survival
## machinery (survival_prototype.R: survfit, survdiff, coxph) and the Analysis tab's
## group comparisons (group_compare.R: wilcox.test, kruskal.test, chisq.test,
## fisher.test, t.test, oneway.test, p.adjust BH; contract T2Mobile/docs/ANALYSIS-SPEC.md).
.t2_ref <- function(title, authors, journal, year, doi = "", pmid = "", note = "") list(
  group = "Statistical methods", title = title, authors = authors, journal = journal, year = year,
  pmid = pmid, doi = doi,
  url = if (nzchar(pmid)) paste0("https://pubmed.ncbi.nlm.nih.gov/", pmid, "/") else paste0("https://doi.org/", doi),
  note = note)
## special color-menu entries: not dataset columns, resolved inside plotter
T2_COLOR_QUANTA       = "quanta"         # color = the FIRST Y token's quantile groups
T2_COLOR_PROBE_QUANTA = "probe_quanta"   # multi-Y x Y token: probe x group dummy
T2_COLOR_SPECIALS     = c("probe", T2_COLOR_QUANTA, T2_COLOR_PROBE_QUANTA)
T2_METHOD_REFERENCES <- list(
  .t2_ref("Nonparametric Estimation from Incomplete Observations", "Kaplan EL, Meier P",
          "Journal of the American Statistical Association", 1958, doi = "10.1080/01621459.1958.10501452",
          note = "The method behind the survival curves (Kaplan-Meier estimate)."),
  .t2_ref("Evaluation of survival data and two new rank order statistics arising in its consideration", "Mantel N",
          "Cancer Chemotherapy Reports", 1966, pmid = "5910392",
          note = "The log-rank test used to compare survival curves between groups."),
  .t2_ref("Regression Models and Life-Tables", "Cox DR",
          "Journal of the Royal Statistical Society, Series B", 1972, doi = "10.1111/j.2517-6161.1972.tb00899.x",
          note = "The proportional hazards model behind the reported hazard ratio."),
  .t2_ref("Individual Comparisons by Ranking Methods", "Wilcoxon F",
          "Biometrics Bulletin", 1945, doi = "10.2307/3001968",
          note = "The rank-sum test comparing a numeric variable between two groups (Analysis tab)."),
  .t2_ref("Use of Ranks in One-Criterion Variance Analysis", "Kruskal WH, Wallis WA",
          "Journal of the American Statistical Association", 1952, doi = "10.1080/01621459.1952.10483441",
          note = "The rank test comparing a numeric variable across three or more groups (Analysis tab)."),
  .t2_ref("On the criterion that a given system of deviations from the probable in the case of a correlated system of variables is such that it can be reasonably supposed to have arisen from random sampling",
          "Pearson K", "Philosophical Magazine, Series 5", 1900, doi = "10.1080/14786440009463897",
          note = "The chi-squared test of independence for categorical comparisons (Analysis tab)."),
  .t2_ref("The logic of inductive inference", "Fisher RA",
          "Journal of the Royal Statistical Society", 1935, doi = "10.2307/2342435",
          note = "The exact test used for 2x2 tables with small expected counts (Analysis tab)."),
  .t2_ref("The generalization of 'Student's' problem when several different population variances are involved",
          "Welch BL", "Biometrika", 1947, doi = "10.1093/biomet/34.1-2.28",
          note = "The unequal-variance t test behind the means-based toggle (Analysis tab)."),
  .t2_ref("Controlling the False Discovery Rate: A Practical and Powerful Approach to Multiple Testing",
          "Benjamini Y, Hochberg Y", "Journal of the Royal Statistical Society, Series B", 1995,
          doi = "10.1111/j.2517-6161.1995.tb02031.x",
          note = "The false-discovery-rate correction applied in the Analysis screen."))

## One reference as HTML: the title (a link when there is a url), then authors, "journal year",
## and the note in small text. Every field is escaped; the url only when http(s).
t2_reference_html <- function(rec) {
  f <- function(k) { v <- rec[[k]]; if (is.null(v) || length(v) == 0 || is.na(v[1])) "" else as.character(v[1]) }
  esc <- htmltools::htmlEscape
  title <- f("title"); url <- f("url")
  head <- if (nzchar(url) && grepl("^https?://", url))
    paste0('<a href="', esc(url, attribute = TRUE), '" target="_blank" rel="noopener">', esc(title), '</a>')
  else esc(title)
  jy <- trimws(paste(f("journal"), f("year")))
  paste0('<div class="t2-ref"><b>', head, '</b>',
         if (nzchar(f("authors"))) paste0('<br>', esc(f("authors"))) else "",
         if (nzchar(jy)) paste0('<br><i>', esc(jy), '</i>') else "",
         if (nzchar(f("note"))) paste0('<br><small>', esc(f("note")), '</small>') else "",
         '</div>')
}
