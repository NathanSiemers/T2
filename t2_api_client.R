## t2_api_client.R
## ============================================================================
## The T2 data layer over the t2api service (T2Mobile/docs/API.md): the ONLY
## data layer of the Shiny app. The environment variable
##
##     T2_API_URL=http://t2api:8080            (the service's Docker network)
##     T2_API_URL=https://www.fiveprime.org/api/t2   (from anywhere)
##
## names the service; global.R stops the app with one message when it is unset
## (t2_api_require()). The app opens no database: datasets, bundles and gitr()
## all go to the service. The SQLite path (gitr() over a file, dataset_registry.R)
## stays in the repository as the builders' library and as the equivalence
## ORACLE of the tests: test_gitr_api.R and T2Mobile/service/test_equivalence.R
## hold this layer to it, value for value.
##
## The client DERIVES NOTHING (DATASET-CONTRACT.md s.2-3): handles, time-to-event
## variables, type labels, About prose, default cohorts and the typed variable
## list are read from /meta and /probes; a service that lacks one of them is an
## old service and the client says so (t2_api_need), it never falls back to a
## rule of its own.
##
## What is done here is transport, caching and R typing:
##   - /clinical once per dataset version, factored once (per version) the way
##     gitr() makes factors; each call applies its row filters on top;
##   - /values for probes, at most 100 names per request, kept in a bounded
##     per-process cache keyed by dataset version and name;
##   - JSON parsed to vectors (simplifyVector) for the big answers.
## ============================================================================
if (!exists("t2_cache")) source("t2_util.R")
T2_API_URL = sub("/+$", "", Sys.getenv("T2_API_URL", ""))
t2_api_on = function() nzchar(T2_API_URL)

## The app's one start-up check: the data layer is the service, so no service, no app.
t2_api_require = function() {
  if (!t2_api_on())
    stop("T2_API_URL is not set. The T2 app reads all its data from the T2 query service: set T2_API_URL ",
         "(for example http://t2api:8080 in the service's Docker network, or http://127.0.0.1:3861 for the ",
         "development service) in the environment or the site's Renviron, and start the app again.", call. = FALSE)
  invisible(TRUE)
}

.t2_api = new.env(parent = emptyenv())
T2_API_VALUES_CACHE = 400                       # probe columns kept per process
.t2_api$values = t2_cache(T2_API_VALUES_CACHE)  # "<ds>|<version>|<probe>" -> column (or "missing")
.t2_api$meta   = t2_cache(8)                    # "<ds>|<version>" -> /meta
.t2_api$clin   = t2_cache(8)                    # "<ds>|<version>" -> the clinical frame (character / numeric)
.t2_api$fillopts = t2_cache(200)                # "<ds>|<version>|set|<probes>" -> the fills the answer offered for that set
.t2_api$frames = t2_cache(8)                    # "<ds>|<version>|<roles>" -> list(raw, fac): the frame and its factored twin
.t2_api$menu   = t2_cache(8)                    # "<ds>|<version>" -> the typed variable list

## percent-encode every reserved character of one value; unlike utils::URLencode it
## also encodes a value that already contains %XX ("x%41y" -> "x%2541y")
t2_urlencode = function(x) utils::URLencode(as.character(x), reserved = TRUE, repeated = TRUE)

