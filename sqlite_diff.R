## sqlite_diff.R
## ============================================================================
## Thorough structural + data diff of two SQLite databases -> a markdown report.
##
##   Rscript sqlite_diff.R <old.db> <new.db> [report.md]
##   DIFF_FULL_ROWS=5000000 Rscript sqlite_diff.R a.db b.db   # exact-diff cutoff
##
## What it compares:
##   * OBJECTS  — tables / views / indexes present in each, and DDL changes.
##   * COLUMNS  — for common tables: added / removed / retyped columns.
##   * DATA     — per common table:
##       - row counts (A vs B, delta)
##       - a per-column FINGERPRINT (count, distinct, min, max, and sum for
##         numeric cols) computed in ONE scan each — order-independent, so it
##         works on huge fact tables (tcgai/tcgacati) without sorting.
##       - if a `type` column exists, per-`type` row counts (handy for T2).
##       - for tables under DIFF_FULL_ROWS (default 2,000,000): an EXACT
##         row-level set diff (rows only in A / only in B) + example rows.
##
## Read-only: opens a :memory: db and ATTACHes both files; only SELECTs run.
## ============================================================================

suppressMessages({ library(DBI); library(RSQLite) })

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  cat("usage: Rscript sqlite_diff.R <old.db> <new.db> [report.md]\n"); quit(status = 2)
}
DBA <- args[1]; DBB <- args[2]
OUT <- if (length(args) >= 3) args[3] else "sqlite_diff_report.md"
FULL_ROWS <- suppressWarnings(as.numeric(Sys.getenv("DIFF_FULL_ROWS", "2000000")))
if (is.na(FULL_ROWS)) FULL_ROWS <- 2000000
stopifnot(file.exists(DBA), file.exists(DBB))

con <- dbConnect(SQLite(), ":memory:")
dbExecute(con, "PRAGMA busy_timeout=60000")
dbExecute(con, "ATTACH DATABASE ? AS a", params = list(normalizePath(DBA)))
dbExecute(con, "ATTACH DATABASE ? AS b", params = list(normalizePath(DBB)))
Q  <- function(sql) dbGetQuery(con, sql)
Q1 <- function(sql) { r <- tryCatch(Q(sql), error = function(e) NULL)
                      if (is.null(r) || !nrow(r)) NA else r[1, 1] }
qi <- function(x) sprintf("`%s`", gsub("`", "``", x))          # quote identifier
plural <- function(ty) if (ty == "index") "indexes" else paste0(ty, "s")

