## dataset_registry.R
## ============================================================================
## The datasets as FILES: discovery, and their roles read VERBATIM from each
## file's dataset_meta table. This is the builders' library and the
## equivalence ORACLE of the tests (gitr() over a file, test_equivalence.R,
## test_gitr_api.R); the Shiny app never uses it: the app is an api client
## (t2_api_client.R) and reads everything from the service
## (DATASET-CONTRACT.md, decision 2026-10-19).
##
## DESIGN (see MULTIDATASET.md): each dataset is a SEPARATE SQLite file with the
## SAME schema shape. Its name is its file name: datasets/<name>.db (TCGA.db,
## cptac.db, ...); the legacy top-level tcga.db is also "TCGA". A dataset is
## SELF-DESCRIBING: dataset_meta(key, value) names the clinical column of each
## role (cohort / subtype / sample type) and the default picks. Nothing here
## derives or guesses: a file without dataset_meta is an error, not a fallback.
## ============================================================================

if (!exists("t2_cache")) source("t2_util.R")

## Directory holding additional dataset files (one <name>.db per dataset).
## T2_DATASETS_DIR points a test or a trial at other copies of the files.
DATASETS_DIR <- Sys.getenv("T2_DATASETS_DIR", "datasets")

## ---------------------------------------------------------------------------
## Low-level helpers
## ---------------------------------------------------------------------------

## Open a short-lived read-only connection to a dataset db.
.ds_ro <- function(path) {
  RSQLite::dbConnect(RSQLite::SQLite(), dbname = path,
                     flags = RSQLite::SQLITE_RO)
}

## Read the dataset_meta key/value table from a db, or NULL if absent.
.read_dataset_meta <- function(path) {
  con <- tryCatch(.ds_ro(path), error = function(e) NULL)
  if (is.null(con)) return(NULL)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  has_meta <- tryCatch("dataset_meta" %in% DBI::dbListTables(con),
                       error = function(e) FALSE)
  if (!has_meta) return(NULL)
  m <- tryCatch(DBI::dbGetQuery(con, "SELECT key, value FROM dataset_meta"),
                error = function(e) NULL)
  if (is.null(m) || nrow(m) == 0) return(NULL)
  setNames(as.list(m$value), m$key)
}

## comma-separated meta value -> character vector (empty string -> character(0))
## A list stored in dataset_meta. Values can contain commas ("Acute Myeloid
## Leukemia, Induction Failure Subproject"), so builders separate with "|"; a
## string without "|" is split on "," (databases built before October 2026).
## The t2api service applies the same rule (splitMeta in dataset.go).
.split_meta <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) return(character(0))
  x <- trimws(strsplit(s, if (grepl("|", s, fixed = TRUE)) "|" else ",", fixed = TRUE)[[1]])
  x[nzchar(x)]
}

## ---------------------------------------------------------------------------
## The role map of a dataset FILE: dataset_meta, verbatim (contract s.1).
## ---------------------------------------------------------------------------
.resolve_roles <- function(name, path) {
  meta <- .read_dataset_meta(path)
  if (is.null(meta))
    stop("dataset '", name, "' (", path, ") has no dataset_meta table: build it with the builder of its dataset ",
         "(DATASET-CONTRACT.md) or `Rscript dataset_meta.R set ", path, " cohort_col=...`")
  roles <- list(
    cohort_col        = meta$cohort_col     %||% NA_character_,
    subtype_col       = meta$subtype_col    %||% NA_character_,
    sampletype_col    = (meta$sampletype_col %||% ""),
    ## normal_label may be a LIST of non-tumor sample types
    normal_label      = .split_meta(meta$normal_label),
    heme_values       = .split_meta(meta$heme_values),
    sampletype_levels = .split_meta(meta$sampletype_levels)
  )
  ## an unset role is NA (a dataset without a subtype stores subtype_col = "")
  for (k in c("cohort_col", "subtype_col", "sampletype_col"))
    if (!nzchar(roles[[k]] %||% "")) roles[[k]] <- NA_character_
  if (length(roles$normal_label) == 0)       roles$normal_label   <- NA_character_
  if (length(roles$sampletype_levels) == 0)  roles$sampletype_levels <- NULL
  roles$source_col          <- meta$source_col %||% NA_character_
  roles$sources             <- .split_meta(meta$sources)
  roles$source_labels       <- .split_meta(meta$source_labels)
  roles$source_descriptions <- .split_meta(meta$source_descriptions)
  defaults <- list(
    x         = meta$default_x         %||% "cohort",
    y         = meta$default_y         %||% "",
    color     = meta$default_color     %||% "",
    size      = meta$default_size      %||% "",
    condition = meta$default_condition %||% "",
    cohorts   = .split_meta(meta$default_cohorts)
  )
  title <- meta$title %||% name
  label <- meta$label %||% title
  list(roles = roles, defaults = defaults, title = title, label = label, order = suppressWarnings(as.numeric(meta$order %||% NA)))
}

## ---------------------------------------------------------------------------
## Public API (files)
## ---------------------------------------------------------------------------

## The dataset name of a file: its base name; tcga.db / TCGA.db (any case) is "TCGA".
.dataset_name_of <- function(path) {
  nm <- sub("\\.db$", "", basename(path))
  if (identical(tolower(nm), "tcga")) "TCGA" else nm
}

## Discover available datasets. Returns a named list keyed by dataset name;
## each element is list(name, path), in the order of the dataset_meta key
## `order` (missing = after the ordered ones), then alphabetically. Every *.db
## of DATASETS_DIR is a dataset; the legacy top-level tcga.db is TCGA when
## the directory holds no TCGA.db.
discover_datasets <- function() {
  paths <- if (dir.exists(DATASETS_DIR)) sort(list.files(DATASETS_DIR, pattern = "\\.db$", full.names = TRUE)) else character(0)
  out <- list()
  for (p in paths) { nm <- .dataset_name_of(p); out[[nm]] <- list(name = nm, path = p) }
  if (is.null(out[["TCGA"]]) && file.exists("tcga.db")) out[["TCGA"]] <- list(name = "TCGA", path = "tcga.db")
  ord <- vapply(out, function(d) {
    m <- .read_dataset_meta(d$path); o <- suppressWarnings(as.numeric(m$order %||% NA)); if (is.na(o)) Inf else o
  }, 0)
  out[order(ord, names(out))]
}

## Names of available datasets.
list_datasets <- function() names(discover_datasets())

## The default dataset name (TCGA if present, else the first discovered).
default_dataset <- function() {
  d <- list_datasets()
  if ("TCGA" %in% d) "TCGA" else if (length(d)) d[1] else stop("No datasets found")
}

## Full descriptor for one dataset file: name, path, roles, defaults, title.
dataset_info <- function(name) {
  d <- discover_datasets()
  if (!name %in% names(d)) stop("Unknown dataset: ", name)
  path <- d[[name]]$path
  r <- .resolve_roles(name, path)
  list(name = name, path = path, roles = r$roles,
       defaults = r$defaults, title = r$title, label = r$label)
}

## Convenience: db path for a dataset name.
dataset_db_path <- function(name) dataset_info(name)$path

## The roles of a database FILE (what gitr(roles = NULL) uses): dataset_meta, verbatim.
dataset_roles <- function(path) .resolve_roles(.dataset_name_of(path), path)$roles