## GET a path of the service, parsed JSON. `simplify = FALSE` gives lists (for
## /meta, which is small and nested); TRUE gives vectors for the big answers
## (/values, /probes, /clinical: arrays of numbers / strings become atomic
## vectors, null becomes NA; callers pin the types). `retry`: the service
## answers 503 for a few seconds while a database file is replaced, and a
## transient network error is retried once. A 409 means the dataset version in
## the URL is no longer the one served (a database was deployed; the service
## restarts with a new version): the datasets list is forgotten so the next
## t2_api_version() re-reads it, and the condition `t2_api_version_changed` is
## signalled for t2_api_versioned() to retry.
t2_api_get = function(path, retry = 1, simplify = FALSE) {
  url = paste0(T2_API_URL, path)
  ## a worker is held for at most about a minute (2 tries, 3 s to connect, 30 s in all):
  ## during a service restart the visitor gets "busy" quickly rather than a stuck page
  h = curl::new_handle(accept_encoding = "gzip", followlocation = TRUE, connecttimeout = 3, timeout = 30)
  curl::handle_setheaders(h, "User-Agent" = "T2-shiny (gitr over t2api)")
  for (i in seq_len(retry + 1)) {
    r = tryCatch(curl::curl_fetch_memory(url, handle = h), error = function(e) e)
    if (inherits(r, "error")) { if (i > retry) stop("t2api: the service is busy or not answering: ", conditionMessage(r), " (", substr(url, 1, 200), ")"); Sys.sleep(1); next }
    if (r$status_code == 503 && i <= retry) { Sys.sleep(1); next }
    if (r$status_code == 409) {
      .t2_api$datasets = NULL
      stop(structure(class = c("t2_api_version_changed", "error", "condition"),
                     list(message = paste("t2api: dataset version changed for", path), call = NULL)))
    }
    if (r$status_code != 200)
      stop("t2api: HTTP ", r$status_code, " for ", substr(path, 1, 200), ": ", substr(rawToChar(r$content), 1, 200))
    return(jsonlite::fromJSON(rawToChar(r$content), simplifyVector = simplify,
                              simplifyDataFrame = FALSE, simplifyMatrix = FALSE))
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
t2_api_versioned = function(ds, make_path, simplify = FALSE) {
  for (attempt in 1:2) {
    v = t2_api_version(ds)
    r = tryCatch(t2_api_get(make_path(v), simplify = simplify), t2_api_version_changed = function(e) NULL)
    if (!is.null(r)) return(list(result = r, version = v))
  }
  stop("t2api: the dataset version of ", ds, " keeps changing")
}

## A required member of an answer of the service: its absence means the service
## is older than this app (the contract's fields are never absent). No fallback.
t2_api_need = function(x, field, what) {
  if (is.null(x[[field]]))
    stop("The T2 query service at ", T2_API_URL, " is older than this app: ", what, " has no '", field,
         "' (DATASET-CONTRACT.md). Deploy the service (ops/deploy.sh service) before the app.", call. = FALSE)
  x[[field]]
}

t2_api_meta = function(ds) {
  key = paste(ds, t2_api_version(ds))
  hit = .t2_api$meta$get(key)
  if (!is.null(hit)) return(hit)
  m = t2_api_get(sprintf("/v1/%s/meta", ds))
  what = sprintf("/v1/%s/meta", ds)
  for (f in c("handles", "tte_variables", "type_labels", "about", "default_cohorts", "survival_endpoints"))
    t2_api_need(m, f, what)
  .t2_api$meta$put(key, m)
}

## an API column object -> an R vector: numbers with NA, or character with NA.
## Works on both parsings (lists and simplified vectors); the types are pinned.
t2_api_vector = function(col) {
  if (identical(col$kind, "num")) {
    v = col$values
    if (is.list(v)) vapply(v, function(z) if (is.null(z)) NA_real_ else as.numeric(z), 0) else as.numeric(v)
  } else {
    codes = as.integer(unlist(col$codes)); lv = as.character(unlist(col$levels))
    out = rep(NA_character_, length(codes))
    i = codes >= 0L
    out[i] = lv[codes[i] + 1L]
    out
  }
}

## the clinical table of a dataset as a data frame: `sample` first, then
## every clinical and virtual column, in the service's order (untyped:
## character / numeric, as DBI::dbReadTable would give it). Once per version.
t2_api_clinical = function(ds) {
  key = paste(ds, t2_api_version(ds))
  hit = .t2_api$clin$get(key)
  if (!is.null(hit)) return(hit)
  got = t2_api_versioned(ds, function(v) sprintf("/v1/%s/clinical?v=%s", ds, v), simplify = TRUE)
  cl = got$result
  out = data.frame(sample = as.character(unlist(cl$samples)), stringsAsFactors = FALSE, check.names = FALSE)
  for (col in cl$columns) out[[col$name]] = t2_api_vector(col)
  .t2_api$clin$put(paste(ds, got$version), out)
}

## The clinical frame as gitr() types it, ONCE per (dataset, version, roles):
## list(raw = the frame, fac = every text column a factor (as.factor on the text:
## the same level order as gitr()), the sample-type column with the dataset's
## declared level order). Row filters are evaluated on `raw` (before the
## sample-type column is re-levelled: a value outside the declared levels must
## stay visible to a rule) and applied to `fac`.
t2_api_frames = function(ds, roles) {
  stc = t2_role(roles, "sampletype_col")
  key = paste(ds, t2_api_version(ds), stc %||% "", paste(roles$sampletype_levels, collapse = "|"), sep = "|")
  hit = .t2_api$frames$get(key)
  if (!is.null(hit)) return(hit)
  raw = t2_api_clinical(ds)
  fac = raw
  for (n in colnames(fac)) if (is.character(fac[[n]])) fac[[n]] = as.factor(fac[[n]])
  if (!is.null(stc) && stc %in% colnames(raw) && !is.null(roles$sampletype_levels))
    fac[[stc]] = factor(raw[[stc]], levels = roles$sampletype_levels)
  .t2_api$frames$put(key, list(raw = raw, fac = fac))
}

## the values of probes (not clinical columns): a named list of vectors in
## sample order, each carrying its data type in attr "t2type"; a name the
## dataset lacks is absent from the result (and remembered as missing, so it is
## not asked for again on every plot).
## fill: the not-detected values ("na" | "zero" | "floor", the service's `fill`). The ANSWER
## decides what is on offer: the list carries attr "fill_options", the union the service
## reported for exactly these probes (cached per probe set: the cached columns alone
## cannot tell), and, for a fill that was applied, attrs "fill", "filled", "tested_n"
## (named by probe; only probes with cells changed). A fill the answer does not list is
## not asked for: the values come back as "na" and attr "fill" is absent.
t2_api_values = function(ds, probes, fill = "na") {
  v = t2_api_version(ds)
  fill = if (fill %in% c("zero", "floor")) fill else "na"
  probes = unique(probes)
  key = function(p, f = "na") paste0(ds, "|", v, "|", p, if (f != "na") paste0("|fill=", f))
  ask = function(chunk, f) t2_api_versioned(ds, function(vv) sprintf("/v1/%s/values?v=%s&probes=%s%s", ds, vv,
                                  t2_urlencode(paste(chunk, collapse = ",")),
                                  if (f != "na") paste0("&fill=", f) else ""), simplify = TRUE)
  ## the values of all the probes under fill f: list(cols, options). `force` asks for every probe
  ## (the answer's fill_options is for the probes of THAT request), else only for the uncached ones.
  fetch = function(f, force = FALSE) {
    out = list(); todo = character(0); opts = character(0)
    for (p in probes) {
      hit = if (force) NULL else .t2_api$values$get(key(p, f))
      if (is.null(hit)) todo = c(todo, p)
      else if (!identical(hit, "missing")) out[[p]] = hit
    }
    for (chunk in split(todo, ceiling(seq_along(todo) / 100))) {
      f1 = f
      got = tryCatch(ask(chunk, f), error = function(e)
        if (f != "na" && grepl("fill not available", conditionMessage(e), fixed = TRUE)) NULL else stop(e))
      if (is.null(got)) { got = ask(chunk, "na"); f1 = "na" }     # a chunk none of whose probes offers the fill
      res = got$result
      if (!identical(got$version, v)) v <<- got$version
      opts = union(opts, as.character(unlist(res$fill_options)))
      fl = unlist(res$filled); tn = unlist(res$tested_n)
      one = function(x, nm) if (length(x) && nm %in% names(x)) as.integer(x[[nm]]) else NULL
      for (col in res$columns) {
        out[[col$name]] = structure(t2_api_vector(col), t2type = col$type,
                                    t2filled = one(fl, col$name), t2tested = one(tn, col$name))
        .t2_api$values$put(key(col$name, f1), out[[col$name]])
      }
      for (p in as.character(unlist(res$missing))) .t2_api$values$put(key(p, f1), "missing")
    }
    list(cols = out, options = opts, fresh = length(todo) == length(probes))
  }
  ## the options the answer gave for this exact set of probes: asked once per set, then remembered
  setkey = paste0(ds, "|", v, "|set|", paste(sort(probes), collapse = ","))
  opts = .t2_api$fillopts$get(setkey)
  base = NULL
  if (is.null(opts)) {
    ## the cached columns carry their type (attr t2type) and the meta says which fills a type offers; only
    ## when the meta says nothing is the answer asked (once, forced if some columns came from the cache)
    base = fetch("na")
    mt = tryCatch(t2_api_meta(ds)$types, error = function(e) NULL)
    tf = list(); for (t in mt) tf[[t$type]] = as.character(unlist(t$fill_options))
    if (!any(lengths(tf) > 0) && !base$fresh) base = fetch("na", force = TRUE)
    tys = unique(unlist(lapply(base$cols, function(x) attr(x, "t2type"))))
    say = unlist(tf[intersect(tys, names(tf))])
    opts = c("na", "zero", "floor")[c("na", "zero", "floor") %in% c("na", say, base$options)]
    .t2_api$fillopts$put(setkey, opts)
  }
  if (fill != "na" && fill %in% opts) {
    out = fetch(fill)$cols
    fl = vapply(out, function(x) attr(x, "t2filled") %||% 0L, 0L)
    tn = vapply(out, function(x) attr(x, "t2tested") %||% NA_integer_, 0L)
    fl = fl[fl > 0]
    ## the samples whose cell the fill set: missing in the na frame, a value in the filled one
    nacols = fetch("na")$cols
    smp = t2_api_clinical(ds)$sample
    ids = lapply(stats::setNames(names(fl), names(fl)), function(p) smp[is.na(nacols[[p]]) & !is.na(out[[p]])])
    return(structure(out, fill_options = opts, fill = fill, filled = fl, tested_n = tn[names(fl)], filled_ids = ids))
  }
  if (is.null(base)) base = fetch("na")
  structure(base$cols, fill_options = opts)
}

## drop the unused levels of the factor columns `cols` of a frame; only a column
## that has an empty level is touched (tabulate is a single pass in C)
t2_droplevels_cols = function(df, cols) {
  for (n in intersect(cols, colnames(df))) {
    x = df[[n]]
    if (is.factor(x) && any(tabulate(x, nlevels(x)) == 0L)) df[[n]] = droplevels(x)
  }
  df
}

## gitr() over the service: the same arguments and the same frame (the tests hold
## it to the oracle). `dbfile` is the dataset NAME here (the bundle's $path).
## Levels are dropped for the columns that were ASKED for (and `sample`, the
## sample-type column); a clinical column nobody asked for may keep levels that
## the filters emptied.
gitr_api = function(probes, phenos = TRUE, nonormal = FALSE, noheme = FALSE,
                    cohort = 'all', makefactors = TRUE, dbfile = "TCGA",
                    roles = NULL, keep_samples = NULL, rules = list(), fill = "na", ...) {
  ds = dbfile
  if (is.null(roles)) roles = t2_api_resolve(ds)$roles
  stc = t2_role(roles, 'sampletype_col')
  probes = unique(probes); probes = probes[!is.na(probes) & nzchar(probes)]
  fr = t2_api_frames(ds, roles)
  clin = fr$raw
  ## the virtual columns exist only in the phenos frame (gitr() synthesises
  ## them there); a name asked for without phenos is a clinical column or a probe
  virtual_cols = c('subtype', 'cohort', 'lcohort')
  is_clin = probes %in% colnames(clin) & !(probes %in% virtual_cols)
  is_virtual = probes %in% virtual_cols
  db_probes = probes[!is_clin & !is_virtual]
  vals = if (length(db_probes)) t2_api_values(ds, db_probes, fill) else list()
  base = if (makefactors) fr$fac else {
    ## no factors, except the sample-type column's declared level order (as gitr())
    b = clin
    if (phenos && !is.null(stc) && stc %in% colnames(b) && !is.null(roles$sampletype_levels))
      b[[stc]] = fr$fac[[stc]]
    b
  }
  if (phenos) out = base
  else {
    cols = unique(c('sample', probes[is_clin]))
    out = base[, cols, drop = FALSE]
    if (makefactors && !is.null(stc) && stc %in% cols) out[[stc]] = as.factor(clin[[stc]])   # no re-levelling without phenos
  }
  ## probe columns in gitr()'s order: the numeric ones sorted (tidyr::spread),
  ## then the categorical ones sorted, then the unknown names (all NA)
  numeric = vapply(vals, is.numeric, NA)
  for (p in c(sort(names(vals)[numeric]), sort(names(vals)[!numeric]), setdiff(db_probes, names(vals))))
    out[[p]] = if (!is.null(vals[[p]])) as.vector(vals[[p]]) else rep(NA, nrow(out))   # plain vector: the t2type attribute stays on the cached copy
  ## a name the service does not know is an all-NA column; gitr() still makes it
  ## a factor when its suffix names a factor data type (.mut, .cnc ...): the
  ## builders' naming convention, kept only for names without data
  dt = if (makefactors) t2_api_meta(ds)$datatypes else NULL
  if (makefactors)
    for (p in setdiff(db_probes, names(vals)))
      if (identical(dt[[sub(".*\\.", "", p)]], "factor")) out[[p]] = as.factor(out[[p]])
  cat(sprintf("%d probes from %s\n", length(db_probes), T2_API_URL))   # as gitr() prints its row counts
  ## filters, on the raw values, as gitr()
  fframe = if (phenos) clin else out
  keep = t2_sample_keep(fframe, roles, cohort = cohort, nonormal = nonormal, noheme = noheme, rules = rules)
  if (!is.null(keep_samples)) keep = keep & (fframe$sample %in% keep_samples)
  if (!all(keep)) out = out[keep, , drop = FALSE]
  ## a probe the service reports as categorical with numbers for levels is a
  ## numeric probe declared "factor" (.mut, .cnc): gitr() holds its numbers and
  ## makes the factor from them (levels in numeric order), so do the same
  numlike = function(x) { v = x[!is.na(x)]; length(v) > 0 && !anyNA(suppressWarnings(as.numeric(v))) }
  for (p in db_probes) if (is.character(out[[p]]) && numlike(out[[p]])) out[[p]] = as.numeric(out[[p]])
  if (makefactors) {
    ## a probe column becomes a factor only when its data type is declared
    ## "factor" in the datatypes table (gitr()'s rule; every text type is, today)
    is_factor_type = function(p) identical(dt[[attr(vals[[p]], "t2type") %||% ""]], "factor")
    for (p in intersect(db_probes, names(vals)))
      if (is.character(vals[[p]]) && is_factor_type(p)) out[[p]] = as.factor(out[[p]])
  }
  out = t2_droplevels_cols(out, c('sample', stc, probes))
  rownames(out) = NULL
  ## the answer's word on not-detected values (what the app reads to offer the choice)
  attr(out, "fill_options") = attr(vals, "fill_options") %||% "na"
  if (!is.null(attr(vals, "fill", exact = TRUE))) {
    attr(out, "fill") = attr(vals, "fill", exact = TRUE); attr(out, "filled") = attr(vals, "filled"); attr(out, "tested_n") = attr(vals, "tested_n")
    attr(out, "filled_rows") = lapply(attr(vals, "filled_ids"), function(i) as.character(out$sample) %in% as.character(i))   # after the filters, as gitr()
  }
  out
}

## the dataset descriptor (what the bundle and the plot context carry) from /meta
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
  ## the opening cohorts are the array `default_cohorts`; defaults$cohorts is the comma
  ## string kept for the shipped iPhone 1.0 and is never read here
  defaults = list(x = d$x %||% "cohort", y = d$y %||% "", color = d$color %||% "", size = d$size %||% "",
                  condition = d$condition %||% "", cohorts = chr(m$default_cohorts))
  list(roles = roles, defaults = defaults, title = m$title %||% ds, label = m$label %||% m$title %||% ds)
}

## The typed variable list of a dataset (/probes?all=1): list(name, section, type, kind) of
## parallel vectors -- section "handle" | "probe" | "clinical", type a types name, kind "num" | "cat"
t2_api_menu = function(ds) {
  key = paste(ds, t2_api_version(ds))
  hit = .t2_api$menu$get(key)
  if (!is.null(hit)) return(hit)
  got = t2_api_versioned(ds, function(v) sprintf("/v1/%s/probes?all=1&v=%s", ds, v), simplify = TRUE)
  pl = got$result; what = sprintf("/v1/%s/probes?all=1", ds)
  for (f in c("probes", "section", "type", "kind", "types")) t2_api_need(pl, f, what)
  types = as.character(unlist(pl$types))
  .t2_api$menu$put(paste(ds, got$version), list(
    name = as.character(unlist(pl$probes)),
    section = c("handle", "probe", "clinical")[as.integer(unlist(pl$section)) + 1L],
    type = types[as.integer(unlist(pl$type)) + 1L],
    kind = c("num", "cat")[as.integer(unlist(pl$kind)) + 1L]))
}

## the bundle (lib.R's load_dataset_bundle) from the service: everything the app knows
## of a dataset, as the service declares it
t2_api_bundle = function(ds) {
  info = t2_api_resolve(ds)
  m = t2_api_meta(ds)
  chr = function(x) as.character(unlist(x))
  menu = t2_api_menu(ds)
  clin = t2_api_clinical(ds)
  handles = data.frame(name = chr(lapply(m$handles, `[[`, "name")), role = chr(lapply(m$handles, `[[`, "role")),
                       stringsAsFactors = FALSE)
  mygenes = menu$name[menu$section == "probe"]
  clin_vars = menu$name[menu$section == "clinical"]
  mygenesplus = unique(c(handles$name, mygenes, clin_vars))
  co = m$cohorts
  mycohorts = if (length(co)) {
    v = chr(lapply(co, `[[`, "cohort"))
    if (!is.null(co[[1]]$cohortstring)) names(v) = chr(lapply(co, `[[`, "cohortstring"))
    v
  } else character(0)
  presets = lapply(m$presets, function(p) list(
    label = p$label, description = p$description %||% "", default = isTRUE(p$default), source = p$source %||% "",
    rules = t2_as_rules(p$rules), n_samples = as.integer(p$n_samples)))
  sources = lapply(t2_api_need(m, "sources", sprintf("/v1/%s/meta", ds)), function(s) list(
    label = s$label, description = s$description %||% "", rules = t2_as_rules(s$rules),
    n_samples = as.integer(s$n_samples), cohorts = chr(s$cohorts), groups = chr(s$groups),
    exclusions = chr(s$exclusions), single_level_columns = chr(s$single_level_columns)))
  types = if (length(m$types)) do.call(rbind, lapply(m$types, function(t) as.data.frame(
    lapply(c(type = "type", description = "description", example = "example", reference = "reference",
             source_file = "source_file", source_url = "source_url", label = "label",
             reference_title = "reference_title", reference_authors = "reference_authors",
             reference_journal = "reference_journal", reference_year = "reference_year",
             reference_url = "reference_url"), function(k) as.character(t[[k]] %||% "")),
    stringsAsFactors = FALSE))) else data.frame(type = character(0))
  tte = stats::setNames(lapply(m$tte_variables, function(t) list(
    name = t$name, label = t$label %||% t$name, event_col = t$event_col, time_col = t$time_col,
    time_unit = t$time_unit %||% "days", description = t$description %||% "")),
    chr(lapply(m$tte_variables, `[[`, "name")))
  about = lapply(m$about[c("description", "citation", "attribution", "url")], function(x) x %||% "")
  ## the dataset's bibliography (seminal papers), as a list of records; empty when the service has none
  about$references = lapply(m$about$references, function(r) as.list(r))
  list(name = ds, path = ds, title = info$title, label = info$label, roles = info$roles, defaults = info$defaults,
       handles = handles, mygenes = mygenes, clin_vars = clin_vars, mygenesplus = mygenesplus,
       menu = menu, names_lower = tolower(mygenesplus),
       samples = clin$sample, mycohorts = mycohorts, presets = presets, sources = sources,
       types = types, tte = tte, type_labels = unlist(m$type_labels) %||% character(0), about = about,
       default_cohorts = chr(m$default_cohorts), datatypes = unlist(m$datatypes) %||% character(0),
       version = t2_api_version(ds), clin = clin,
       descriptions = stats::setNames(chr(lapply(m$clinical_descriptions, `[[`, "description")),
                                      chr(lapply(m$clinical_descriptions, `[[`, "column"))))
}

## the datasets the service serves, and the one opened first (TCGA when present)
t2_datasets = function() vapply(t2_api_datasets(), `[[`, "", "name")
t2_default_dataset = function() {
  d = t2_datasets()
  if ("TCGA" %in% d) "TCGA" else if (length(d)) d[1] else stop("t2api: the service serves no dataset")
}
