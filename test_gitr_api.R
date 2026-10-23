## test_gitr_api.R — the service as the app's data layer (t2_api_client.R), held to the
## ORACLE: gitr() over the dataset FILES (dataset_registry.R: dataset_meta read verbatim).
## gitr() over T2_API_URL must return the same frames, value for value, and the bundle the same
## lists and the same declarations (handles, time-to-event variables, type labels, About, default cohorts).
## Needs BOTH: the service (T2_API_URL) and the files (./tcga.db or TCGA.db, and T2_DATASETS_DIR):
##   T2_API_URL=http://t2api-dev:8080 T2_DATASETS_DIR=<dir> Rscript test_gitr_api.R
## (T2Mobile/service/test.sh shiny runs it in the T2T image on the service's network.)
suppressMessages({source("global.R"); source("lib.R"); source("dataset_registry.R")})
source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero, quiet()
stopifnot(t2_api_on())
## the same call over the files: switch the data layer off around it
with_files <- function(expr) { old <- T2_API_URL; T2_API_URL <<- ""; on.exit(T2_API_URL <<- old); expr }
## a frame as gitr() returns it: same columns, classes, levels (ignoring row names).
## Column ORDER is not compared: gitr() orders probe columns by storage (the numeric view's
## names sorted, then the text view's), the service by kind, so a factor-typed numeric probe
## (TP53.mut) lands elsewhere. Nothing reads columns by position. Factor LEVELS are compared for
## the columns that were asked for (and sample / the sample-type column): the service drops the
## unused levels of those only (t2_droplevels_cols); the values of every column are compared.
same_frame <- function(a, b, used = colnames(a)) {
  if (!setequal(colnames(a), colnames(b))) return(paste("columns differ:", paste(head(c(setdiff(colnames(a), colnames(b)), setdiff(colnames(b), colnames(a)))), collapse = ",")))
  b <- b[, colnames(a), drop = FALSE]
  if (nrow(a) != nrow(b)) return(sprintf("rows %d vs %d", nrow(a), nrow(b)))
  for (n in colnames(a)) {
    x <- a[[n]]; y <- b[[n]]
    if (is.factor(x) != is.factor(y)) return(paste(n, "factor-ness differs"))
    if (is.factor(x)) { if (n %in% used && !identical(levels(x), levels(y))) return(paste(n, "levels differ")); x <- as.character(x); y <- as.character(y) }
    if (is.numeric(x) != is.numeric(y)) return(paste(n, "numeric-ness differs"))
    ## the service's numbers are doubles whatever the file stores (an integer column over the files): pinned
    if (is.numeric(x) && !is.double(x)) return(paste(n, "is not double over the service:", typeof(x)))
    if (!identical(is.na(x), is.na(y))) return(paste(n, "NA pattern differs"))
    if (is.numeric(x)) { if (!isTRUE(all.equal(x[!is.na(x)], y[!is.na(y)], tolerance = 1e-12))) return(paste(n, "values differ")) }
    else if (!identical(iconv(x, "UTF-8", "UTF-8", sub = " "), iconv(y, "UTF-8", "UTF-8", sub = " "))) return(paste(n, "text differs"))
  }
  TRUE
}
set.seed(20261009)
files <- discover_datasets()
ok(length(files) >= 1 && all(names(files) %in% t2_datasets()), sprintf("every dataset file is served (%s)", paste(names(files), collapse = ", ")))
for (ds in intersect(t2_datasets(), names(files))) {
  cat("\n==", ds, "==\n")
  ba <- load_dataset_bundle(ds)
  fi <- dataset_info(ds)                    # roles, defaults, title, label: dataset_meta, verbatim
  fd <- t2_file_declared(fi$path)
  ## the six gitr roles, the defaults, the titles
  six <- c("cohort_col", "subtype_col", "sampletype_col", "normal_label", "heme_values", "sampletype_levels")
  ok(identical(ba$roles[six], fi$roles[six]), "roles identical")
  d <- c("x", "y", "color", "size", "condition", "cohorts")
  ok(identical(ba$defaults[d], fi$defaults[d]), "defaults identical (cohorts from the array default_cohorts)")
  ok(identical(ba$label, fi$label) && identical(ba$title, fi$title), "title and label identical")
  ## the declarations the service must serve as the file states them
  ok(identical(ba$handles, fd$handles), sprintf("handles = the file's roles: %s", paste(sprintf("%s (%s)", ba$handles$name, ba$handles$role), collapse = ", ")))
  if (!is.null(fd$tte)) {
    flat <- function(t) list(name = t$name, label = t$label, event_col = t$event_col, time_col = t$time_col, time_unit = t$time_unit)
    ok(identical(unname(lapply(ba$tte, flat)), lapply(fd$tte, flat)), sprintf("time-to-event variables = the file's tte_variables (%d)", length(fd$tte)))
  } else cat("  (the file declares no tte_variables: the service derives them; not compared)\n")
  ok(identical(ba$type_labels[names(fd$type_labels)], fd$type_labels), sprintf("type labels = the file's types.label (%d)", length(fd$type_labels)))
  ab4 <- c("description", "citation", "attribution", "url")
  ok(identical(unname(unlist(ba$about[ab4])), unname(unlist(fd$about[ab4]))), "About = the file's about / citation / attribution / about_url")
  ## the bibliography: the service serves the file's records (it only adds the computed url per record)
  nref <- tryCatch({ con0 <- DBI::dbConnect(RSQLite::SQLite(), dbname = fi$path, flags = RSQLite::SQLITE_RO); on.exit(DBI::dbDisconnect(con0), add = TRUE)
    v <- DBI::dbGetQuery(con0, "SELECT value FROM dataset_meta WHERE key = 'references'")$value
    if (length(v)) length(jsonlite::fromJSON(v, simplifyVector = FALSE)) else 0L }, error = function(e) 0L)
  ok(length(ba$about$references) == nref && all(vapply(ba$about$references, function(r) nzchar(r$title) && nzchar(r$url), logical(1))),
     sprintf("references = the file's %d record(s), each with a title and a link", nref))
  ok(identical(ba$default_cohorts, fd$default_cohorts), sprintf("default cohorts = the file's default_cohorts (%d)", length(fd$default_cohorts)))
  ## the lists of the file
  con <- DBI::dbConnect(RSQLite::SQLite(), dbname = fi$path, flags = RSQLite::SQLITE_RO)
  co <- DBI::dbGetQuery(con, "SELECT cohort, cohortstring FROM cohorts")
  allp <- DBI::dbGetQuery(con, "SELECT probe FROM allprobes")$probe
  DBI::dbDisconnect(con)
  ok(identical(unname(ba$mycohorts), co$cohort) && identical(names(ba$mycohorts), co$cohortstring), sprintf("cohort menu identical (%d)", nrow(co)))
  clin_names <- colnames(ba$clin)
  ok(setequal(ba$mygenes, setdiff(allp, c(clin_names, "sample"))), sprintf("probe list = the file's allprobes without clinical columns (%d)", length(ba$mygenes)))
  ok(all(ba$mygenesplus %in% c(ba$handles$name, ba$mygenes, ba$clin_vars)) && !anyDuplicated(ba$mygenesplus) &&
     all(setdiff(clin_names, "sample") %in% ba$mygenesplus),
     sprintf("variable menu: handles, probes, clinical columns (%d names; %d clinical)", length(ba$mygenesplus), length(ba$clin_vars)))
  ok(identical(as.character(ba$clin$sample), as.character(with_files(quiet(gitr(character(0), dbfile = fi$path, roles = fi$roles)))$sample)),
     "clinical frame: same samples in the same order")
  ## gitr: clinical only, then probes of every kind, with the filters
  ga <- quiet(gitr(character(0), dbfile = ba$path, roles = ba$roles))
  gf <- with_files(quiet(gitr(character(0), dbfile = fi$path, roles = fi$roles)))
  r <- same_frame(ga, gf); ok(isTRUE(r), paste("gitr(no probes) identical:", if (isTRUE(r)) sprintf("%d x %d", nrow(gf), ncol(gf)) else r))
  genes <- setdiff(ba$mygenes, colnames(gf))
  suffix <- ifelse(grepl("\\.", genes), sub(".*\\.", "", genes), "(none)")
  pick <- unname(unlist(lapply(split(genes, suffix), function(v) sample(v, min(3, length(v))))))
  if (ds == "TCGA") pick <- unique(c("CD8A", "TP53.mut", "FOXP3", "StromalScore.estimate", "TP53.fmut", "OS", "OS.time", pick))
  used <- c("sample", t2_role(ba$roles, "sampletype_col"), pick)
  t0 <- Sys.time(); ga <- quiet(gitr(pick, dbfile = ba$path, roles = ba$roles)); ta <- as.numeric(Sys.time() - t0, units = "secs")
  t0 <- Sys.time(); gf <- with_files(quiet(gitr(pick, dbfile = fi$path, roles = fi$roles))); tf <- as.numeric(Sys.time() - t0, units = "secs")
  r <- same_frame(ga, gf, used); ok(isTRUE(r), paste(sprintf("gitr(%d probes of every type) identical:", length(pick)), if (isTRUE(r)) sprintf("%d x %d; service %.2f s (first request), files %.2f s", nrow(gf), ncol(gf), ta, tf) else r))
  t0 <- Sys.time(); ga <- quiet(gitr(pick, dbfile = ba$path, roles = ba$roles)); ta <- as.numeric(Sys.time() - t0, units = "secs")
  cat(sprintf("    the same probes again from the service: %.2f s (cached)\n", ta))
  ## the parsed types are pinned: numeric probes are double with NA_real_, never integer / logical
  numcols <- intersect(pick, colnames(ga))[vapply(intersect(pick, colnames(ga)), function(n) is.numeric(ga[[n]]), NA)]
  ok(all(vapply(numcols, function(n) is.double(ga[[n]]), NA)), sprintf("numeric probe columns are double (%d)", length(numcols)))
  ## filters: cohort, rules (a preset), keep_samples, phenos = FALSE, makefactors = FALSE
  co3 <- head(unname(ba$mycohorts), 3)
  p1 <- if (length(ba$presets)) ba$presets[[1]]$rules else list()
  keep <- sample(as.character(ba$clin$sample), min(500, nrow(ba$clin)))
  for (args in list(list(cohort = co3), list(rules = p1), list(cohort = co3, rules = p1, keep_samples = keep),
                    list(phenos = FALSE), list(makefactors = FALSE), list(nonormal = TRUE, noheme = TRUE))) {
    ga <- quiet(do.call(gitr, c(list(head(pick, 4), dbfile = ba$path, roles = ba$roles), args)))
    gf <- with_files(quiet(do.call(gitr, c(list(head(pick, 4), dbfile = fi$path, roles = fi$roles), args))))
    r <- same_frame(ga, gf, c("sample", t2_role(ba$roles, "sampletype_col"), head(pick, 4)))
    ok(isTRUE(r), paste("gitr with", paste(names(args), collapse = "+"), if (isTRUE(r)) sprintf("identical (%d rows)", nrow(gf)) else r))
  }
  ## not-detected values: the service and the files agree on fill = zero / floor, and on what they report
  fattr <- function(x) list(attr(x, "fill_options"), attr(x, "fill", exact = TRUE), attr(x, "filled"), attr(x, "tested_n"))
  gn <- quiet(gitr(head(pick, 3), dbfile = ba$path, roles = ba$roles))
  ok(identical(attr(gn, "fill_options"), with_files(attr(quiet(gitr(head(pick, 3), dbfile = fi$path, roles = fi$roles)), "fill_options"))),
     sprintf("fill_options reported alike by service and files (%s)", paste(attr(gn, "fill_options"), collapse = "|")))
  if (ds == "cptac") {
    fp <- c("CLDN6", "CLDN6.prot", "CLDN6.phospho", "TP53.mut")
    fp <- intersect(fp, c(ba$mygenes, ba$clin_vars))
    ok("CLDN6.prot" %in% fp, "cptac has CLDN6.prot for the fill cases")
    ga0 <- quiet(gitr(fp, dbfile = ba$path, roles = ba$roles))
    ok(identical(attr(ga0, "fill_options"), c("na", "zero", "floor")) && is.null(attr(ga0, "fill", exact = TRUE)), "cptac: the answer offers na, zero, floor for a proteome probe; none applied by default")
    ok(identical(attr(quiet(gitr("CLDN6", dbfile = ba$path, roles = ba$roles)), "fill_options"), "na"), "an RNA-only request offers na only")
    for (fl in c("zero", "floor")) for (extra in list(list(), list(cohort = co3), list(keep_samples = keep))) {
      ga <- quiet(do.call(gitr, c(list(fp, dbfile = ba$path, roles = ba$roles, fill = fl), extra)))
      gf <- with_files(quiet(do.call(gitr, c(list(fp, dbfile = fi$path, roles = fi$roles, fill = fl), extra))))
      r <- same_frame(ga, gf, c("sample", fp))
      ok(isTRUE(r) && identical(fattr(ga), fattr(gf)) && identical(attr(ga, "filled_rows"), attr(gf, "filled_rows")) &&
         all(vapply(names(attr(ga, "filled_rows")), function(p) length(attr(ga, "filled_rows")[[p]]) == nrow(ga) && sum(attr(ga, "filled_rows")[[p]]) <= attr(ga, "filled")[[p]], NA)),
         paste("fill =", fl, if (length(extra)) paste("with", names(extra)) else "", "identical (frame, filled, tested_n):",
               if (isTRUE(r)) sprintf("filled %s of %s", paste(attr(ga, "filled"), collapse = ","), paste(attr(ga, "tested_n"), collapse = ",")) else r))
    }
    z <- quiet(gitr(fp, dbfile = ba$path, roles = ba$roles, fill = "zero"))
    ok(sum(is.na(ga0$CLDN6.prot)) - sum(is.na(z$CLDN6.prot)) == attr(z, "filled")[["CLDN6.prot"]] && all(z$CLDN6.prot[is.na(ga0$CLDN6.prot)] %in% c(0, NA)),
       "zero: the cells that were missing and tested are 0, the count matches `filled`; untested stay NA")
    ok(identical(ga0$CLDN6, z$CLDN6), "an RNA column in the same request is unchanged by the fill")
    z2 <- quiet(gitr("CLDN6", dbfile = ba$path, roles = ba$roles, fill = "zero"))
    ok(is.null(attr(z2, "fill", exact = TRUE)), "a fill that the answer did not offer is not applied (RNA only)")
  }
  ga <- quiet(gitr("no_such_probe_zzz", dbfile = ba$path, roles = ba$roles))
  ok("no_such_probe_zzz" %in% colnames(ga) && all(is.na(ga$no_such_probe_zzz)), "an unknown probe is an all-NA column, as with the files")
}
## ---- file mode (the oracle itself): filters with phenos = FALSE, undeclared sample types, absent virtual columns ----
cat("\n== file mode: gitr() filters and levels (DEMO) ==\n")
if ("DEMO" %in% names(files)) {
  fd <- dataset_info("DEMO"); co <- "breast"
  gp1 <- quiet(with_files(gitr("GENE01", phenos = TRUE,  cohort = co, dbfile = fd$path, roles = fd$roles)))
  gp0 <- quiet(with_files(gitr("GENE01", phenos = FALSE, cohort = co, dbfile = fd$path, roles = fd$roles)))
  nb <- sum(as.character(quiet(with_files(gitr("cohort", cohort = "all", dbfile = fd$path, roles = fd$roles)))$cohort) == co)
  ok(nrow(gp1) == nb && nb > 0 && nrow(gp0) == nb, sprintf("phenos = FALSE filters by cohort like phenos = TRUE (%d of %d rows)", nrow(gp0), nb))
  ok(identical(sort(as.character(gp0$sample)), sort(as.character(gp1$sample))) && identical(colnames(gp0), c("sample", "GENE01")), "... the same samples, and only the requested columns")
  gall <- quiet(with_files(gitr("GENE01", phenos = FALSE, dbfile = fd$path, roles = fd$roles)))
  ok(nrow(gall) > nb, "... and without a cohort filter all samples come back")
  gr <- quiet(with_files(gitr("GENE01", phenos = FALSE, rules = list(list(column = "tissue_origin", op = "in", values = "lung")), dbfile = fd$path, roles = fd$roles)))
  ok(nrow(gr) == 12, "phenos = FALSE applies sample rules too (lung: 12)")
  ok(!"lcohort" %in% colnames(quiet(with_files(gitr(c("GENE01", "lcohort"), dbfile = fd$path, roles = fd$roles)))),
     "a dataset with no clinical `cohort` column returns no lcohort column and no error (the service says `missing`)")
  r0 <- fd$roles; r0$subtype_col <- NA_character_
  ok(!"subtype" %in% colnames(quiet(with_files(gitr(c("GENE01", "subtype"), dbfile = fd$path, roles = r0)))),
     "asking for subtype where no subtype_col is declared returns no column and no error")
  ## sample-type values outside the declared levels: kept as extra levels with ONE warning, never NA
  r1 <- fd$roles; r1$sampletype_col <- "growth_media"
  lv <- sort(unique(quiet(with_files(gitr("growth_media", dbfile = fd$path, roles = fd$roles)))$growth_media)); r1$sampletype_levels <- as.character(lv[1])
  w <- character(0)
  g1 <- withCallingHandlers(suppressMessages(capture.output(gx <- with_files(gitr("GENE01", dbfile = fd$path, roles = r1)))),
                            warning = function(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") })
  ok(length(w) == 1 && grepl("not in the declared sampletype_levels", w), "one warning names the undeclared sample types")
  ok(sum(is.na(gx$growth_media)) == 0 && identical(levels(gx$growth_media)[1], as.character(lv[1])) && setequal(levels(gx$growth_media), as.character(lv)),
     "no sample type became NA; the declared level stays first, the others follow")
}
finish("gitr over the service")
