## test_equivalence.R — the API must return exactly what gitr() returns.
## Run by ./test.sh inside the T2T image (R + the T2 code), on the service's Docker network:
##   Rscript test_equivalence.R http://t2api:8080 [n_random_probes]
## For every dataset: sample order, every clinical / virtual column, and a stratified random
## sample of probes (every data type) are compared value by value, missing values included.
suppressMessages({source("global.R"); source("database_connection_shiny.R"); source("lib.R")})
args <- commandArgs(trailingOnly = TRUE); base <- args[1]; n_random <- if (length(args) > 1) as.integer(args[2]) else 60
ok <- function(cond, msg) { cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n"); if (!isTRUE(cond)) FAILS <<- FAILS + 1 }
FAILS <- 0
quiet <- function(expr) { utils::capture.output(v <- suppressWarnings(expr)); v }
get <- function(path) jsonlite::fromJSON(paste0(base, path), simplifyVector = FALSE)
## an API column -> the R vector it stands for (numbers, or character with NA)
col_vec <- function(col) {
  if (col$kind == "num") vapply(col$values, function(v) if (is.null(v)) NA_real_ else as.numeric(v), 0)
  else {   # codes index the levels from 0; -1 = missing (note: lv[0] would silently DROP elements in R)
    codes <- unlist(col$codes); lv <- unlist(col$levels)
    out <- rep(NA_character_, length(codes)); out[codes >= 0] <- lv[codes[codes >= 0] + 1]; out
  }
}
## the same from a gitr column. JSON must be valid UTF-8, so the API turns every invalid byte
## of database text into a space (the one documented deviation); do the same to gitr's text.
BAD_TEXT <- character(0)
r_vec <- function(x) {
  if (is.numeric(x)) return(as.numeric(x))
  x <- as.character(x); fixed <- iconv(x, "UTF-8", "UTF-8", sub = " ")
  BAD_TEXT <<- unique(c(BAD_TEXT, fixed[!is.na(x) & (is.na(fixed) | fixed != x)]))
  fixed
}
same <- function(a, b) {
  if (is.numeric(a) != is.numeric(b)) return(FALSE)
  if (!identical(is.na(a), is.na(b))) return(FALSE)
  if (is.numeric(a)) isTRUE(all.equal(a[!is.na(a)], b[!is.na(b)], tolerance = 1e-12)) else identical(a[!is.na(a)], b[!is.na(b)])
}
set.seed(20261004)
for (ds in vapply(get("/v1/datasets")$datasets, `[[`, "", "name")) {
  cat("\n==", ds, "==\n")
  b <- load_dataset_bundle(ds)
  g0 <- quiet(gitr(character(0), dbfile = b$path, roles = b$roles))
  cl <- get(sprintf("/v1/%s/clinical", ds))
  ok(identical(unlist(cl$samples), as.character(g0$sample)), sprintf("sample order identical (%d samples)", length(cl$samples)))
  api_cols <- stats::setNames(cl$columns, vapply(cl$columns, `[[`, "", "name"))
  r_cols <- setdiff(colnames(g0), "sample")
  ok(setequal(names(api_cols), r_cols), sprintf("same clinical + virtual columns (%d)", length(r_cols)))
  bad <- Filter(function(n) !same(col_vec(api_cols[[n]]), r_vec(g0[[n]])), intersect(names(api_cols), r_cols))
  if (length(bad)) cat("    differ:", paste(bad, collapse = ", "), "\n")
  ok(length(bad) == 0, "every clinical / virtual column equals gitr()")
  ## probes: a few from every name suffix (data type), plus fixed favourites
  genes <- setdiff(b$mygenes, colnames(g0))
  suffix <- ifelse(grepl("\\.", genes), sub(".*\\.", "", genes), "(none)")
  per <- max(2, ceiling(n_random / length(unique(suffix))))
  pick <- unlist(lapply(split(genes, suffix), function(v) sample(v, min(per, length(v)))))
  ## the .fmut probes have samples with several values (two mutations of one gene): the
  ## rule "smallest value in byte order" must hold on both sides whatever index is used
  if (ds == "TCGA") pick <- unique(c("CD8A", "TP53.mut", "FOXP3", "StromalScore.estimate", "HRD.hrd",
                                     "CPN2.fmut", "TP53.fmut", "TTN.fmut", "KRAS.fmut", pick))
  pick <- unname(pick)
  t_api <- t_r <- 0; n_ok <- 0; kinds <- character(0); diffs <- character(0)
  for (chunk in split(pick, ceiling(seq_along(pick) / 20))) {
    t0 <- Sys.time()
    res <- get(sprintf("/v1/%s/values?probes=%s", ds, utils::URLencode(paste(chunk, collapse = ","), reserved = TRUE)))
    t_api <- t_api + as.numeric(Sys.time() - t0, units = "secs")
    t0 <- Sys.time(); g <- quiet(gitr(chunk, dbfile = b$path, roles = b$roles)); t_r <- t_r + as.numeric(Sys.time() - t0, units = "secs")
    got <- stats::setNames(res$columns, vapply(res$columns, `[[`, "", "name"))
    for (p in chunk) {
      rv <- g[[p]]
      if (is.null(got[[p]])) {            # the API says "no such probe": gitr must have an all-NA column
        if (all(is.na(rv))) n_ok <- n_ok + 1 else diffs <- c(diffs, paste(p, "(API: missing)"))
        next
      }
      kinds <- c(kinds, got[[p]]$kind)
      ## gitr reports factor-typed probes as factors and the rest as numbers / text
      if (same(col_vec(got[[p]]), r_vec(rv)) && (got[[p]]$kind == "cat") == (!is.numeric(rv))) n_ok <- n_ok + 1
      else diffs <- c(diffs, p)
    }
  }
  if (length(diffs)) cat("    differ:", paste(head(diffs, 20), collapse = ", "), "\n")
  ok(n_ok == length(pick), sprintf("%d of %d probes equal gitr() value for value (%d numeric, %d categorical; suffixes: %s)",
                                   n_ok, length(pick), sum(kinds == "num"), sum(kinds == "cat"), paste(sort(unique(suffix)), collapse = " ")))
  cat(sprintf("    time for these probes: API %.1f s (first request for each, uncached), gitr() %.1f s\n", t_api, t_r))
  res <- get(sprintf("/v1/%s/values?probes=%s", ds, "no_such_probe_zzz"))
  ok(length(res$columns) == 0 && identical(unlist(res$missing), "no_such_probe_zzz"), "an unknown name is reported as missing")
}
if (length(BAD_TEXT)) cat("\nNOTE: text with bytes that are not valid UTF-8 in the database (served with a space in their place):",
                          paste(sprintf("\"%s\"", BAD_TEXT), collapse = ", "), "\n")
cat(sprintf("\n== equivalence test done: %s ==\n", if (FAILS == 0) "ALL PASS" else paste(FAILS, "FAILED")))
quit(status = if (FAILS == 0) 0 else 1)
