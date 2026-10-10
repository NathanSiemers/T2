## t2_api_client.R
## ============================================================================
## The T2 data layer over the t2api service (T2Mobile/docs/API.md) -- the
## second implementation of what gitr() and the dataset bundle read from the
## SQLite files. Switched on by the environment variable
##
##     T2_API_URL=http://t2api:8080            (the service's Docker network)
##     T2_API_URL=https://www.fiveprime.org/api/t2   (from anywhere)
##
## With it set, the app needs no database files at all: discover_datasets(),
## dataset_info(), the bundle and gitr() all go to the service. Without it
## (the default, RStudio work, the tests) nothing here is used. test_gitr_api.R
## checks that both paths return the same frames, value for value.
##
## What the service gives us is exactly what gitr() computes (the service's
## own equivalence test, T2Mobile/service/test_equivalence.R, holds it to
## that), so the work here is only transport, caching and R typing:
##   - /clinical once per dataset version (every clinical + virtual column);
##   - /values for probes, at most 100 names per request, kept in a small
##     per-process cache keyed by dataset version and name;
##   - categorical columns become factors the way gitr() makes them
##     (as.factor on the text: the same level order).
## ============================================================================
T2_API_URL = sub("/+$", "", Sys.getenv("T2_API_URL", ""))
t2_api_on = function() nzchar(T2_API_URL)

.t2_api = new.env(parent = emptyenv())
.t2_api$values = new.env(parent = emptyenv())   # "<ds>|<version>|<probe>" -> column
.t2_api$values_keys = character(0)
T2_API_VALUES_CACHE = 400                       # probe columns kept per process

## GET a path of the service, parsed JSON (lists, not simplified). `retry`:
## the service answers 503 for a few seconds while a database file is
## replaced, and a transient network error is retried once. A 409 means the
## dataset version in the URL is no longer the one served (a database was
## deployed; the service restarts with a new version): the datasets list is
## forgotten so the next t2_api_version() re-reads it, and the condition
## `t2_api_version_changed` is signalled for t2_api_versioned() to retry.
t2_api_get = function(path, retry = 2) {
  url = paste0(T2_API_URL, path)
  h = curl::new_handle(accept_encoding = "gzip", followlocation = TRUE, connecttimeout = 10, timeout = 120)
  curl::handle_setheaders(h, "User-Agent" = "T2-shiny (gitr over t2api)")
  for (i in seq_len(retry + 1)) {
    r = tryCatch(curl::curl_fetch_memory(url, handle = h), error = function(e) e)
    if (inherits(r, "error")) { if (i > retry) stop("t2api: ", conditionMessage(r), " (", url, ")"); Sys.sleep(1); next }
    if (r$status_code == 503 && i <= retry) { Sys.sleep(3); next }
    if (r$status_code == 409) {
      .t2_api$datasets = NULL
      stop(structure(class = c("t2_api_version_changed", "error", "condition"),
                     list(message = paste("t2api: dataset version changed for", path), call = NULL)))
    }
    if (r$status_code != 200)
      stop("t2api: HTTP ", r$status_code, " for ", path, ": ", substr(rawToChar(r$content), 1, 200))
    return(jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE))
  }
}

## /v1/datasets, read once per process (a changed version is noticed on the
## next bundle load: the server keys the bundle cache by version too)
t2_api_datasets = function(refresh = FALSE) {
  if (refresh || is.null(.t2_api$datasets)) .t2_api$datasets = t2_api_get("/v1/datasets")$datasets
  .t2_api$datasets
}
t2_api_version = function(ds) {
  for (d in t2_api_datasets()) if (identical(d$name, ds)) return(d$version)
  stop("t2api: unknown dataset ", ds)
}
## a request whose URL names the dataset version: built by make_path(version);
## asked again with the fresh version when the served version has changed
## (a database deploy), so a long-running app never sticks on 409
t2_api_versioned = function(ds, make_path) {
  for (attempt in 1:2) {
    v = t2_api_version(ds)
    r = tryCatch(t2_api_get(make_path(v)), t2_api_version_changed = function(e) NULL)
    if (!is.null(r)) return(list(result = r, version = v))
  }
  stop("t2api: the dataset version of ", ds, " keeps changing")
}
t2_api_meta = function(ds) {
  key = paste(ds, t2_api_version(ds))
  if (is.null(.t2_api[[paste0("meta|", key)]])) .t2_api[[paste0("meta|", key)]] = t2_api_get(sprintf("/v1/%s/meta", ds))
  .t2_api[[paste0("meta|", key)]]
}

