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
