## test_equivalence.R — the API must return exactly what gitr() returns.
## Run by ./test.sh inside the T2T image (R + the T2 code), on the service's Docker network:
##   Rscript test_equivalence.R http://t2api:8080 [n_random_probes]
## For every dataset: sample order, every clinical / virtual column, and a stratified random
## sample of probes (every data type) are compared value by value, missing values included.
## The ORACLE side is the files: gitr() over each dataset file (gitr.R) with the roles and declarations
## the file's dataset_meta states VERBATIM (dataset_registry.R, t2_test_helpers.R). The app is an api
## client and is not loaded here; test_gitr_api.R holds the app's data layer to the same oracle.
suppressMessages({source("t2_util.R"); source("gitr.R"); source("dataset_registry.R"); source("t2_test_helpers.R")})
args <- commandArgs(trailingOnly = TRUE); base <- args[1]; n_random <- if (length(args) > 1) as.integer(args[2]) else 60
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
  fi <- dataset_info(ds)                       # path, roles, defaults: dataset_meta of the file, verbatim
  g0 <- quiet(gitr(character(0), dbfile = fi$path, roles = fi$roles))
  fd <- t2_file_declared(fi$path)
  con <- DBI::dbConnect(RSQLite::SQLite(), dbname = fi$path, flags = RSQLite::SQLITE_RO)
  allp <- DBI::dbGetQuery(con, "SELECT probe FROM allprobes")$probe
  cohorts_file <- DBI::dbGetQuery(con, "SELECT cohort FROM cohorts")$cohort
  presets_file <- tryCatch(unique(DBI::dbGetQuery(con, "SELECT preset FROM default_filters")$preset), error = function(e) character(0))
  DBI::dbDisconnect(con)
  cl <- get(sprintf("/v1/%s/clinical", ds))
  ok(identical(unlist(cl$samples), as.character(g0$sample)), sprintf("sample order identical (%d samples)", length(cl$samples)))
  api_cols <- stats::setNames(cl$columns, vapply(cl$columns, `[[`, "", "name"))
  r_cols <- setdiff(colnames(g0), "sample")
  ok(setequal(names(api_cols), r_cols), sprintf("same clinical + virtual columns (%d)", length(r_cols)))
  bad <- Filter(function(n) !same(col_vec(api_cols[[n]]), r_vec(g0[[n]])), intersect(names(api_cols), r_cols))
  if (length(bad)) cat("    differ:", paste(bad, collapse = ", "), "\n")
  ok(length(bad) == 0, "every clinical / virtual column equals gitr()")
  ## probes: a few from every name suffix (data type), plus fixed favourites
  genes <- setdiff(allp, c(colnames(g0), "sample"))
  suffix <- ifelse(grepl("\\.", genes), sub(".*\\.", "", genes), "(none)")
  per <- max(2, ceiling(n_random / length(unique(suffix))))
  pick <- unlist(lapply(split(genes, suffix), function(v) sample(v, min(per, length(v)))))
  ## the .fmut probes have samples with several values (two mutations of one gene): the
  ## rule "smallest value in byte order" must hold on both sides whatever index is used
  if (ds == "TCGA") pick <- unique(c("CD8A", "TP53.mut", "FOXP3", "StromalScore.estimate", "HRD.hrd",
                                     "CPN2.fmut", "TP53.fmut", "TTN.fmut", "KRAS.fmut", pick))
  if (ds == "cptac") pick <- unique(c("CLDN6", "CLDN6.prot", "CLDN6.phospho", pick))   # the not-detected fills below
  pick <- unname(pick)
  t_api <- t_r <- 0; n_ok <- 0; kinds <- character(0); diffs <- character(0); fkinds <- character(0)
  for (chunk in split(pick, ceiling(seq_along(pick) / 20))) {
    t0 <- Sys.time()
    res <- get(sprintf("/v1/%s/values?probes=%s", ds, utils::URLencode(paste(chunk, collapse = ","), reserved = TRUE)))
    t_api <- t_api + as.numeric(Sys.time() - t0, units = "secs")
    t0 <- Sys.time(); g <- quiet(gitr(chunk, dbfile = fi$path, roles = fi$roles)); t_r <- t_r + as.numeric(Sys.time() - t0, units = "secs")
    got <- stats::setNames(res$columns, vapply(res$columns, `[[`, "", "name"))
    for (p in chunk) {
      rv <- g[[p]]
      if (!all(is.na(rv))) fkinds[p] <- if (is.numeric(rv)) "num" else "cat"   # an all-NA column says nothing about its kind
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
  ## not-detected fills: values?fill=zero|floor equals gitr(fill =) value for value, and the answer's
  ## fill_options / filled / tested_n equal what the file mode reports (a dataset whose types offer none: skipped)
  nfill <- 0; fdiffs <- character(0)
  for (chunk in split(pick, ceiling(seq_along(pick) / 20))) {
    res0 <- get(sprintf("/v1/%s/values?probes=%s", ds, utils::URLencode(paste(chunk, collapse = ","), reserved = TRUE)))
    offered <- as.character(unlist(res0$fill_options))
    g0f <- quiet(gitr(chunk, dbfile = fi$path, roles = fi$roles))
    if (!identical(offered, attr(g0f, "fill_options"))) fdiffs <- c(fdiffs, "fill_options")
    for (f in setdiff(offered, "na")) {
      res <- get(sprintf("/v1/%s/values?probes=%s&fill=%s", ds, utils::URLencode(paste(chunk, collapse = ","), reserved = TRUE), f))
      g <- quiet(gitr(chunk, dbfile = fi$path, roles = fi$roles, fill = f))
      got <- stats::setNames(res$columns, vapply(res$columns, `[[`, "", "name"))
      for (p in names(got)) if (!same(col_vec(got[[p]]), r_vec(g[[p]]))) fdiffs <- c(fdiffs, paste(p, f))
      fa <- unlist(res$filled); ta <- unlist(res$tested_n)
      if (!identical(as.integer(fa[order(names(fa))]), as.integer(attr(g, "filled")[order(names(attr(g, "filled")))])) ||
          !identical(as.integer(ta[order(names(ta))]), as.integer(attr(g, "tested_n")[order(names(attr(g, "tested_n")))])))
        fdiffs <- c(fdiffs, paste("counts", f))
      nfill <- nfill + 1
    }
  }
  if (length(fdiffs)) cat("    fill differs:", paste(head(fdiffs, 20), collapse = ", "), "\n")
  ok(length(fdiffs) == 0, sprintf("not-detected fills (%d requests with zero / floor) and fill_options equal gitr(fill =)", nfill))
  ## presets and data sources: the service derives them (dataset.go, sources.go); the oracle here is the
  ## rule semantics applied to the file's own clinical frame (the sample counts, the cohorts present) and
  ## the labels the file's default_filters table declares
  meta <- get(sprintf("/v1/%s/meta", ds))
  rules_of <- function(x) lapply(x$rules, function(r) list(column = r$column, op = r$op, values = as.character(unlist(r$values))))
  raw <- g0; for (n in colnames(raw)) if (is.factor(raw[[n]])) raw[[n]] <- as.character(raw[[n]])
  p_n <- vapply(meta$presets, function(p) as.integer(sum(t2_rules_mask(raw, rules_of(p)))) == as.integer(p$n_samples), NA)
  ok(all(p_n), sprintf("%d presets: each preset's sample count = its rules applied to the file's clinical table", length(p_n)))
  ok(all(presets_file %in% vapply(meta$presets, `[[`, "", "label")),
     sprintf("every default_filters preset of the file is served (%d)", length(presets_file)))
  s_ok <- vapply(meta$sources, function(s) {
    m <- t2_rules_mask(raw, rules_of(s))
    sum(m) == as.integer(s$n_samples) && setequal(as.character(unlist(s$cohorts)), unique(as.character(raw$cohort[m & !is.na(raw$cohort)])))
  }, NA)
  ok(all(s_ok), sprintf("%d data sources: sample counts and cohorts present = the rules applied to the file", length(s_ok)))
  ## the cohort menu is the file's cohorts table, in order
  ok(identical(vapply(meta$cohorts, `[[`, "", "cohort"), cohorts_file), sprintf("cohort menu = the cohorts table (%d)", length(cohorts_file)))
  ## the declarations: what /meta serves equals what the file's dataset_meta / types state, verbatim
  hs <- data.frame(name = vapply(meta$handles, `[[`, "", "name"), role = vapply(meta$handles, `[[`, "", "role"), stringsAsFactors = FALSE)
  ok(identical(hs, fd$handles), sprintf("handles = the file's roles (%s)", paste(sprintf("%s:%s", hs$name, hs$role), collapse = ", ")))
  if (!is.null(fd$tte)) {
    flat <- function(t) list(name = t$name, label = t$label, event_col = t$event_col, time_col = t$time_col, time_unit = t$time_unit, description = t$description)
    ok(identical(lapply(meta$tte_variables, flat), lapply(fd$tte, flat)), sprintf("tte_variables = the file's tte_variables (%d)", length(fd$tte)))
  } else cat("    (the file declares no tte_variables: the service derives them from X / X.time pairs; not compared)\n")
  ok(identical(as.character(unlist(meta$survival_endpoints)), vapply(meta$tte_variables, `[[`, "", "name")), "survival_endpoints = the names of tte_variables")
  tl <- unlist(meta$type_labels)
  ok(identical(tl[names(fd$type_labels)], fd$type_labels), sprintf("type_labels = the file's types.label, the type name where none (%d)", length(fd$type_labels)))
  ab <- unlist(meta$about)
  ok(identical(unname(ab[c("description", "citation", "attribution", "url")]), unname(unlist(fd$about))), "about = the file's about / citation / attribution / about_url")
  dc <- as.character(unlist(meta$default_cohorts))
  ok(identical(dc, fd$default_cohorts) && identical(paste(dc, collapse = ","), meta$defaults$cohorts %||% ""),
     sprintf("default_cohorts = the file's list (%d); defaults.cohorts is the same list comma-joined for the shipped phone", length(dc)))
  for (k in c("x", "y", "color", "size", "condition"))
    if (!identical(meta$defaults[[k]] %||% "", fi$defaults[[k]])) { ok(FALSE, paste("default", k, "= the file's default_", k, sep = "")) }
  ## the typed variable list (probes?all=1): the handles, then the probes of the file, then clinical columns
  pl <- get(sprintf("/v1/%s/probes?all=1", ds))
  a_menu <- as.character(unlist(pl$probes)); a_sec <- as.integer(unlist(pl$section)); a_kind <- c("num", "cat")[as.integer(unlist(pl$kind)) + 1L]
  ok(identical(a_menu[a_sec == 0L], fd$handles$name) && setequal(a_menu[a_sec == 1L], setdiff(allp, c(colnames(g0), "sample"))) &&
     all(a_menu[a_sec == 2L] %in% colnames(g0)) && length(a_menu) == length(unique(a_menu)),
     sprintf("probes?all=1 typed: %d handles, %d probes (= the file's allprobes without clinical columns), %d clinical columns",
             sum(a_sec == 0L), sum(a_sec == 1L), sum(a_sec == 2L)))
  ok(length(unlist(pl$type)) == length(a_menu) && length(a_kind) == length(a_menu) && all(a_kind %in% c("num", "cat")), "the typed list has a type and a kind per name")
  kind_of <- stats::setNames(a_kind, a_menu)
  ok(all(!is.na(kind_of[names(fkinds)])) && all(kind_of[names(fkinds)] == fkinds),
     sprintf("the kind in the typed list = the kind of gitr()'s values for the %d probes compared (factor-typed numbers are 'cat')", length(fkinds)))
  res <- get(sprintf("/v1/%s/values?probes=%s", ds, "no_such_probe_zzz"))
  ok(length(res$columns) == 0 && identical(unlist(res$missing), "no_such_probe_zzz"), "an unknown name is reported as missing")
}
if (length(BAD_TEXT)) cat("\nNOTE: text with bytes that are not valid UTF-8 in the database (served with a space in their place):",
                          paste(sprintf("\"%s\"", BAD_TEXT), collapse = ", "), "\n")
finish("equivalence test")