## an API column object -> an R vector: numbers with NA, or character with NA
t2_api_vector = function(col) {
  if (identical(col$kind, "num")) {
    vapply(col$values, function(v) if (is.null(v)) NA_real_ else as.numeric(v), 0)
  } else {
    codes = unlist(col$codes); lv = unlist(col$levels)
    out = rep(NA_character_, length(codes))
    out[codes >= 0] = lv[codes[codes >= 0] + 1]
    out
  }
}

## the clinical table of a dataset as a data frame: `sample` first, then
## every clinical and virtual column, in the service's order (untyped:
## character / numeric, as DBI::dbReadTable would give it). Once per version.
t2_api_clinical = function(ds) {
  key = paste0("clin|", ds, "|", t2_api_version(ds))
  hit = .t2_api[[key]]
  if (!is.null(hit)) return(hit)
  got = t2_api_versioned(ds, function(v) sprintf("/v1/%s/clinical?v=%s", ds, v))
  cl = got$result
  out = data.frame(sample = as.character(unlist(cl$samples)), stringsAsFactors = FALSE, check.names = FALSE)
  for (col in cl$columns) out[[col$name]] = t2_api_vector(col)
  .t2_api[[paste0("clin|", ds, "|", got$version)]] = out
  out
}

## the values of probes (not clinical columns): a named list of vectors in
## sample order, each carrying its data type in attr "t2type"; a name the
## dataset lacks is absent from the result (and remembered as missing, so it is
## not asked for again on every plot)
t2_api_values = function(ds, probes) {
  v = t2_api_version(ds)
  key = function(p) paste0(ds, "|", v, "|", p)
  out = list()
  todo = character(0)
  for (p in unique(probes)) {
    hit = .t2_api$values[[key(p)]]
    if (is.null(hit)) todo = c(todo, p)
    else if (!identical(hit, "missing")) out[[p]] = hit
  }
  remember = function(p, value) {
    .t2_api$values[[key(p)]] = value
    .t2_api$values_keys = c(.t2_api$values_keys, key(p))
  }
  for (chunk in split(todo, ceiling(seq_along(todo) / 100))) {
    got = t2_api_versioned(ds, function(vv) sprintf("/v1/%s/values?v=%s&probes=%s", ds, vv,
                                                    utils::URLencode(paste(chunk, collapse = ","), reserved = TRUE)))
    res = got$result
    if (!identical(got$version, v)) { v = got$version; key = function(p) paste0(ds, "|", v, "|", p) }
    for (col in res$columns) {
      out[[col$name]] = structure(t2_api_vector(col), t2type = col$type)
      remember(col$name, out[[col$name]])
    }
    for (p in as.character(unlist(res$missing))) remember(p, "missing")
  }
  if (length(.t2_api$values_keys) > T2_API_VALUES_CACHE) {
    drop = head(.t2_api$values_keys, length(.t2_api$values_keys) - T2_API_VALUES_CACHE)
    rm(list = intersect(drop, ls(.t2_api$values)), envir = .t2_api$values)
    .t2_api$values_keys = setdiff(.t2_api$values_keys, drop)
  }
  out
}

