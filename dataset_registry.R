## dataset_registry.R
## ============================================================================
## Multi-dataset support for T2.
##
## DESIGN (see MULTIDATASET.md): each dataset is a SEPARATE SQLite file with the
## SAME schema shape (samples / probes / types / tcgai / tcgacati / tested /
## clinpheno / cohorts / datatypes + the tcgas/tcgacats/tcga/tcgacat views).
## The dataset boundary is a PHYSICAL partition, not a row-level `project`
## column — because the datasets are not numerically comparable, their clinical
## tables have different column sets, and the existing fact table is 577M rows
## (a column-migration would be a multi-hour, high-risk rewrite for a
## cross-dataset JOIN capability that is semantically meaningless here).
##
## A dataset is SELF-DESCRIBING: each non-canonical db carries a small
## `dataset_meta(key,value)` table that names which clinical column plays the
## role of cohort / subtype / sample-type, plus sensible default selections.
## The canonical TCGA db predates this convention, so its role map is supplied
## as a hard-coded fallback below.
## ============================================================================

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

## Directory holding additional dataset files (one <name>.db per dataset).
DATASETS_DIR <- "datasets"

## ---------------------------------------------------------------------------
## Canonical TCGA role map (the original hard-coded behaviour of gitr/lib/app).
## ---------------------------------------------------------------------------
.TCGA_ROLES <- list(
  cohort_col        = "tumtype",
  subtype_col       = "Subtype_Selected",
  sampletype_col    = "sample_type",
  normal_label      = "Solid Tissue Normal",
  heme_values       = c("LAML", "THYM", "DLBC"),
  sampletype_levels = c("Primary Tumor", "Recurrent Tumor", "Metastatic",
                        "Additional - New Primary", "Additional Metastatic",
                        "Primary Blood Derived Cancer - Peripheral Blood",
                        "Solid Tissue Normal")
)
.TCGA_DEFAULTS <- list(
  x = "cohort", y = "CD8A", color = "sample_type", size = "",
  condition = "StromalScore.estimate"
)
.TCGA_TITLE <- "T2: TCGA 2018 Pan-Cancer Database"
.TCGA_LABEL <- "TCGA Pan-Cancer 2018"   # short label used in plot captions

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

## clinpheno column names for a db (used for generic role introspection).
.clin_cols <- function(path) {
  con <- tryCatch(.ds_ro(path), error = function(e) NULL)
  if (is.null(con)) return(character(0))
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tryCatch(DBI::dbListFields(con, "clinpheno"), error = function(e) character(0))
}

## comma-separated meta value -> character vector (empty string -> character(0))
.split_meta <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) return(character(0))
  trimws(strsplit(s, ",", fixed = TRUE)[[1]])
}

## ---------------------------------------------------------------------------
## Build a role map for a dataset, in priority order:
##   1. canonical TCGA fallback (name == "TCGA")
##   2. self-describing dataset_meta table
##   3. generic introspection of clinpheno column names
## ---------------------------------------------------------------------------
.resolve_roles <- function(name, path) {
  if (identical(name, "TCGA")) {
    return(list(roles = .TCGA_ROLES, defaults = .TCGA_DEFAULTS,
                title = .TCGA_TITLE, label = .TCGA_LABEL))
  }

  meta <- .read_dataset_meta(path)
  if (!is.null(meta)) {
    roles <- list(
      cohort_col        = meta$cohort_col     %||% NA_character_,
      subtype_col       = meta$subtype_col    %||% NA_character_,
      sampletype_col    = (meta$sampletype_col %||% "") ,
      normal_label      = (meta$normal_label   %||% "") ,
      heme_values       = .split_meta(meta$heme_values),
      sampletype_levels = .split_meta(meta$sampletype_levels)
    )
    ## normalise empty strings to NA for the role columns
    if (!nzchar(roles$sampletype_col %||% "")) roles$sampletype_col <- NA_character_
    if (!nzchar(roles$normal_label   %||% "")) roles$normal_label   <- NA_character_
    if (length(roles$sampletype_levels) == 0)  roles$sampletype_levels <- NULL
    defaults <- list(
      x         = meta$default_x         %||% "cohort",
      y         = meta$default_y         %||% "",
      color     = meta$default_color     %||% "",
      size      = meta$default_size      %||% "",
      condition = meta$default_condition %||% ""
    )
    title <- meta$title %||% name
    label <- meta$label %||% title
    return(list(roles = roles, defaults = defaults, title = title, label = label))
  }

  ## generic introspection fallback
  cc <- .clin_cols(path)
  pick <- function(cands) { hit <- cands[cands %in% cc]; if (length(hit)) hit[1] else NA_character_ }
  roles <- list(
    cohort_col        = pick(c("tumtype", "cohort", "group", "dataset")),
    subtype_col       = pick(c("Subtype_Selected", "subtype")),
    sampletype_col    = pick(c("sample_type", "sampletype")),
    normal_label      = NA_character_,
    heme_values       = character(0),
    sampletype_levels = NULL
  )
  defaults <- list(x = "cohort", y = "", color = "", size = "", condition = "")
  list(roles = roles, defaults = defaults, title = name, label = name)
}

## ---------------------------------------------------------------------------
## Public API
## ---------------------------------------------------------------------------

## Discover available datasets. Returns a named list keyed by dataset name;
## each element is list(name, path). TCGA (root tcga.db) is always first.
discover_datasets <- function() {
  out <- list()
  if (file.exists("tcga.db")) out[["TCGA"]] <- list(name = "TCGA", path = "tcga.db")
  if (dir.exists(DATASETS_DIR)) {
    dbs <- list.files(DATASETS_DIR, pattern = "\\.db$", full.names = TRUE)
    for (p in sort(dbs)) {
      nm <- sub("\\.db$", "", basename(p))
      if (identical(nm, "TCGA")) next   # never shadow the canonical entry
      out[[nm]] <- list(name = nm, path = p)
    }
  }
  out
}

## Names of available datasets (for the UI dropdown).
list_datasets <- function() names(discover_datasets())

## The default dataset name (TCGA if present, else the first discovered).
default_dataset <- function() {
  d <- list_datasets()
  if ("TCGA" %in% d) "TCGA" else if (length(d)) d[1] else stop("No datasets found")
}

## Full descriptor for one dataset: name, path, roles, defaults, title.
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
