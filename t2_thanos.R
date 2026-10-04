## t2_thanos.R
## ============================================================================
## Thanos (interactive multi-field cross-filtering) for T2.
##
## Thanos is a separate project: a Shiny module that shows a live histogram +
## filter widget per chosen column and tells the host app which ROWS survive.
## This file is the whole bridge between the two:
##
##   1. load Thanos (HAVE_THANOS says whether that worked -- the app runs
##      without the Filter tab when it didn't)
##   2. backend_t2(bundle): the Thanos "backend" for a T2 dataset. Rows are the
##      dataset's samples; columns are every variable T2 can plot. Columns are
##      fetched lazily through gitr(), so the Filter tab sees exactly the
##      values (types, sparse zeros, NAs) the plot sees.
##
## Row <-> sample mapping: Thanos speaks row numbers, T2 speaks sample ids.
## backend$samples[i] is the sample id of row i (clinpheno order).
## ============================================================================

## ---- 1. load Thanos --------------------------------------------------------
## Source-mode loader by default (Thanos is not an installed package here):
## T2_THANOS names the loader file, default ../Thanos/thanos.R. An installed
## `thanos` package is the fallback. Either must be new enough to have
## thanosServer(base_mask = ), which the Filter tab depends on.
T2_THANOS_PATH = Sys.getenv("T2_THANOS", file.path("..", "Thanos", "thanos.R"))
HAVE_THANOS = FALSE
T2_THANOS_NOTE = ""
local({
    ok = FALSE
    if (file.exists(T2_THANOS_PATH)) {
        ok = tryCatch({ source(T2_THANOS_PATH, local = globalenv()); TRUE },
                      error = function(e) {
                          T2_THANOS_NOTE <<- paste("Thanos failed to load:", conditionMessage(e))
                          FALSE
                      })
    } else if (requireNamespace("thanos", quietly = TRUE)) {
        ok = tryCatch({ library(thanos); TRUE }, error = function(e) FALSE)
    } else {
        T2_THANOS_NOTE <<- paste0("Thanos not found (looked for ", T2_THANOS_PATH,
                                  " and an installed 'thanos' package).")
    }
    if (ok && !("base_mask" %in% names(formals(get("thanosServer", envir = globalenv()))))) {
        T2_THANOS_NOTE <<- "The Thanos version found is too old (needs thanosServer(base_mask = ), >= 0.3.0)."
        ok = FALSE
    }
    HAVE_THANOS <<- ok
})
if (!HAVE_THANOS) message("T2: Filter tab disabled. ", T2_THANOS_NOTE)

## module id for a dataset's Thanos instance (one instance per dataset, because
## a Thanos instance is bound to one backend for life)
t2_thanos_id = function(dataset) paste0("th_", gsub("[^A-Za-z0-9]", "_", dataset))

## ---- 2. the backend --------------------------------------------------------
## Probe columns kept per backend before the oldest are dropped. Thanos keeps
## its own copy of every column that is currently selected, so eviction here
## never affects a live filter panel -- it only means a re-fetch later.
T2_BACKEND_MAX_COLS = 300

