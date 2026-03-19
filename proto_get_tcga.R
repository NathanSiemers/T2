library(sqldf)
library(data.table)
library(ggplot2)

db = '../tcga.db'



# Build a dense-matrix fetch query against tcga.db.
#
# types  : character vector of type names (e.g. c('sig','hrd')).
#           Controls which samples are included via the tested table.
# probes : optional character vector of probe names (e.g. c('BCAT2.sig')).
#           When supplied, added as an AND filter on pt so only those
#           probes appear in the result.
# db     : path to the SQLite database.  Required only when probes is
#           supplied without types (used to auto-derive types).
#
# Behaviour:
#   types only        -> same query as original; probes unrestricted
#   types + probes    -> types control tested samples; probes added to pt
#   probes only       -> types are derived from tcgai for those probes,
#                        then query is built as types+probes above
make_query <- function(types = NULL, probes = NULL, db = NULL) {
  if (is.null(types) && is.null(probes))
    stop("At least one of 'types' or 'probes' must be provided.")

  if (is.null(types)) {
    if (is.null(db))
      stop("'db' is required when deriving types from probe names.")
    probe_sql <- paste(sprintf("'%s'", probes), collapse = ", ")
    types <- sqldf(sprintf(
      "SELECT DISTINCT ti.type FROM tcgai ti
       JOIN probes pr ON pr.key = ti.probekey
       WHERE pr.probe IN (%s)", probe_sql), db = db)$type
    if (length(types) == 0)
      stop("None of the supplied probe names were found in tcgai.")
  }

  types_in     <- paste(sprintf("'%s'", types),  collapse = ", ")
  probe_clause <- if (!is.null(probes)) {
    probe_sql <- paste(sprintf("'%s'", probes), collapse = ", ")
    sprintf("\n  AND pr.probe IN (%s)", probe_sql)
  } else ""

  sprintf("SELECT tk.sample, pt.probe, COALESCE(ti.value, 0) AS value, tk.type
FROM (
  SELECT DISTINCT samp.key AS samplekey, samp.sample, t.type
  FROM tested t
  JOIN samples samp ON samp.sample = t.sample
  WHERE t.type IN (%s)
) tk
JOIN (
  SELECT DISTINCT ti2.probekey, pr.probe, ti2.type
  FROM tcgai ti2
  JOIN probes pr ON pr.key = ti2.probekey
  WHERE ti2.type IN (%s)%s
) pt ON pt.type = tk.type
LEFT JOIN tcgai ti
ON ti.probekey   = pt.probekey
AND ti.samplekey = tk.samplekey
AND ti.type      = pt.type", types_in, types_in, probe_clause)
}

## ---- 1. Fetch the pre-computed signature-level data (as before) ----
types <- c('viral', 'pc_gene_program', 'hrd', 'immune_score', 'immune_subtype', 'molec_subtype', 'sig')
query  <- make_query(types)

sqldf(paste( "explain query plan", query ), db = db)

out = sqldf( query, db = db); dim(out)
table(out$type)

out_na = out[is.na(out$value), ] ; head(out_na)

sigs <- as.data.frame(dcast(as.data.table(out), probe ~ paste0(sample), value.var = "value", fill = NA))
rownames(sigs) = sigs$probe; sigs$probe = NULL
sigs = as.matrix(sigs)
sigs[1:5,1:5]
dim(sigs)
length(which(is.na(sigs)))

head(sigs["ai1.hrd", 1:10])

## ---- 2. Extract individual probes from signatures.R ----
## Source the signature definitions to get the decon_genelist
source("signatures.R")

## All unique gene names that appear in any signature definition
all_probe_genes <- unique(decon_genelist)
message("Individual probes from signatures.R: ", length(all_probe_genes))

## Check which of these genes actually exist as type 'rna' in the database
probe_sql <- paste(sprintf("'%s'", all_probe_genes), collapse = ", ")
found <- sqldf(sprintf(
  "SELECT DISTINCT pr.probe FROM probes pr
   JOIN tcgai ti ON ti.probekey = pr.key
   WHERE ti.type = 'rna' AND pr.probe IN (%s)", probe_sql), db = db)$probe
missing <- setdiff(all_probe_genes, found)
if (length(missing) > 0)
  message("Probes not found as 'rna' in tcga.db (skipped): ",
          paste(missing, collapse = ", "))
message("Probes found in db: ", length(found))

## Query individual probe RNA data — use type 'rna' with a probe name filter
rna_query <- make_query(types = "rna", probes = found)
out_rna   <- sqldf(rna_query, db = db); dim(out_rna)

## Pivot to matrix with .rna suffix so these are distinguishable from signatures
out_rna$probe <- paste0(out_rna$probe, ".rna")
rna_mat <- as.data.frame(dcast(as.data.table(out_rna),
                                probe ~ paste0(sample),
                                value.var = "value", fill = NA))
rownames(rna_mat) <- rna_mat$probe; rna_mat$probe <- NULL
rna_mat <- as.matrix(rna_mat)
message("RNA probe matrix: ", nrow(rna_mat), " probes x ", ncol(rna_mat), " samples")

## ---- 3. Merge signature matrix and individual-probe matrix ----
## Align to common samples (signatures may cover different sample sets than rna)
common_samples <- intersect(colnames(sigs), colnames(rna_mat))
message("Common samples between sigs and rna probes: ", length(common_samples))
sigs    <- sigs[, common_samples, drop = FALSE]
rna_mat <- rna_mat[, common_samples, drop = FALSE]

## Stack: signatures on top, individual probes below
sigs <- rbind(sigs, rna_mat)
message("Final merged matrix: ", nrow(sigs), " rows x ", ncol(sigs), " samples")

saveRDS(sigs, file = 'Results/signature_matrix_samples_in_columns.rds')

c = sqldf('select * from clinpheno', db = db)
c$subtype = gsub('.*\\.', '', c$Subtype_Selected)
c$subtype[c$subtype == '-'] = "NA"
c$subtype = gsub(":", "_", c$subtype, fixed = TRUE)
c$subtype = gsub(" ", "", c$subtype, fixed = TRUE)
c$subtype = gsub("-", "", c$subtype, fixed = TRUE)
unique(c$subtype)
c$subtype = paste0(c$tumtype, '_', c$subtype)
sort(unique(c$subtype))
c$Subtype_Selected = c$subtype


dim(c)
saveRDS(c, file = 'Results/clin.rds')

