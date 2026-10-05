## test_t2_backend.R — the Thanos backend over T2 data, and the sample pre-filter
## predicate it shares with gitr(). No Shiny session needed.
##   Rscript test_t2_backend.R        (from the app directory)
suppressMessages({
  source("global.R"); source("database_connection_shiny.R")
  source("lib.R"); source("input_validation.R"); source("t2_thanos.R")
})

ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")
quiet <- function(expr) { utils::capture.output(v <- expr); v }

ok(HAVE_THANOS, "Thanos loaded, with base_mask support")

## the value Thanos should see for a gitr column: factors as character
as_thanos <- function(x) if (is.factor(x) || is.logical(x)) as.character(x) else as.numeric(x)

for (ds in list_datasets()) {
  cat("\n==", ds, "==\n")
  b  <- load_dataset_bundle(ds)
  be <- quiet(backend_t2(b))
  g0 <- quiet(gitr(character(0), dbfile = b$path, roles = b$roles))

  ok(be$n_rows() == nrow(g0) && identical(be$samples, as.character(g0$sample)),
     sprintf("rows are the dataset's samples, in gitr order (%d)", be$n_rows()))
  cols <- be$get_columns()
  ok(!anyDuplicated(cols) && !("sample" %in% cols) && all(nzchar(cols)),
     sprintf("column list is clean (%d columns)", length(cols)))
  ok(all(setdiff(colnames(g0), "sample") %in% cols),
     "every clinical/virtual column gitr provides is filterable")
  ## a virtual handle the dataset does not have must not be offered
  ok(all(intersect(c("cohort", "subtype"), cols) %in% colnames(g0)),
     "no phantom virtual columns")

  ## every clinical column can be fetched and described without error
  clin <- setdiff(colnames(g0), "sample")
  res <- vapply(clin, function(v) {
    x <- be$get_column(v); i <- be$get_column_info(v)
    length(x) == be$n_rows() && identical(i$name, v) && is.logical(i$is_numeric)
  }, NA)
  ok(all(res), sprintf("all %d clinical columns fetch + describe", length(clin)))

  ## clinical columns equal gitr's, value for value
  same <- vapply(clin, function(v) identical(be$get_column(v), as_thanos(g0[[v]])), NA)
  ok(all(same), "clinical columns identical to gitr()")

  ## probes: a handful, fetched one by one and in one prefetch
  probes <- head(setdiff(b$mygenes, colnames(g0)), 4)
  if (ds == "TCGA") probes <- c("CD8A", "TP53.mut", "FOXP3", "StromalScore.estimate")
  gp <- quiet(gitr(probes, dbfile = b$path, roles = b$roles))
  gp <- gp[match(be$samples, as.character(gp$sample)), ]
  be2 <- quiet(backend_t2(b))
  quiet(be2$prefetch(probes))
  same <- vapply(probes, function(p) {
    x <- quiet(be$get_column(p))
    identical(x, as_thanos(gp[[p]])) && identical(x, be2$get_column(p))
  }, NA)
  ok(all(same), sprintf("probe columns identical to gitr(), single + prefetch (%s)",
                        paste(probes, collapse = ", ")))
  if (ds == "TCGA") {
    ok(isTRUE(be$get_column_info("CD8A")$is_numeric), "CD8A is numeric (slider)")
    i <- be$get_column_info("TP53.mut")
    ok(!i$is_numeric && setequal(i$levels, c("0", "1")), "TP53.mut is categorical 0/1 (checkboxes)")
    ok(be$get_column_info("CD8A")$n_na == sum(is.na(gp$CD8A)), "NA count matches gitr")
  }

  ## unknown names: an all-NA column, not an error (and never a query)
  x <- be$get_column("no_such_probe_xyz")
  ok(length(x) == be$n_rows() && all(is.na(x)), "unknown column is all-NA, no error")

  ## the pre-filter predicate == the samples gitr keeps, for every combination
  co <- unname(b$mycohorts)
  combos <- list(list("all", FALSE, FALSE), list("all", TRUE, FALSE),
                 list("all", FALSE, TRUE),  list("all", TRUE, TRUE))
  if (length(co) >= 2) combos <- c(combos, list(list(co[1:2], FALSE, FALSE),
                                                list(co[1:2], TRUE, TRUE),
                                                list(co[length(co)], TRUE, FALSE)))
  agree <- vapply(combos, function(k) {
    g <- quiet(gitr(character(0), cohort = k[[1]], nonormal = k[[2]], noheme = k[[3]],
                    dbfile = b$path, roles = b$roles))
    m <- be$base_mask(cohort = k[[1]], nonormal = k[[2]], noheme = k[[3]])
    is.logical(m) && length(m) == be$n_rows() && !anyNA(m) &&
      setequal(be$samples[m], as.character(g$sample))
  }, NA)
  ok(all(agree), sprintf("base mask == gitr's kept samples (%d filter combinations)", length(combos)))
  nn <- be$base_mask(nonormal = TRUE)
  cat(sprintf("    Exclude Non-tumor keeps %d of %d samples\n", sum(nn), length(nn)))
  ok(all(be$base_mask()), "no pre-filters: every sample is in the universe")

  ## keep_samples in gitr
  ids <- be$samples[seq(1, be$n_rows(), length.out = 25)]
  g <- quiet(gitr(probes[1], dbfile = b$path, roles = b$roles, keep_samples = ids))
  ok(setequal(as.character(g$sample), ids), "gitr(keep_samples) keeps exactly those samples")
  g <- quiet(gitr(probes[1], dbfile = b$path, roles = b$roles, keep_samples = character(0)))
  ok(nrow(g) == 0, "gitr(keep_samples = character(0)) keeps nothing")
  g <- quiet(gitr(probes[1], dbfile = b$path, roles = b$roles, keep_samples = NULL))
  ok(nrow(g) == be$n_rows(), "gitr(keep_samples = NULL) keeps everything")
  if (length(co) >= 2) {
    g <- quiet(gitr(probes[1], cohort = co[1], dbfile = b$path, roles = b$roles,
                    keep_samples = be$samples))
    ok(setequal(as.character(g$sample), be$samples[be$base_mask(cohort = co[1])]),
       "keep_samples combines with the cohort filter")
  }
}

cat("\n== filter descriptions ==\n")
b  <- load_dataset_bundle("TCGA"); be <- quiet(backend_t2(b))
d <- quiet(t2_describe_filters(list(CD8A = c(5, 9.123456), FOXP3 = c(-Inf, 3), MKI67 = c(2, Inf),
                                    gender = "FEMALE", TP53.mut = c("0", "1"), PDCD1 = c(-Inf, Inf)),
                               be))
print(d)
ok(length(d) == 4 && any(grepl("CD8A in \\[5, 9.123\\]", d)) && any(grepl("FOXP3 <= 3", d)) &&
   any(grepl("MKI67 >= 2", d)) && any(grepl("gender: FEMALE", d)),
   "active filters described; no-op filters (full range / all levels) omitted")

cat("== t2 backend test done ==\n")