## ---- objects in each db ----------------------------------------------------
objs <- function(sch)
  Q(sprintf("SELECT type, name, COALESCE(sql,'') sql FROM %s.sqlite_master
             WHERE type IN ('table','view','index') AND name NOT LIKE 'sqlite_%%'
             ORDER BY type, name", sch))
oa <- objs("a"); ob <- objs("b")
byt <- function(o, ty) o[o$type == ty, , drop = FALSE]

## column info for one table in one schema
cols_of <- function(sch, tbl)
  Q(sprintf("SELECT name, type FROM pragma_table_info('%s','%s')",
            gsub("'", "''", tbl), sch))

## normalise DDL for comparison (collapse whitespace)
norm <- function(s) gsub("\\s+", " ", trimws(s))

## ---- data fingerprint: one aggregate row per table (one scan) --------------
fingerprint <- function(sch, tbl, ct) {
  parts <- "COUNT(*) AS `__rows`"
  for (i in seq_len(nrow(ct))) {
    nm <- ct$name[i]; ty <- tolower(ct$type[i]); c <- qi(nm)
    parts <- c(parts,
      sprintf("COUNT(%s) AS %s", c, qi(paste0(nm, "|n"))),
      sprintf("COUNT(DISTINCT %s) AS %s", c, qi(paste0(nm, "|nd"))),
      sprintf("MIN(%s) AS %s", c, qi(paste0(nm, "|min"))),
      sprintf("MAX(%s) AS %s", c, qi(paste0(nm, "|max"))))
    if (grepl("int|real|floa|doub|num|dec", ty))
      parts <- c(parts, sprintf("TOTAL(%s) AS %s", c, qi(paste0(nm, "|sum"))))
  }
  Q(sprintf("SELECT %s FROM %s.%s", paste(parts, collapse = ", "), sch, qi(tbl)))
}

## compare two 1-row fingerprints; sums use a relative tolerance (float sums are
## order-sensitive), everything else exact.
fp_diffs <- function(fa, fb) {
  fields <- union(names(fa), names(fb)); out <- character(0)
  for (f in fields) {
    va <- if (f %in% names(fa)) fa[[1, f]] else NA
    vb <- if (f %in% names(fb)) fb[[1, f]] else NA
    same <- local({
      if (is.na(va) && is.na(vb)) return(TRUE)
      if (is.na(va) || is.na(vb)) return(FALSE)
      if (grepl("\\|sum$", f) && is.numeric(va) && is.numeric(vb))
        return(abs(va - vb) <= 1e-9 * max(1, abs(va), abs(vb)))
      identical(as.character(va), as.character(vb))
    })
    if (!same) out <- c(out, sprintf("%s: %s -> %s", f,
                                      format(va, scientific = FALSE),
                                      format(vb, scientific = FALSE)))
  }
  out
}

## ---- report buffer ---------------------------------------------------------
R <- character(0); add <- function(...) R <<- c(R, paste0(...))
fsz <- function(p) {
  b <- file.info(p)$size
  if (b > 1e9) return(sprintf("%.2f GB", b/1e9))
  if (b > 1e6) return(sprintf("%.1f MB", b/1e6))
  sprintf("%d B", b)
}

add("# SQLite diff report")
add("")
add("| | database | size | modified |")
add("|--|--|--|--|")
add(sprintf("| **A (old)** | `%s` | %s | %s |", DBA, fsz(DBA), format(file.info(DBA)$mtime, "%Y-%m-%d %H:%M")))
add(sprintf("| **B (new)** | `%s` | %s | %s |", DBB, fsz(DBB), format(file.info(DBB)$mtime, "%Y-%m-%d %H:%M")))
add(sprintf("| generated | %s | full-diff cutoff | %s rows |", format(Sys.time(), "%Y-%m-%d %H:%M"), format(FULL_ROWS, big.mark = ",", scientific = FALSE)))
add("")

## ---- object-level summary --------------------------------------------------
schema_changed <- FALSE
add("## Objects")
add("")
add("| kind | in A | in B | common | only in A | only in B | DDL changed |")
add("|--|--:|--:|--:|--:|--:|--:|")
obj_detail <- list()
for (ty in c("table", "view", "index")) {
  na <- byt(oa, ty)$name; nb <- byt(ob, ty)$name
  onlyA <- setdiff(na, nb); onlyB <- setdiff(nb, na); common <- intersect(na, nb)
  ddlch <- character(0)
  for (nm in common) {
    sa <- norm(oa$sql[oa$type == ty & oa$name == nm]); sb <- norm(ob$sql[ob$type == ty & ob$name == nm])
    if (!identical(sa, sb)) ddlch <- c(ddlch, nm)
  }
  if (length(onlyA) || length(onlyB) || length(ddlch)) schema_changed <- TRUE
  add(sprintf("| %s | %d | %d | %d | %d | %d | %d |", ty, length(na), length(nb),
              length(common), length(onlyA), length(onlyB), length(ddlch)))
  obj_detail[[ty]] <- list(onlyA = onlyA, onlyB = onlyB, ddlch = ddlch,
                           sa = oa, sb = ob, common = common)
}
add("")

## ---- schema detail ---------------------------------------------------------
add("## Schema changes")
add("")
any_schema <- FALSE
for (ty in c("table", "view", "index")) {
  d <- obj_detail[[ty]]
  if (length(d$onlyA)) { any_schema <- TRUE
    add(sprintf("**%s only in A (dropped):** %s", plural(ty), paste0("`", d$onlyA, "`", collapse = ", "))); add("") }
  if (length(d$onlyB)) { any_schema <- TRUE
    add(sprintf("**%s only in B (added):** %s", plural(ty), paste0("`", d$onlyB, "`", collapse = ", "))); add("") }
  if (length(d$ddlch)) { any_schema <- TRUE
    add(sprintf("**%s with changed DDL:** %s", plural(ty), paste0("`", d$ddlch, "`", collapse = ", "))); add("")
    for (nm in d$ddlch) {
      add("<details><summary>", ty, " `", nm, "` DDL</summary>"); add("")
      add("```sql"); add("-- A:"); add(norm(oa$sql[oa$type == ty & oa$name == nm]))
      add("-- B:"); add(norm(ob$sql[ob$type == ty & ob$name == nm])); add("```")
      add("</details>"); add("")
    }
  }
}
## column changes on common tables
common_tables <- obj_detail[["table"]]$common
col_change_lines <- character(0)
for (t in common_tables) {
  ca <- cols_of("a", t); cb <- cols_of("b", t)
  addc <- setdiff(cb$name, ca$name); rmc <- setdiff(ca$name, cb$name)
  retyped <- character(0)
  for (nm in intersect(ca$name, cb$name)) {
    ta <- ca$type[ca$name == nm][1]; tb <- cb$type[cb$name == nm][1]
    if (!identical(tolower(ta), tolower(tb))) retyped <- c(retyped, sprintf("%s (%s->%s)", nm, ta, tb))
  }
  if (length(addc) || length(rmc) || length(retyped)) {
    any_schema <- TRUE; schema_changed <- TRUE
    col_change_lines <- c(col_change_lines, sprintf("- `%s`: %s%s%s", t,
      if (length(addc)) paste0("added {", paste(addc, collapse = ", "), "} ") else "",
      if (length(rmc)) paste0("removed {", paste(rmc, collapse = ", "), "} ") else "",
      if (length(retyped)) paste0("retyped {", paste(retyped, collapse = ", "), "}") else ""))
  }
}
if (length(col_change_lines)) { add("**Column changes (common tables):**"); add(""); add(col_change_lines); add("") }
if (!any_schema) { add("_No schema differences — same tables, views, indexes, columns, and DDL._"); add("") }

## ---- data diff -------------------------------------------------------------
add("## Data changes (common tables)")
add("")
add("| table | rows A | rows B | Δ | verdict | method |")
add("|--|--:|--:|--:|--|--|")
data_changed <- FALSE
details <- character(0)
for (t in common_tables) {
  ca <- cols_of("a", t); cb <- cols_of("b", t)
  same_cols <- setequal(ca$name, cb$name)
  fa <- tryCatch(fingerprint("a", t, ca), error = function(e) NULL)
  fb <- tryCatch(fingerprint("b", t, cb), error = function(e) NULL)
  ra <- if (!is.null(fa)) fa[["__rows"]] else NA
  rb <- if (!is.null(fb)) fb[["__rows"]] else NA
  small <- same_cols && !is.na(ra) && !is.na(rb) && max(ra, rb) <= FULL_ROWS
  verdict <- "identical"; method <- "fingerprint"; note <- ""

  if (small) {
    method <- "row-exact"
    onlyA <- Q1(sprintf("SELECT COUNT(*) FROM (SELECT * FROM a.%s EXCEPT SELECT * FROM b.%s)", qi(t), qi(t)))
    onlyB <- Q1(sprintf("SELECT COUNT(*) FROM (SELECT * FROM b.%s EXCEPT SELECT * FROM a.%s)", qi(t), qi(t)))
    if (isTRUE(onlyA == 0) && isTRUE(onlyB == 0)) verdict <- "identical"
    else { verdict <- "**changed**"; data_changed <- TRUE
           note <- sprintf("%s rows only in A, %s only in B", onlyA, onlyB) }
  } else {
    fields <- if (!same_cols) "columns differ" else if (is.null(fa) || is.null(fb)) fp_diffs(fa, fb) else fp_diffs(fa, fb)
    if (!same_cols) { verdict <- "**changed**"; data_changed <- TRUE; note <- "column set differs" }
    else if (length(fields)) { verdict <- "**changed**"; data_changed <- TRUE
                               note <- sprintf("%d fingerprint fields differ", length(fields)) }
  }
  delta <- if (!is.na(ra) && !is.na(rb)) rb - ra else NA
  add(sprintf("| %s | %s | %s | %s | %s | %s |", t,
              format(ra, big.mark = ",", scientific = FALSE),
              format(rb, big.mark = ",", scientific = FALSE),
              if (is.na(delta)) "?" else sprintf("%+d", as.integer(delta)),
              verdict, method))

  ## per-table detail when changed
  if (grepl("changed", verdict)) {
    details <- c(details, sprintf("### `%s`", t), "")
    if (nzchar(note)) details <- c(details, paste0("- ", note), "")
    ## per-type breakdown if a `type` column exists
    if ("type" %in% ca$name && "type" %in% cb$name) {
      ta <- Q(sprintf("SELECT type, COUNT(*) n FROM a.%s GROUP BY type", qi(t)))
      tb <- Q(sprintf("SELECT type, COUNT(*) n FROM b.%s GROUP BY type", qi(t)))
      m <- merge(ta, tb, by = "type", all = TRUE, suffixes = c("_A", "_B"))
      m[is.na(m)] <- 0
      m <- m[m$n_A != m$n_B, , drop = FALSE]
      if (nrow(m)) {
        details <- c(details, "per-`type` row counts that differ:", "",
                     "| type | A | B | Δ |", "|--|--:|--:|--:|")
        for (i in seq_len(nrow(m)))
          details <- c(details, sprintf("| %s | %s | %s | %+d |", m$type[i],
                       format(m$n_A[i], big.mark = ","), format(m$n_B[i], big.mark = ","),
                       as.integer(m$n_B[i] - m$n_A[i])))
        details <- c(details, "")
      }
    }
    ## fingerprint field diffs (large tables)
    if (!small && same_cols && !is.null(fa) && !is.null(fb)) {
      fd <- fp_diffs(fa, fb)
      if (length(fd)) details <- c(details, "changed aggregates (col|stat): A -> B", "",
                                   paste0("- `", fd, "`"), "")
    }
    ## example differing rows (small tables)
    if (small && same_cols) {
      ex <- tryCatch(Q(sprintf("SELECT * FROM a.%s EXCEPT SELECT * FROM b.%s LIMIT 4", qi(t), qi(t))),
                     error = function(e) NULL)
      if (!is.null(ex) && nrow(ex)) {
        details <- c(details, "example rows only in A:", "", "```",
                     capture.output(print(ex, row.names = FALSE)), "```", "")
      }
    }
  }
}
add("")
if (length(details)) { add("### Changed-table details"); add(""); add(details) }

## ---- verdict ---------------------------------------------------------------
verdict <- if (!schema_changed && !data_changed) {
  "**IDENTICAL** — no schema or data differences detected."
} else {
  paste0("**DIFFERENT** — ",
         if (schema_changed) "schema changes" else "",
         if (schema_changed && data_changed) " and " else "",
         if (data_changed) "data changes" else "", " detected.")
}
R <- append(R, c("", verdict), after = 1)   # verdict right under the title

writeLines(R, OUT)
cat(sprintf("\n%s\nreport -> %s (%d lines)\n", sub("\\*\\*", "", gsub("\\*\\*", "", verdict)), OUT, length(R)))
dbDisconnect(con)