## gitr() over the service: the same arguments and the same frame. `dbfile`
## is the dataset NAME here (the bundle's $path in API mode).
gitr_api = function(probes, phenos = TRUE, nonormal = FALSE, noheme = FALSE,
                    cohort = 'all', makefactors = TRUE, dbfile = "TCGA",
                    roles = gitr_default_roles, keep_samples = NULL, rules = list(), ...) {
  ds = dbfile
  if (is.null(roles)) roles = gitr_default_roles
  role_has = function(key) { v = roles[[key]]; !is.null(v) && length(v) == 1 && !is.na(v) && nzchar(v) }
  probes = unique(probes); probes = probes[!is.na(probes) & nzchar(probes)]
  clin = t2_api_clinical(ds)
  ## the virtual columns exist only in the phenos frame (gitr() synthesises
  ## them there); a name asked for without phenos is a clinical column or a probe
  virtual_cols = c('subtype', 'cohort', 'lcohort')
  is_clin = probes %in% colnames(clin) & !(probes %in% virtual_cols)
  is_virtual = probes %in% virtual_cols
  db_probes = probes[!is_clin & !is_virtual]
  vals = if (length(db_probes)) t2_api_values(ds, db_probes) else list()
  if (phenos) out = clin
  else out = clin[, unique(c('sample', probes[is_clin])), drop = FALSE]
  ## probe columns in gitr()'s order: the numeric ones sorted (tidyr::spread),
  ## then the categorical ones sorted, then the unknown names (all NA)
  numeric = vapply(vals, is.numeric, NA)
  for (p in c(sort(names(vals)[numeric]), sort(names(vals)[!numeric]), setdiff(db_probes, names(vals))))
    out[[p]] = if (!is.null(vals[[p]])) as.vector(vals[[p]]) else rep(NA, nrow(out))   # plain vector: the t2type attribute stays on the cached copy
  ## a name the service does not know is an all-NA column; gitr() still makes it
  ## a factor when its suffix names a factor data type (.mut, .cnc ...)
  if (makefactors) {
    dt = t2_api_meta(ds)$datatypes
    for (p in setdiff(db_probes, names(vals)))
      if (identical(dt[[sub(".*\\.", "", p)]], "factor")) out[[p]] = as.factor(out[[p]])
  }
  cat(sprintf("%d probes from %s\n", length(db_probes), T2_API_URL))   # as gitr() prints its row counts
  ## filters, on the raw values, as gitr()
  keep = t2_sample_keep(out, roles, cohort = cohort, nonormal = nonormal, noheme = noheme, rules = rules)
  if (!is.null(keep_samples)) keep = keep & (out$sample %in% keep_samples)
  if (!all(keep)) out = out[keep, , drop = FALSE]
  stc = roles$sampletype_col
  if (phenos && role_has('sampletype_col') && stc %in% colnames(out) && !is.null(roles$sampletype_levels))
    out[[stc]] = factor(out[[stc]], levels = roles$sampletype_levels)
  ## a probe the service reports as categorical with numbers for levels is a
  ## numeric probe declared "factor" (.mut, .cnc): gitr() holds its numbers and
  ## makes the factor from them (levels in numeric order), so do the same
  numlike = function(x) { v = x[!is.na(x)]; length(v) > 0 && !anyNA(suppressWarnings(as.numeric(v))) }
  for (p in db_probes) if (is.character(out[[p]]) && numlike(out[[p]])) out[[p]] = as.numeric(out[[p]])
  if (makefactors) {
    ## a probe column becomes a factor only when its data type is declared
    ## "factor" in the datatypes table (gitr()'s rule; every text type is, today);
    ## every clinical text column becomes a factor
    dt = t2_api_meta(ds)$datatypes
    is_factor_type = function(p) identical(dt[[attr(vals[[p]], "t2type") %||% ""]], "factor")
    for (p in intersect(db_probes, names(vals))) {
      if (is.character(vals[[p]]) && is_factor_type(p)) out[[p]] = as.factor(out[[p]])
    }
    for (n in setdiff(colnames(out), db_probes)) if (is.character(out[[n]])) out[[n]] = as.factor(out[[n]])
  }
  out = droplevels(out)
  rownames(out) = NULL
  data.frame(out, check.names = FALSE, stringsAsFactors = FALSE)
}

