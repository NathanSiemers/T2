## test_survival_facet.R — a faceted survival panel must be identical to
## selecting that cohort directly: the median-z signature AND the group cut-points
## are computed WITHIN each facet group, not against the whole pull. Guards a
## fixed bug where pan-cancer tertiles were applied to each per-tumor panel.
suppressMessages({ source("database_connection_shiny.R"); source("lib.R") })
DB <- "tcga.db"; RO <- gitr_default_roles
ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")

sig <- c("CXCR1", "CXCR2", "CSF3R", "PROK2", "IL1B", "IL1A")   # compound signature
gf <- suppressWarnings(survival_km(sig, "OS", cohort = "all", facet = "tumtype", dbfile = DB, roles = RO))
gc <- suppressWarnings(survival_km(sig, "OS", cohort = "HNSC", dbfile = DB, roles = RO))

fd <- attr(gf, "km_data"); cd <- attr(gc, "km_data")
fh <- setNames(as.character(fd$grp[fd$tumtype == "HNSC"]), fd$sample[fd$tumtype == "HNSC"])
ch <- setNames(as.character(cd$grp), cd$sample)
common <- intersect(names(fh), names(ch)); common <- common[!is.na(fh[common]) & !is.na(ch[common])]
agree <- if (length(common)) mean(fh[common] == ch[common]) else 0
cat(sprintf("  HNSC: facet-panel=%d  cohort=%d  common=%d  group-agreement=%.1f%%\n",
            length(fh), length(ch), length(common), 100 * agree))
ok(length(common) > 100 && agree > 0.99, "faceted HNSC panel grouping == cohort=HNSC grouping")

## also verify the compound signature was used (median-z of >1 probe)
ok(length(attr(gc, "stats")$markers) == length(sig), "compound signature carried through")
cat("== survival facet test done ==\n")
