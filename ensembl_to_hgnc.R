## ensembl_to_hgnc.R
## ============================================================================
## REUSABLE Ensembl -> HGNC gene-symbol harmonization + collapse.
##
## Why this exists: some expression matrices are keyed by Ensembl gene IDs
## (ENSG...), but the T2 schema and app are gene-SYMBOL centric (CD8A, TP53,
## ...). To integrate such a matrix we must translate Ensembl -> HGNC and
## COLLAPSE the several Ensembl genes that share one HGNC symbol into a single
## row.
##
## Two correctness rules baked in here:
##   1. Aggregation of LOGGED values is done in LINEAR space: un-log -> sum ->
##      re-log. Summing log values directly would be multiplying expression,
##      which is wrong. (unlog -> add -> relog).
##   2. An Ensembl ID that maps to MORE THAN ONE distinct HGNC symbol is
##      DROPPED entirely (ambiguous; not worth accommodating). An Ensembl ID
##      with NO symbol is KEPT as-is under its Ensembl ID.
##
## Harmonization source: a probemap table with (id, gene) columns, e.g. UCSC
## Xena's gencode.v23.annotation.gene.probemap. biomaRt / ensembldb could
## supply the same id->symbol mapping if a probemap is unavailable; this code
## only needs a two-column id/gene lookup.
## ============================================================================

library(data.table)

## probemap (data.frame/data.table whose first two columns are id, gene) ->
## named character vector  id -> HGNC symbol.
##   * empty/NA symbols dropped (those ids fall through to "kept as Ensembl")
##   * ids mapping to >1 distinct symbol dropped entirely (ambiguous)
load_ensembl_hgnc_map <- function(probemap, verbose = TRUE) {
  pm <- as.data.table(probemap)
  setnames(pm, names(pm)[1:2], c("id", "gene"))
  pm <- pm[!is.na(id) & nzchar(id)]
  pm[, gene := trimws(gene)]
  pm <- pm[!is.na(gene) & nzchar(gene)]
  pm <- unique(pm[, .(id, gene)])

  ## drop ids that resolve to more than one distinct symbol
  amb <- pm[, .N, by = id][N > 1L, id]
  if (length(amb)) {
    if (verbose) cat(sprintf("load_ensembl_hgnc_map: dropping %d ambiguous Ensembl ids (>1 HGNC symbol)\n",
                             length(amb)))
    pm <- pm[!id %in% amb]
  }
  if (verbose) cat(sprintf("load_ensembl_hgnc_map: %d Ensembl->HGNC entries\n", nrow(pm)))
  setNames(pm$gene, pm$id)
}

## Collapse an Ensembl-gene expression matrix to HGNC symbols.
##   expr : data.table/data.frame, first column = Ensembl id, remaining columns
##          = one numeric column per sample.
##   map  : named character vector id -> HGNC symbol (load_ensembl_hgnc_map()).
##   from_log/log_base/log_offset : how the INPUT values are logged. The UCSC
##          Toil TPM matrix is log2(tpm + 0.001) -> base 2, offset 0.001.
##   relog_offset : offset for the OUTPUT re-log. Default 1 yields log2(tpm+1),
##          which maps unexpressed genes (tpm 0) to exactly 0 so they collapse
##          into the T2 sparse-zero model.
##   zero_floor : linear values below this are snapped to 0 to kill the float
##          dust left by un-logging the 0.001 offset (so true zeros stay zero).
## Returns a data.table: column `probe` (HGNC symbol or kept Ensembl id) + one
## numeric column per sample, re-logged.
collapse_ensembl_to_hgnc <- function(expr, map,
                                     from_log = TRUE, log_base = 2,
                                     log_offset = 0.001, relog_offset = 1,
                                     zero_floor = 1e-6, verbose = TRUE) {
  dt <- as.data.table(expr)
  idcol   <- names(dt)[1]
  samples <- setdiff(names(dt), idcol)
  ids     <- as.character(dt[[idcol]])

  ## resolve label: HGNC symbol if mapped, else keep the Ensembl id. Try a
  ## version-stripped fallback for ids absent from the (versioned) map.
  lab  <- unname(map[ids])
  miss <- is.na(lab)
  if (any(miss)) {
    map_nov <- map
    names(map_nov) <- sub("\\.[0-9]+$", "", names(map))
    map_nov <- map_nov[!duplicated(names(map_nov))]
    lab[miss] <- unname(map_nov[sub("\\.[0-9]+$", "", ids[miss])])
  }
  keep_ens <- is.na(lab) | !nzchar(lab)
  lab[keep_ens] <- ids[keep_ens]
  if (verbose)
    cat(sprintf("collapse_ensembl_to_hgnc: %d rows -> HGNC: %d, kept Ensembl: %d, distinct labels: %d\n",
                length(ids), sum(!keep_ens), sum(keep_ens), length(unique(lab))))

  ## values -> numeric matrix (drop the id column)
  M <- as.matrix(dt[, ..samples])
  rm(dt); gc(FALSE)

  ## un-log to linear space (recovers the original tpm), snap float dust to 0
  if (from_log) {
    M <- log_base^M - log_offset
    M[!is.finite(M) | M < zero_floor] <- 0
  }

  ## sum rows that share a label, in linear space. rowsum() is a C-level
  ## group-wise ROW sum: for a WIDE matrix (here ~19k sample columns) it is
  ## dramatically faster than per-column data.table/GForce aggregation, which
  ## pays grouping overhead once per column.
  M <- rowsum(M, group = lab, reorder = FALSE)

  ## re-log (default relog_offset = 1 -> log2(tpm+1), so tpm 0 -> exactly 0)
  if (from_log) M <- log(M + relog_offset, base = log_base)

  out <- as.data.table(M, keep.rownames = "probe")
  rm(M); gc(FALSE)
  out[]
}