## attributes travel with a vector only until it is modified; keep the type
## lookup robust to that
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

## the dataset descriptor (dataset_registry.R's .resolve_roles) from /meta
t2_api_resolve = function(ds) {
  m = t2_api_meta(ds)
  chr = function(x) as.character(unlist(x))
  r = m$roles
  roles = list(cohort_col = r$cohort_col %||% NA_character_, subtype_col = r$subtype_col %||% NA_character_,
               sampletype_col = r$sampletype_col %||% NA_character_,
               normal_label = chr(r$normal_label), heme_values = chr(r$heme_values),
               sampletype_levels = chr(r$sampletype_levels))
  for (k in c('cohort_col', 'subtype_col', 'sampletype_col')) if (!nzchar(roles[[k]] %||% "")) roles[[k]] = NA_character_
  if (length(roles$normal_label) == 0) roles$normal_label = NA_character_
  if (length(roles$sampletype_levels) == 0) roles$sampletype_levels = NULL
  d = m$defaults
  defaults = list(x = d$x %||% "cohort", y = d$y %||% "", color = d$color %||% "", size = d$size %||% "",
                  condition = d$condition %||% "", cohorts = .split_meta(d$cohorts))
  list(roles = roles, defaults = defaults, title = m$title %||% ds, label = m$label %||% m$title %||% ds)
}

## the bundle (lib.R's .read_dataset_bundle) from the service
t2_api_bundle = function(info) {
  ds = info$name; roles = info$roles
  m = t2_api_meta(ds)
  chr = function(x) as.character(unlist(x))
  menu = chr(t2_api_versioned(ds, function(v) sprintf("/v1/%s/probes?all=1&v=%s", ds, v))$result$probes)
  clin = t2_api_clinical(ds)
  handles = c('subtype', 'cohort', if (!is.na(roles$sampletype_col %||% NA)) roles$sampletype_col)
  mygenes = setdiff(menu, handles)
  co = m$cohorts
  mycohorts = if (length(co)) {
    v = chr(lapply(co, `[[`, "cohort"))
    if (!is.null(co[[1]]$cohortstring)) names(v) = chr(lapply(co, `[[`, "cohortstring"))
    v
  } else character(0)
  presets = lapply(m$presets, function(p) list(
    label = p$label, description = p$description %||% "", default = isTRUE(p$default), source = p$source %||% "",
    rules = lapply(p$rules, function(r) list(column = r$column, op = r$op, values = chr(r$values))),
    n_samples = as.integer(p$n_samples)))
  sources = if (length(m$sources)) lapply(m$sources, function(s) list(
    label = s$label, description = s$description %||% "",
    rules = lapply(s$rules, function(r) list(column = r$column, op = r$op, values = chr(r$values))),
    n_samples = as.integer(s$n_samples), cohorts = chr(s$cohorts), groups = chr(s$groups),
    exclusions = chr(s$exclusions), single_level_columns = chr(s$single_level_columns)))
  else t2_sources(clin, roles, presets, unname(mycohorts), info$label)   # a service older than /meta sources
  types = if (length(m$types)) do.call(rbind, lapply(m$types, function(t) as.data.frame(
    lapply(c(type = "type", description = "description", example = "example", reference = "reference",
             source_file = "source_file", source_url = "source_url"), function(k) t[[k]] %||% ""),
    stringsAsFactors = FALSE))) else data.frame(type = character(0))
  list(name = ds, path = ds, title = info$title, label = info$label, roles = roles, defaults = info$defaults,
       mygenes = mygenes, probes = mygenes, samples = clin$sample, mutationsamples = character(0),
       mycohorts = mycohorts, mygenesplus = menu, clin = clin, presets = presets, sources = sources,
       types = types, version = t2_api_version(ds),
       descriptions = stats::setNames(chr(lapply(m$clinical_descriptions, `[[`, "description")),
                                      chr(lapply(m$clinical_descriptions, `[[`, "column"))))
}
