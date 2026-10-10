## test_gitr_api.R — the service as the app's data layer (t2_api_client.R):
## gitr() over T2_API_URL must return the same frames as gitr() over the
## files, and the bundle the same lists. Run with BOTH available:
##   T2_API_URL=http://t2api-dev:8080 Rscript test_gitr_api.R     (files in ./ and T2_DATASETS_DIR)
## (T2Mobile/service/test.sh shiny runs it in the T2T image on the service's network.)
suppressMessages({source("global.R"); source("database_connection_shiny.R"); source("lib.R")})
ok <- function(cond, msg) { cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n"); if (!isTRUE(cond)) FAILS <<- FAILS + 1 }
FAILS <- 0
quiet <- function(expr) { utils::capture.output(v <- suppressWarnings(expr)); v }
stopifnot(t2_api_on())
## the same call over the files: switch the layer off around it
with_files <- function(expr) { old <- T2_API_URL; T2_API_URL <<- ""; on.exit(T2_API_URL <<- old); expr }
## a frame as gitr() returns it: same columns, classes, levels (ignoring row names)
## Column ORDER is not compared: gitr() orders probe columns by storage (the numeric view's
## names sorted, then the text view's), the service by kind, so a factor-typed numeric probe
## (TP53.mut) lands elsewhere. Nothing reads columns by position.
same_frame <- function(a, b) {
  if (!setequal(colnames(a), colnames(b))) return(paste("columns differ:", paste(head(c(setdiff(colnames(a), colnames(b)), setdiff(colnames(b), colnames(a)))), collapse = ",")))
  b <- b[, colnames(a), drop = FALSE]
  if (nrow(a) != nrow(b)) return(sprintf("rows %d vs %d", nrow(a), nrow(b)))
  for (n in colnames(a)) {
    x <- a[[n]]; y <- b[[n]]
    if (is.factor(x) != is.factor(y)) return(paste(n, "factor-ness differs"))
    if (is.factor(x)) { if (!identical(levels(x), levels(y))) return(paste(n, "levels differ")); x <- as.character(x); y <- as.character(y) }
    if (is.numeric(x) != is.numeric(y)) return(paste(n, "numeric-ness differs"))
    if (!identical(is.na(x), is.na(y))) return(paste(n, "NA pattern differs"))
    if (is.numeric(x)) { if (!isTRUE(all.equal(x[!is.na(x)], y[!is.na(y)], tolerance = 1e-12))) return(paste(n, "values differ")) }
    else if (!identical(iconv(x, "UTF-8", "UTF-8", sub = " "), iconv(y, "UTF-8", "UTF-8", sub = " "))) return(paste(n, "text differs"))
  }
  TRUE
}
set.seed(20261009)
for (ds in list_datasets()) {
  cat("\n==", ds, "==\n")
  ba <- load_dataset_bundle(ds)
  bf <- with_files(load_dataset_bundle(ds))
  ## the six gitr roles (the file side also carries the part declaration, which the
  ## service folds into its ready-made `sources`)
  six <- c("cohort_col", "subtype_col", "sampletype_col", "normal_label", "heme_values", "sampletype_levels")
  ok(identical(ba$roles[six], bf$roles[six]), "roles identical")
  ok(identical(ba$defaults, bf$defaults), "defaults identical")
  ok(identical(ba$label, bf$label) && identical(ba$title, bf$title), "title and label identical")
  ok(identical(ba$mycohorts, bf$mycohorts), sprintf("cohort menu identical (%d)", length(bf$mycohorts)))
  r_menu <- setdiff(unique(bf$mygenesplus), "sample")
  ok(identical(head(ba$mygenesplus, length(r_menu)), r_menu), sprintf("variable menu identical (%d names; the service adds %d clinical columns)", length(r_menu), length(ba$mygenesplus) - length(r_menu)))
  ok(identical(ba$presets, bf$presets), sprintf("presets identical (%d)", length(bf$presets)))
  ok(identical(ba$sources, bf$sources), sprintf("data sources identical (%d)", length(bf$sources)))
  ok(identical(ba$types$type, bf$types$type), sprintf("data-type table identical (%d types)", nrow(bf$types)))
  ok(identical(as.character(ba$clin$sample), as.character(bf$clin$sample)) && setequal(colnames(ba$clin), colnames(bf$clin)),
     "clinical frame: same samples and columns")
  ## gitr: clinical only, then probes of every kind, with the filters
  ga <- quiet(gitr(character(0), dbfile = ba$path, roles = ba$roles))
  gf <- with_files(quiet(gitr(character(0), dbfile = bf$path, roles = bf$roles)))
  r <- same_frame(ga, gf); ok(isTRUE(r), paste("gitr(no probes) identical:", if (isTRUE(r)) sprintf("%d x %d", nrow(gf), ncol(gf)) else r))
  genes <- setdiff(bf$mygenes, colnames(gf))
  suffix <- ifelse(grepl("\\.", genes), sub(".*\\.", "", genes), "(none)")
  pick <- unname(unlist(lapply(split(genes, suffix), function(v) sample(v, min(3, length(v))))))
  if (ds == "TCGA") pick <- unique(c("CD8A", "TP53.mut", "FOXP3", "StromalScore.estimate", "TP53.fmut", "OS", "OS.time", pick))
  t0 <- Sys.time(); ga <- quiet(gitr(pick, dbfile = ba$path, roles = ba$roles)); ta <- as.numeric(Sys.time() - t0, units = "secs")
  t0 <- Sys.time(); gf <- with_files(quiet(gitr(pick, dbfile = bf$path, roles = bf$roles))); tf <- as.numeric(Sys.time() - t0, units = "secs")
  r <- same_frame(ga, gf); ok(isTRUE(r), paste(sprintf("gitr(%d probes of every type) identical:", length(pick)), if (isTRUE(r)) sprintf("%d x %d; service %.2f s (first request), files %.2f s", nrow(gf), ncol(gf), ta, tf) else r))
  t0 <- Sys.time(); ga <- quiet(gitr(pick, dbfile = ba$path, roles = ba$roles)); ta <- as.numeric(Sys.time() - t0, units = "secs")
  cat(sprintf("    the same probes again from the service: %.2f s (cached)\n", ta))
  ## filters: cohort, rules (a preset), keep_samples, phenos = FALSE, makefactors = FALSE
  co <- head(unname(bf$mycohorts), 3)
  p1 <- bf$presets[[1]]$rules
  keep <- sample(as.character(bf$clin$sample), min(500, nrow(bf$clin)))
  for (args in list(list(cohort = co), list(rules = p1), list(cohort = co, rules = p1, keep_samples = keep),
                    list(phenos = FALSE), list(makefactors = FALSE), list(nonormal = TRUE, noheme = TRUE))) {
    ga <- quiet(do.call(gitr, c(list(head(pick, 4), dbfile = ba$path, roles = ba$roles), args)))
    gf <- with_files(quiet(do.call(gitr, c(list(head(pick, 4), dbfile = bf$path, roles = bf$roles), args))))
    r <- same_frame(ga, gf)
    ok(isTRUE(r), paste("gitr with", paste(names(args), collapse = "+"), if (isTRUE(r)) sprintf("identical (%d rows)", nrow(gf)) else r))
  }
  ga <- quiet(gitr("no_such_probe_zzz", dbfile = ba$path, roles = ba$roles))
  ok("no_such_probe_zzz" %in% colnames(ga) && all(is.na(ga$no_such_probe_zzz)), "an unknown probe is an all-NA column, as with the files")
}
cat(sprintf("\n== gitr over the service: %s ==\n", if (FAILS == 0) "ALL PASS" else paste(FAILS, "FAILED")))
quit(status = if (FAILS == 0) 0 else 1)