## backend_t2(bundle) -> the four functions of the Thanos backend contract
##   $get_columns()  $n_rows()  $get_column(name)  $get_column_info(name)
## plus T2's own extras:
##   $samples                      sample id per row
##   $prefetch(cols)               fetch several probes in ONE query
##   $base_mask(cohort, nonormal, noheme)
##                                 logical per row: the Select tab's pre-filters
backend_t2 = function(bundle) {
    dbfile = bundle$path
    roles  = bundle$roles

    ## typed: clinical + virtual columns exactly as gitr() hands them to the
    ## plotter (no probes, no filters). One query; every clinical column the
    ## Filter tab asks for is served from here.
    typed = gitr(character(0), dbfile = dbfile, roles = roles)
    samples = as.character(typed$sample)
    n = length(samples)

    ## raw: clinpheno with the virtual columns but BEFORE gitr's factor
    ## conversion, for the pre-filter predicate (gitr applies its filters at
    ## that same point -- re-levelling the sample-type column turns unlisted
    ## values into NA, which would hide them from "Exclude Non-tumor").
    raw = local({
        con_be = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile,
                                    flags = RSQLite::SQLITE_RO)
        on.exit(DBI::dbDisconnect(con_be), add = TRUE)
        clin = as.data.frame(DBI::dbReadTable(con_be, 'clinpheno', check.names = FALSE),
                             check.names = FALSE)
        t2_add_virtual_cols(clin, roles)
    })
    raw = raw[match(samples, as.character(raw$sample)), , drop = FALSE]

    clin_cols = setdiff(colnames(typed), 'sample')
    columns = unique(c(clin_cols, bundle$mygenes))
    columns = columns[!is.na(columns) & nzchar(columns) & columns != 'sample']

    ## name -> list(col = <vector in row order>, info = <Thanos column info>)
    store = new.env(parent = emptyenv())
    fetched = character(0)   # probe columns in fetch order, for eviction

    ## coerce + describe one column through Thanos' own in-memory backend, so
    ## type handling (factor -> character, integer -> double, ...) and the
    ## statistics behind the widgets are Thanos' and cannot drift from it
    put = function(v, x) {
        if (length(x) != n) x = rep(NA_character_, n)
        df = data.frame(x, stringsAsFactors = FALSE, check.names = FALSE)
        names(df) = v
        be = backend_memory(df)
        if (!(v %in% be$get_columns())) {          # unsupported type: all NA
            df[[v]] = rep(NA_character_, n)
            be = backend_memory(df)
        }
        store[[v]] = list(col = be$get_column(v), info = be$get_column_info(v))
    }

    fetch = function(vs) {
        vs = unique(vs[vs %in% columns])
        vs = vs[!vapply(vs, exists, NA, envir = store, inherits = FALSE)]
        if (length(vs) == 0) return(invisible())
        clin = intersect(vs, clin_cols)
        for (v in clin) put(v, typed[[v]])
        probes = setdiff(vs, clin)
        if (length(probes) == 0) return(invisible())
        ## a failed query must not take the session down: the column shows up
        ## as all-NA instead (and is not cached, so a later attempt retries)
        d = tryCatch(gitr(probes, dbfile = dbfile, roles = roles),
                     error = function(e) {
                         warning("backend_t2: fetching ", paste(probes, collapse = ", "),
                                 " failed: ", conditionMessage(e), call. = FALSE)
                         NULL
                     })
        if (is.null(d)) return(invisible())
        idx = match(samples, as.character(d$sample))
        for (p in probes) {
            put(p, if (p %in% colnames(d)) d[[p]][idx] else rep(NA_character_, n))
        }
        fetched <<- c(fetched, probes)
        if (length(fetched) > T2_BACKEND_MAX_COLS) {
            drop = head(fetched, length(fetched) - T2_BACKEND_MAX_COLS)
            rm(list = intersect(drop, ls(store)), envir = store)
            fetched <<- setdiff(fetched, drop)
        }
        invisible()
    }

    entry = function(v) {
        fetch(v)
        e = store[[v]]
        if (is.null(e)) {      # unknown name or failed fetch: an all-NA column
            x = rep(NA_character_, n)
            e = list(col = x,
                     info = list(name = v, is_numeric = FALSE, n_na = n,
                                 levels = character(0)))
        }
        e
    }

    list(
        get_columns     = function() columns,
        n_rows          = function() n,
        get_column      = function(name) entry(name)$col,
        get_column_info = function(name) entry(name)$info,
        samples         = samples,
        prefetch        = fetch,
        base_mask       = function(cohort = 'all', nonormal = FALSE, noheme = FALSE) {
            t2_sample_keep(raw, roles, cohort = cohort, nonormal = nonormal,
                           noheme = noheme)
        }
    )
}

## One-line description of the active Thanos filters, for the plot summary:
## `filters` is th$filters() (column -> c(lo, hi) or a set of values),
## `backend` supplies each column's levels so "everything ticked" is skipped.
t2_describe_filters = function(filters, backend) {
    num = function(x) format(signif(x, 4), trim = TRUE)
    out = character(0)
    for (v in names(filters)) {
        val = filters[[v]]
        if (is.null(val)) next
        if (is.numeric(val)) {
            if (!any(is.finite(val))) next
            out = c(out, if (!is.finite(val[1])) sprintf("%s <= %s", v, num(val[2]))
                         else if (!is.finite(val[2])) sprintf("%s >= %s", v, num(val[1]))
                         else sprintf("%s in [%s, %s]", v, num(val[1]), num(val[2])))
        } else {
            levs = backend$get_column_info(v)$levels
            if (!is.null(levs) && setequal(val, levs)) next
            shown = if (length(val) > 6) c(head(val, 6), sprintf("... (%d values)", length(val)))
                    else val
            out = c(out, sprintf("%s: %s", v,
                                 if (length(val)) paste(shown, collapse = ", ") else "(none selected)"))
        }
    }
    out
}
