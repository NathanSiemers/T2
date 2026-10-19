## CPTAC/01-profile.R
## ============================================================================
## Profile the raw CPTAC Pan-Cancer files downloaded by 00-download.R and write
## Data/profile.md. Read-only on the sources; re-runnable.
## Run (container, repo root): Rscript CPTAC/01-profile.R
## ============================================================================
suppressMessages({library(data.table); library(readxl)})
setDTthreads(2)
here <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) NA)
if (is.na(here)) {
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  here <- if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else "CPTAC"
}
D <- file.path(here, "Data")
OUT <- file.path(D, "profile.md")
COH <- c("BRCA","CCRCC","COAD","GBM","HNSCC","LSCC","LUAD","OV","PDAC","UCEC")

## ---- markdown helpers ------------------------------------------------------
buf <- character()
w  <- function(...) buf <<- c(buf, paste0(...))
h  <- function(n, s) w("\n", strrep("#", n), " ", s, "\n")
cb <- function(x) { w("```"); w(x); w("```") }
tbl <- function(df) {
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  if (!nrow(df)) { w("(none)"); return(invisible()) }
  df[] <- lapply(df, function(x) gsub("|", "\\|", as.character(x), fixed = TRUE))
  w("| ", paste(names(df), collapse = " | "), " |")
  w("|", paste(rep("---", ncol(df)), collapse = "|"), "|")
  for (i in seq_len(nrow(df))) w("| ", paste(df[i, ], collapse = " | "), " |")
  w("")
}
fm <- function(x, d = 4) ifelse(is.na(x), "NA", format(signif(x, d), trim = TRUE, scientific = FALSE))
cpr <- function(x, n = 3) paste(head(x, n), collapse = ", ")

## ---- file paths --------------------------------------------------------------
PD <- function(zip) { b <- file.path(D, zip, zip); b }
DIR <- list(prot = PD("Proteome_BCM_GENCODE_v34_harmonized_v1"),
            phos = PD("Phosphoproteome_BCM_GENCODE_v34_harmonized_v1"),
            rna  = PD("RNA_BCM_v1"), cnv = PD("CNV_BCM_v1"),
            mut  = PD("Mutation_BCM_v1"), clin = PD("Clinical_meta_data_v1"))
## RNA, CNV, mutation and clinical zips use ccRCC and HGSC where the others use CCRCC and OV
alt <- function(C) c(CCRCC = "ccRCC", OV = "HGSC")[C] |> (\(x) ifelse(is.na(x), C, x))()
FILES <- function(C) {
  a <- unname(alt(C)); M <- file.path(D, "mirror", C)
  c(prot_T = file.path(DIR$prot, paste0(C, "_proteomics_gene_abundance_log2_reference_intensity_normalized_Tumor.txt")),
    prot_N = file.path(DIR$prot, paste0(C, "_proteomics_gene_abundance_log2_reference_intensity_normalized_Normal.txt")),
    phos_T = file.path(DIR$phos, paste0(C, "_phospho_site_abundance_log2_reference_intensity_normalized_Tumor.txt")),
    phos_N = file.path(DIR$phos, paste0(C, "_phospho_site_abundance_log2_reference_intensity_normalized_Normal.txt")),
    rna_T  = file.path(DIR$rna, paste0(a, "_RNAseq_gene_RSEM_coding_UQ_1500_log2_Tumor.txt")),
    rna_N  = file.path(DIR$rna, paste0(a, "_RNAseq_gene_RSEM_coding_UQ_1500_log2_Normal.txt")),
    tpm    = Sys.glob(file.path(M, paste0(C, "-gene_TPM*")))[1],
    cnv_ratio  = file.path(DIR$cnv, paste0(a, "_WES_CNV_gene_ratio_log2.txt")),
    cnv_gistic = file.path(DIR$cnv, paste0(a, "_WES_CNV_gene_gistic_level.txt")),
    mut_bin = file.path(DIR$mut, paste0(a, "_somatic_mutation_gene_level_binary.txt")),
    maf     = file.path(DIR$mut, paste0(a, "_somatic_mutation.maf")),
    meta    = file.path(DIR$clin, paste0(a, "_meta.txt")),
    meta_mirror = file.path(M, paste0(C, "_meta.txt")),
    survival = file.path(M, paste0(C, "_survival.txt")),
    phenotype = file.path(M, paste0(C, "_phenotype.txt")))
}
LAB <- c(prot_T="Proteome Tumor", prot_N="Proteome Normal", phos_T="Phospho Tumor", phos_N="Phospho Normal",
         rna_T="RNA UQ Tumor", rna_N="RNA UQ Normal", tpm="RNA TPM (mirror)", cnv_ratio="CNV ratio log2",
         cnv_gistic="CNV gistic", mut_bin="Mutation binary", maf="MAF", meta="Meta (PDC clinical)",
         meta_mirror="Meta (mirror)", survival="Survival (mirror)", phenotype="Phenotype (mirror)")
MATTYPES <- c("prot_T","prot_N","phos_T","phos_N","rna_T","rna_N","tpm","cnv_ratio","cnv_gistic","mut_bin")

## ---- readers -----------------------------------------------------------------
nf <- function(l) length(strsplit(l, "\t", fixed = TRUE)[[1]]) + (substring(l, nchar(l)) == "\t")
head_ids <- function(f) {                       # column ids from the header line
  ls <- readLines(f, n = 2, warn = FALSE); ls <- sub("\r$", "", ls)
  hd <- strsplit(ls[1], "\t", fixed = TRUE)[[1]]
  list(ids = if (nf(ls[2]) == length(hd) + 1) hd else hd[-1], short_header = nf(ls[2]) == length(hd) + 1,
       first = hd[1])
}
rdm <- function(f) {                            # matrix file -> list(rows, ids, M)
  hi <- head_ids(f)
  dt <- if (hi$short_header) fread(f, header = FALSE, skip = 1, sep = "\t", quote = "")
        else fread(f, header = TRUE, sep = "\t", quote = "")
  rows <- dt[[1]]; dt[, (1) := NULL]
  M <- as.matrix(dt); rm(dt)
  colnames(M) <- hi$ids
  list(rows = as.character(rows), ids = hi$ids, M = M, short_header = hi$short_header, first = hi$first)
}
idclass <- function(x) gsub("[0-9]", "9", gsub("[A-Za-z]", "A", x))
topcls <- function(x, n = 4) { t <- sort(table(idclass(x)), decreasing = TRUE); paste(sprintf("%s (%d)", names(t), t)[seq_len(min(n, length(t)))], collapse = "; ") }

## ---- 0. text hygiene scan ------------------------------------------------------
scan_file <- function(f) {
  con <- file(f, "rb"); on.exit(close(con))
  bad <- 0L; cr <- 0; crlf_total <- 0; q <- 0; nl <- 0; bom <- FALSE; first <- TRUE; nonascii <- 0
  rest <- raw(0)
  repeat {
    r <- readBin(con, "raw", 32e6); if (!length(r)) break
    if (first) { bom <- length(r) >= 3 && all(r[1:3] == as.raw(c(0xef,0xbb,0xbf))); first <- FALSE }
    cr <- cr + sum(r == as.raw(13)); nl <- nl + sum(r == as.raw(10)); q <- q + sum(r == as.raw(34))
    nonascii <- nonascii + sum(r >= as.raw(128))
  }
  ## UTF-8 validity: only if any non-ASCII byte exists, validate the whole file
  utf8_ok <- if (nonascii == 0) TRUE else {
    ln <- readLines(f, warn = FALSE, encoding = "bytes"); all(validUTF8(ln)) }
  c(bytes = file.size(f), lines = nl, CR = cr, dq = q, nonascii = nonascii, bom = bom, utf8 = utf8_ok)
}

## ---- collect file list --------------------------------------------------------
ALLF <- lapply(COH, FILES); names(ALLF) <- COH
w("# CPTAC Pan-Cancer data freeze: profile of the raw files\n")
w("Generated by `CPTAC/01-profile.R` on ", format(Sys.time(), "%Y-%m-%d %H:%M"), ". Sources: PDC pan-cancer zips (BCM harmonized, GENCODE v34) and the LinkedOmicsKB mirror (S3). Everything below is measured from the files in `CPTAC/Data/`.\n")
h(2, "0. Files, naming and text hygiene")
w("Cohort naming differs by zip: proteome and phospho use `CCRCC` and `OV`; the RNA, CNV, Mutation and Clinical zips use `ccRCC` and `HGSC` for the same two cohorts. The mirror uses `CCRCC` and `OV`.\n")
miss <- unlist(lapply(COH, function(C) { f <- ALLF[[C]]; names(f)[is.na(f) | !file.exists(f)] |> (\(x) if (length(x)) paste(C, x) else NULL)() }))
w("Files expected but missing: ", if (length(miss)) paste(miss, collapse = "; ") else "none", "\n")
w("Cohort x type availability (1 = file present):\n")
av <- t(sapply(COH, function(C) as.integer(!is.na(ALLF[[C]]) & file.exists(ALLF[[C]]))))
colnames(av) <- names(ALLF[[1]]); tbl(cbind(cohort = COH, av))

cat("hygiene scan...\n")
hy <- do.call(rbind, lapply(COH, function(C) do.call(rbind, lapply(names(ALLF[[C]]), function(k) {
  f <- ALLF[[C]][k]; if (is.na(f) || !file.exists(f)) return(NULL)
  s <- scan_file(f); data.frame(cohort = C, type = k, bytes = s["bytes"], lines = s["lines"], CR_bytes = s["CR"],
    dquote_chars = s["dq"], nonASCII_bytes = s["nonascii"], BOM = as.logical(s["bom"]), valid_UTF8 = as.logical(s["utf8"]))
}))))
w("Per file: size, line count, number of CR bytes (CR_bytes = lines means Windows line endings), double-quote characters, non-ASCII bytes, UTF-8 BOM, UTF-8 validity.\n")
tbl(hy)
w("Summary: files with CRLF endings: ", paste(sort(unique(paste(hy$type[hy$CR_bytes > 0]))), collapse = ", "),
  "; files with double quotes: ", paste(unique(hy$type[hy$dquote_chars > 0]), collapse = ", "),
  "; files with non-ASCII bytes: ", paste(unique(hy$type[hy$nonASCII_bytes > 0]), collapse = ", "),
  "; invalid UTF-8: ", sum(!hy$valid_UTF8), " file(s); BOM: ", sum(hy$BOM), " file(s).\n")
rm(hy)

## ---- gene annotation ------------------------------------------------------------
GA <- fread(file.path(DIR$prot, "README", "Gene_annotation_and_representable_isoform_mapping_table.txt"),
            sep = "\t", quote = "", na.strings = NULL, colClasses = "character")
GA2 <- fread(file.path(DIR$phos, "README", "Gene_annotation_and_representable_isoform_mapping_table.txt"),
             sep = "\t", quote = "", na.strings = NULL, colClasses = "character")
empty <- function(x) is.na(x) | x %in% c("", "NA", ".", "-")

## ---- 1. read every matrix, keep summaries and id sets ---------------------------
SUM <- list(); IDS <- list(); ROWS <- list(); PH <- list()
for (C in COH) {
  IDS[[C]] <- list(); ROWS[[C]] <- list()
  for (k in MATTYPES) {
    f <- ALLF[[C]][k]; if (is.na(f) || !file.exists(f)) next
    cat(C, k, "\n"); r <- rdm(f); M <- r$M
    v <- as.vector(M)
    nn <- !is.na(v)
    isint <- all(v[nn] == round(v[nn]))
    SUM[[length(SUM) + 1]] <- data.frame(cohort = C, type = k, file = basename(f), rows = nrow(M), cols = ncol(M),
      first3_cols = cpr(r$ids), first3_rows = cpr(r$rows), min = fm(min(v[is.finite(v)])), median = fm(median(v, na.rm = TRUE)),
      max = fm(max(v, na.rm = TRUE)), frac_NA = fm(mean(is.na(v)), 3), frac_0 = fm(mean(v == 0, na.rm = TRUE), 3), n_neg_inf = sum(v == -Inf, na.rm = TRUE), n_pos_inf = sum(v == Inf, na.rm = TRUE), n_par_y_rows = sum(grepl("_PAR_Y$", r$rows)),
      value_type = if (isint) "integer-valued" else "real", header_has_no_corner_cell = r$short_header,
      corner = r$first, dup_col_ids = anyDuplicated(r$ids) > 0, dup_row_ids = anyDuplicated(r$rows) > 0,
      stringsAsFactors = FALSE)
    IDS[[C]][[k]] <- r$ids; ROWS[[C]][[k]] <- r$rows
    if (k %in% c("mut_bin", "cnv_gistic")) SUM[[length(SUM)]]$distinct_values <- paste(sort(unique(v[nn]))[1:min(10, length(unique(v[nn])))], collapse = " ")
    rm(M, v, nn, r); gc(verbose = FALSE)
  }
}
SUMd <- rbindlist(SUM, fill = TRUE)

h(2, "1. Matrix files (proteome, phospho, RNA, CNV, mutation binary)")
w("Each table is read with `data.table::fread` (tab separated, no quote handling). 'First 3 row ids' are the values of column 1. Median/min/max are over all non-NA finite cells (infinite values are counted separately in n_neg_inf / n_pos_inf); n_par_y_rows = row ids ending in `_PAR_Y`. `header_has_no_corner_cell` = the header line has one field fewer than the data lines (the corner cell is missing).\n")
for (k in MATTYPES) {
  h(3, LAB[k]); s <- SUMd[type == k]
  tbl(s[, .(cohort, file = sub("(.{60}).*", "\\1...", file), rows, cols, first3_cols, first3_rows, min_finite = min, median, max, frac_NA, frac_0, n_neg_inf, n_pos_inf, n_par_y_rows, value_type)])
  w("Header corner cell(s): ", paste(unique(s$corner), collapse = " | "), "; header without corner cell in: ",
    paste(s$cohort[s$header_has_no_corner_cell], collapse = ", ") |> (\(x) if (x == "") "none" else x)(),
    "; duplicated column ids in: ", paste(s$cohort[s$dup_col_ids], collapse = ", ") |> (\(x) if (x == "") "none" else x)(),
    "; duplicated row ids in: ", paste(s$cohort[s$dup_row_ids], collapse = ", ") |> (\(x) if (x == "") "none" else x)(), ".\n")
  if ("distinct_values" %in% names(s) && any(!is.na(s$distinct_values)))
    w("Distinct values: ", paste(unique(na.omit(s$distinct_values)), collapse = " | "), "\n")
}

## ---- 2. Sample ids --------------------------------------------------------------
h(2, "2. Sample ids")
w("Column headers are the sample ids. Id patterns below replace letters by A and digits by 9.\n")
rows <- list()
for (C in COH) {
  I <- IDS[[C]]; for (k in names(I)) rows[[length(rows) + 1]] <- data.frame(cohort = C, type = k, n = length(I[[k]]),
    examples = cpr(I[[k]]), id_patterns = topcls(I[[k]]))
}
tbl(rbindlist(rows))

h(3, "Tumor vs Normal id reuse")
w("For each cohort: the number of tumor ids, normal ids and the intersection of the two (same string in both files), per data type. Intersection > 0 with equal strings means the same id marks a case's tumor and its NAT.\n")
tn <- list()
for (C in COH) for (p in c("prot","phos","rna")) {
  t <- IDS[[C]][[paste0(p, "_T")]]; n <- IDS[[C]][[paste0(p, "_N")]]
  if (is.null(t) && is.null(n)) next
  tn[[length(tn) + 1]] <- data.frame(cohort = C, type = p, tumor_ids = length(t), normal_ids = length(n),
    intersection = length(intersect(t, n)), tumor_examples = cpr(t, 2), normal_examples = cpr(n, 2),
    normal_suffix_or_prefix = if (length(n)) topcls(n, 2) else "")
}
tbl(rbindlist(tn))
w("Strings seen in a Normal file that also occur verbatim in the same cohort's Tumor file, examples (first cohort with an overlap): ")
ex <- NULL; for (C in COH) { o <- intersect(IDS[[C]]$prot_T, IDS[[C]]$prot_N); if (length(o)) { ex <- paste0(C, ": ", cpr(o, 5)); break } }
w(ex %||% "none", "\n")

h(3, "Shared ids across data types within a cohort")
w("Pairwise intersection sizes of column ids (diagonal = number of ids).\n")
for (C in COH) {
  I <- IDS[[C]]
  mt <- tryCatch({ m <- fread(ALLF[[C]]["meta"], sep = "\t", quote = "", select = 1, header = TRUE)[[1]]; as.character(m[-1]) }, error = function(e) character())
  I$meta <- mt
  nm <- names(I); m <- outer(nm, nm, Vectorize(function(a, b) length(intersect(I[[a]], I[[b]]))))
  dimnames(m) <- list(nm, nm); w("**", C, "**"); cb(capture.output(print(m)))
  IDS[[C]]$meta <- mt
}
h(3, "Sample ids shared between cohorts")
allid <- rbindlist(lapply(COH, function(C) data.table(cohort = C, id = unique(unlist(IDS[[C]])))))
dd <- allid[, .(n = uniqueN(cohort), cohorts = paste(unique(cohort), collapse = ",")), by = id][n > 1]
w("Ids (any data type) that occur in more than one cohort: ", nrow(dd), "\n")
if (nrow(dd)) tbl(head(dd[order(-n)], 30))
w("Distinct ids overall: ", uniqueN(allid$id), "; sum of per-cohort distinct ids: ", nrow(allid), "\n")

## ---- 3. gene ids ------------------------------------------------------------------
h(2, "3. Gene ids and the gene annotation table")
w("`README/Gene_annotation_and_representable_isoform_mapping_table.txt` (proteome zip): ", nrow(GA), " rows x ", ncol(GA), " columns; identical file in the phospho zip: ", identical(GA, GA2), ".\n")
w("Columns: ", paste(names(GA), collapse = ", "), "\n")
w("Distinct `gene` ids: ", uniqueN(GA$gene), "; versioned (end in .N): ", mean(grepl("\\.[0-9]+$", GA$gene)), ".\n")
w("Type table:"); cb(capture.output(print(sort(table(GA$Type), decreasing = TRUE))))
gm <- GA[, .(gene_name = {x <- unique(gene_name[!empty(gene_name)]); if (length(x)) paste(x, collapse = ";") else ""},
             gene_name_BCM_refined = {x <- unique(gene_name_BCM_refined[!empty(gene_name_BCM_refined)]); if (length(x)) paste(x, collapse = ";") else ""},
             n_name = uniqueN(gene_name[!empty(gene_name)]), n_ref = uniqueN(gene_name_BCM_refined[!empty(gene_name_BCM_refined)])), by = gene]
w("Genes with a non-empty gene_name: ", sum(gm$gene_name != ""), "; non-empty gene_name_BCM_refined: ", sum(gm$gene_name_BCM_refined != ""),
  "; genes with >1 distinct gene_name: ", sum(gm$n_name > 1), "; >1 gene_name_BCM_refined: ", sum(gm$n_ref > 1),
  "; genes whose gene_name differs from gene_name_BCM_refined: ", sum(gm$gene_name != gm$gene_name_BCM_refined & gm$gene_name != "" & gm$gene_name_BCM_refined != ""), "\n")
dif <- gm[gene_name != gene_name_BCM_refined & gene_name != "" & gene_name_BCM_refined != ""]
if (nrow(dif)) { w("Examples where the two symbol columns differ:\n"); tbl(head(dif[, .(gene, gene_name, gene_name_BCM_refined)], 10)) }
w("Mapping-table gene ids with no symbol at all (both columns empty): ", sum(gm$gene_name == "" & gm$gene_name_BCM_refined == ""), "\n")
w("The `MANE`/`Primary_select` columns: ", paste(names(sort(table(GA$Primary_select), decreasing = TRUE)), collapse = "/"), "\n")

genecheck <- function(ids, label) {
  ids <- unique(ids); ver <- grepl("\\.[0-9]+$", ids); base <- sub("\\.[0-9]+$", "", ids)
  gb <- sub("\\.[0-9]+$", "", gm$gene)
  data.frame(set = label, ids = length(ids), versioned = sum(ver), exact_in_table = sum(ids %in% gm$gene),
    in_table_ignoring_version = sum(base %in% gb), version_mismatch = sum(!ids %in% gm$gene & base %in% gb),
    not_in_table = sum(!base %in% gb), with_gene_name = sum(ids %in% gm$gene[gm$gene_name != ""]),
    with_refined_name = sum(ids %in% gm$gene[gm$gene_name_BCM_refined != ""]))
}
gr <- list()
for (k in c("prot_T","prot_N","rna_T","rna_N","tpm","cnv_ratio","cnv_gistic","mut_bin")) {
  u <- unique(unlist(lapply(COH, function(C) ROWS[[C]][[k]]))); if (length(u)) gr[[k]] <- genecheck(u, paste0(LAB[k], " (union of cohorts)"))
}
phg <- NULL
h(3, "Gene id sets against the mapping table (union over cohorts per data type)")
tbl(rbindlist(gr))

h(3, "Proteome gene ids per cohort")
pr <- rbindlist(lapply(COH, function(C) { r <- unique(c(ROWS[[C]]$prot_T, ROWS[[C]]$prot_N)); x <- genecheck(r, C)
  x$set <- C; x$tumor_rows <- length(ROWS[[C]]$prot_T); x$normal_rows <- length(ROWS[[C]]$prot_N); x }))
tbl(pr)
sets <- lapply(COH, function(C) sort(unique(c(ROWS[[C]]$prot_T, ROWS[[C]]$prot_N)))); names(sets) <- COH
w("Proteome row sets identical across all 10 cohorts: ", length(unique(lapply(sets, digest <- function(x) paste(length(x), x[1], x[length(x)], sum(nchar(x)))))) == 1 && all(sapply(sets, identical, sets[[1]])), "\n")
w("Union of proteome ids: ", length(unique(unlist(sets))), "; intersection over cohorts: ", length(Reduce(intersect, sets)), "\n")
w("Tumor and Normal proteome files of one cohort have identical row ids: ",
  paste(COH[sapply(COH, function(C) !is.null(ROWS[[C]]$prot_N) && identical(ROWS[[C]]$prot_T, ROWS[[C]]$prot_N))], collapse = ", "), "\n")
w("RNA UQ row sets identical across cohorts: ", { rs <- lapply(COH, function(C) sort(ROWS[[C]]$rna_T)); all(sapply(rs, identical, rs[[1]])) },
  "; CNV ratio row sets identical across cohorts: ", { rs <- lapply(COH, function(C) sort(ROWS[[C]]$cnv_ratio)); all(sapply(rs, identical, rs[[1]])) },
  "; mutation binary: ", { rs <- lapply(COH, function(C) sort(ROWS[[C]]$mut_bin)); all(sapply(rs, identical, rs[[1]])) },
  "; TPM mirror: ", { rs <- lapply(COH, function(C) sort(ROWS[[C]]$tpm)); all(sapply(rs, identical, rs[[1]])) }, "\n")
rows_n <- rbindlist(lapply(COH, function(C) data.table(cohort = C, prot = length(ROWS[[C]]$prot_T), rna = length(ROWS[[C]]$rna_T),
  tpm = length(ROWS[[C]]$tpm), cnv_ratio = length(ROWS[[C]]$cnv_ratio), cnv_gistic = length(ROWS[[C]]$cnv_gistic), mut_bin = length(ROWS[[C]]$mut_bin))))
w("Row counts per cohort and data type:\n"); tbl(rows_n)

h(3, "Symbol collisions (proteome ids)")
pu <- unique(unlist(sets))
pm <- gm[match(pu, gene)]
for (col in c("gene_name", "gene_name_BCM_refined")) {
  s <- pm[[col]]; s <- s[!is.na(s) & s != ""]
  t <- sort(table(s), decreasing = TRUE); col_n <- t[t > 1]
  w("**", col, "**: ", length(pu), " proteome Ensembl ids, ", sum(!is.na(pm[[col]]) & pm[[col]] != ""), " with a symbol, ", sum(is.na(pm[[col]]) | pm[[col]] == ""),
    " without; distinct symbols: ", length(t), "; symbols carried by >1 Ensembl id: ", length(col_n), " (affecting ", sum(col_n), " ids).\n")
  if (length(col_n)) { tt <- head(col_n, 20); tbl(data.frame(symbol = names(tt), n_ensembl = as.integer(tt),
        ensembl_ids = sapply(names(tt), function(s0) paste(pu[!is.na(pm[[col]]) & pm[[col]] == s0], collapse = ", ")))) }
}
w("Collisions per cohort (gene_name_BCM_refined): ")
w(paste(sapply(COH, function(C) { g <- gm$gene_name_BCM_refined[match(sets[[C]], gm$gene)]; g <- g[!is.na(g) & g != ""]; sprintf("%s=%d", C, sum(table(g) > 1)) }), collapse = ", "), "\n")
nosym <- pu[is.na(pm$gene_name_BCM_refined) | pm$gene_name_BCM_refined == ""]
w("Proteome ids with no refined symbol, examples: ", cpr(nosym, 8), "\n")
for (k in c("rna_T", "tpm", "cnv_ratio", "mut_bin")) {
  u <- unique(unlist(lapply(COH, function(C) ROWS[[C]][[k]]))); b <- gm$gene_name_BCM_refined[match(u, gm$gene)]
  s <- b[!is.na(b) & b != ""]; w(LAB[k], ": ", length(u), " ids, ", length(s), " with refined symbol, ", sum(is.na(b) | b == ""), " without (incl. not in table: ", sum(is.na(match(u, gm$gene))),
    "), symbols carried by >1 id: ", sum(table(s) > 1), "\n")
}
rm(sets)

## ---- 4. phospho ----------------------------------------------------------------------
h(2, "4. Phosphoproteome row ids")
ex <- ROWS$BRCA$phos_T[1:3]
w("Example row ids: `", paste(ex, collapse = "`, `"), "`. Delimiter: `|`.\n")
phs <- list(); allrows <- list()
for (C in COH) for (k in c("phos_T","phos_N")) {
  r <- ROWS[[C]][[k]]; if (is.null(r)) next
  sp <- tstrsplit(r, "|", fixed = TRUE, fill = NA)
  nfld <- lengths(strsplit(r, "|", fixed = TRUE))
  d <- data.table(row = r, gene = sp[[1]], enp = sp[[2]], site = sp[[3]], pep = if (length(sp) >= 4) sp[[4]] else NA, last = if (length(sp) >= 5) sp[[5]] else NA)
  d[, multi := grepl("^([STYsty][0-9]+){2,}$", site) | grepl("[;,&_-]", site)]
  d[, bad := grepl("[^A-Za-z0-9]", site)]
  d[, single := grepl("^[STYsty][0-9]+$", site)]
  pair <- d[, .(nenp = uniqueN(enp)), by = .(gene, site)]
  trip <- d[, .(np = uniqueN(pep)), by = .(gene, enp, site)]
  phs[[length(phs) + 1]] <- data.frame(cohort = C, type = k, sites = nrow(d), fields_per_id = paste(names(table(nfld)), table(nfld), sep = ":", collapse = " "),
    distinct_genes = uniqueN(d$gene), distinct_ENSP = uniqueN(d$enp), gene_site_pairs = nrow(pair), pairs_with_gt1_ENSP = sum(pair$nenp > 1),
    triples_with_gt1_peptide = sum(trip$np > 1), site_tokens_nonalnum = sum(d$bad), multi_site_tokens = sum(d$multi),
    plain_single_site = sum(d$single), versioned_gene = mean(grepl("\\.[0-9]+$", d$gene)), versioned_ENSP = mean(grepl("\\.[0-9]+$", d$enp)),
    dup_rowids = anyDuplicated(r) > 0)
  allrows[[paste(C, k)]] <- d[, .(gene, enp, site, multi, bad, last)]
}
tbl(rbindlist(phs))
ad <- unique(rbindlist(allrows))
w("Site-token shapes (all cohorts, distinct rows): single `[STY]digits`: ", sum(grepl("^[STY][0-9]+$", ad$site)), "; other: ", sum(!grepl("^[STY][0-9]+$", ad$site)), "\n")
oth <- ad[!grepl("^[STY][0-9]+$", site)]
w("Examples of non single-site tokens: ", cpr(unique(oth$site), 15), "\n")
w("Tokens containing a non-alphanumeric character: ", sum(ad$bad), " rows; examples: ", cpr(unique(ad$site[ad$bad]), 10), "\n")
w("Distinct values of the 5th field: ", paste(head(names(sort(table(ad$last), decreasing = TRUE)), 10), collapse = ", "), "\n")
w("Distinct phospho genes across cohorts: ", uniqueN(ad$gene), "; of them in the mapping table: ", sum(unique(ad$gene) %in% gm$gene), "; with refined symbol: ",
  sum(unique(ad$gene) %in% gm$gene[gm$gene_name_BCM_refined != ""]), "\n")
w("Phospho ENSP ids in mapping table `protein` column: ", mean(unique(ad$enp) %in% GA$protein), "\n")
gp <- ad[, .(nenp = uniqueN(enp)), by = .(gene, site)]
w("Across all cohorts, (gene, site) pairs with >1 ENSP: ", sum(gp$nenp > 1), " of ", nrow(gp), "\n")
if (any(gp$nenp > 1)) { tt <- head(gp[nenp > 1][order(-nenp)], 5); tbl(tt) }
mm <- ad[multi == TRUE | bad == TRUE]
if (nrow(mm)) { w("Examples of multi-site / odd rows (gene|ENSP|site):\n"); cb(paste(head(mm$gene, 8), head(mm$enp, 8), head(mm$site, 8), sep = "|")) }
## Phospho ENSG vs proteome ENSG
w("Phospho genes present in the proteome row set: ", mean(unique(ad$gene) %in% unique(unlist(lapply(COH, function(C) ROWS[[C]]$prot_T)))), " (fraction)\n")
rm(allrows, ad, phs, gp)

## ---- 5. mutation -------------------------------------------------------------------------
h(2, "5. Mutation")
h(3, "Gene-level binary files")
w("Rows = Ensembl ids, columns = samples. Values and shapes are in section 1 (Mutation binary). Genes x samples per cohort:\n")
tbl(SUMd[type == "mut_bin", .(cohort, genes = rows, samples = cols, distinct_values, frac_1 = NA_real_)][, frac_1 := NULL][])
mf <- list(); mcols <- list()
for (C in COH) {
  f <- ALLF[[C]]["maf"]; if (is.na(f) || !file.exists(f)) next
  cat("maf", C, "\n")
  mc <- names(fread(f, nrows = 0, sep = "\t", quote = ""))
  m <- fread(f, sep = "\t", quote = "", colClasses = "character", na.strings = NULL)
  sc <- grep("sample|barcode|case", names(m), ignore.case = TRUE, value = TRUE)
  mcols[[C]] <- mc
  sid <- if (length(sc)) m[[sc[1]]] else rep(NA, nrow(m))
  vc <- if ("Variant_Classification" %in% names(m)) m$Variant_Classification else NA
  hg <- grep("HGVSp|aaChange", names(m), value = TRUE)
  mf[[C]] <- data.frame(cohort = C, rows = nrow(m), cols = ncol(m), sample_col = paste(sc, collapse = "/"), distinct_samples = uniqueN(sid),
    sample_examples = cpr(unique(sid), 3), samples_in_prot_ids = sum(unique(sid) %in% unlist(IDS[[C]][c("prot_T","prot_N")])),
    samples_in_mut_bin = sum(unique(sid) %in% IDS[[C]]$mut_bin), hugo_col = paste(grep("Hugo|gene_name", names(m), value = TRUE), collapse = "/"),
    gene_col_examples = cpr(unique(m[[1]]), 2), hgvs_cols = paste(hg, collapse = "/"), hgvs_examples = if (length(hg)) cpr(unique(m[[hg[1]]]), 3) else "",
    variant_classes = if (!is.na(vc[1])) paste(names(sort(table(vc), decreasing = TRUE)), sort(table(vc), decreasing = TRUE), sep = ":", collapse = " ") else "")
  if (C == "BRCA") MAF1 <- head(m, 3)
  rm(m); gc(verbose = FALSE)
}
h(3, "MAF files")
w("MAF columns (first cohort): ", paste(mcols[[1]], collapse = ", "), "\n")
w("Column sets identical across cohorts: ", all(sapply(mcols, identical, mcols[[1]])), "\n")
tbl(rbindlist(mf))
if (exists("MAF1")) { w("First MAF rows (BRCA), transposed:\n"); cb(capture.output(print(t(as.data.frame(MAF1))))) }

## ---- 6. meta -------------------------------------------------------------------------------
h(2, "6. Meta (clinical) files")
w("The PDC `Clinical_meta_data_v1` zip has one `{cohort}_meta.txt` per cohort (ccRCC / HGSC naming). The same files are also in the proteome and phospho zips under `README/`. Line 1 = header, line 2 = declared data type (`data_type` row), then one row per sample.\n")
rd_meta <- function(f) {
  ls <- readLines(f, n = 2, warn = FALSE); ls <- sub("\r$", "", ls)
  hd <- strsplit(ls[1], "\t", fixed = TRUE)[[1]]; ty <- strsplit(ls[2], "\t", fixed = TRUE)[[1]]
  dt <- fread(f, sep = "\t", quote = "", skip = 2, header = FALSE, colClasses = "character", na.strings = c("NA", ""), fill = TRUE)
  list(hd = hd, ty = ty, dt = dt)
}
META <- list(); mrows <- list()
for (C in COH) {
  f <- ALLF[[C]]["meta"]; if (is.na(f) || !file.exists(f)) next
  m <- rd_meta(f); META[[C]] <- m
  ## data columns include the data_type row as column count check
  mrows[[C]] <- data.frame(cohort = C, ncol_header = length(m$hd), ncol_type_row = length(m$ty), ncol_data = ncol(m$dt), samples = nrow(m$dt),
    type_row_first = m$ty[1], tumor_yes = if ("Tumor" %in% m$hd) sum(m$dt[[which(m$hd == "Tumor")]] == "Yes", na.rm = TRUE) else NA,
    normal_yes = if ("Normal" %in% m$hd) sum(m$dt[[which(m$hd == "Normal")]] == "Yes", na.rm = TRUE) else NA,
    dup_ids = anyDuplicated(m$dt[[1]]) > 0, id_patterns = topcls(m$dt[[1]], 3))
}
tbl(rbindlist(mrows))
w("Meta header columns and data types per cohort (first 14 columns shown; full union below):\n")
for (C in names(META)) { m <- META[[C]]; w("- **", C, "** (", length(m$hd), " columns): ", paste(paste0(m$hd, "[", m$ty[seq_along(m$hd)], "]"), collapse = ", ")) }
w("")
u <- rbindlist(lapply(names(META), function(C) { m <- META[[C]]; data.table(cohort = C, col = m$hd, type = m$ty[seq_along(m$hd)]) }))
U <- u[, .(n_cohorts = uniqueN(cohort), declared_types = paste(sort(unique(type)), collapse = "/"), cohorts = paste(cohort, collapse = ",")), by = col]
U <- U[order(-n_cohorts, col)]
w("Union of meta columns across cohorts: **", nrow(U), "** (", sum(U$n_cohorts == length(META)), " present in all ", length(META), " cohorts).\n")
tbl(U)
w("Columns whose declared type differs between cohorts: ", paste(U$col[grepl("/", U$declared_types)], collapse = ", ") |> (\(x) if (x == "") "none" else x)(), "\n")
w("Declared type counts (union, by column): "); cb(capture.output(print(table(unlist(strsplit(U$declared_types, "/"))))))
## survival columns
sv <- rbindlist(lapply(names(META), function(C) { m <- META[[C]]; rbindlist(lapply(c("OS_days","OS_event","PFS_days","PFS_event"), function(cn) {
  if (!cn %in% m$hd) return(data.table(cohort = C, col = cn, present = FALSE, fill = NA_real_, n_nonNA = NA_integer_, distinct = NA_character_))
  x <- m$dt[[which(m$hd == cn)]]; data.table(cohort = C, col = cn, present = TRUE, fill = mean(!is.na(x)), n_nonNA = sum(!is.na(x)),
    distinct = if (grepl("event", cn)) paste(sort(unique(na.omit(x))), collapse = "/") else paste0("range ", fm(suppressWarnings(min(as.numeric(x), na.rm = TRUE))), "..", fm(suppressWarnings(max(as.numeric(x), na.rm = TRUE)))))
})) }))
w("Survival columns in meta (fill = fraction non-NA among the cohort's meta rows):\n"); tbl(sv[, fill := fm(fill, 3)][])
allhd <- unique(unlist(lapply(META, `[[`, "hd")))
sym <- unique(c(GA$gene_name, GA$gene_name_BCM_refined)); sym <- sym[!empty(sym)]
cl <- allhd[allhd %in% sym]; cl2 <- allhd[toupper(allhd) %in% toupper(sym)]
w("Meta column names that equal an HGNC symbol of the annotation table (exact): ", if (length(cl)) paste(cl, collapse = ", ") else "none", "; case-insensitive: ", if (length(cl2)) paste(cl2, collapse = ", ") else "none", "\n")
w("Meta column names that equal a proteome/RNA matrix cohort name, id column or a PDC file column: n/a. Columns ending in `_mutation`: ", paste(allhd[grepl("_mutation$", allhd)], collapse = ", "), "\n")
w("Prefix families of meta columns (text before first `_`):"); cb(capture.output(print(sort(table(sub("_.*", "", allhd)), decreasing = TRUE)[1:12])))
## meta ids vs matrix ids, tumor/normal flags
mr <- list()
for (C in names(META)) {
  m <- META[[C]]; ids <- m$dt[[1]]; I <- IDS[[C]]
  tflag <- if ("Tumor" %in% m$hd) ids[m$dt[[which(m$hd == "Tumor")]] == "Yes"] else character()
  nflag <- if ("Normal" %in% m$hd) ids[m$dt[[which(m$hd == "Normal")]] == "Yes"] else character()
  mr[[C]] <- data.frame(cohort = C, meta_rows = length(ids), tumor_flag = length(tflag), normal_flag = length(nflag),
    both_flags = length(intersect(tflag, nflag)), neither_flag = sum(!ids %in% c(tflag, nflag)),
    meta_in_prot_T = sum(ids %in% I$prot_T), meta_in_prot_N = sum(ids %in% I$prot_N), prot_T_not_in_meta = sum(!I$prot_T %in% ids),
    prot_N_not_in_meta = sum(!I$prot_N %in% ids), tumorflag_eq_protT = identical(sort(tflag), sort(I$prot_T)),
    normalflag_in_protN = if (length(I$prot_N)) sum(nflag %in% I$prot_N) else NA, ids_not_in_any_matrix = sum(!ids %in% unlist(I[setdiff(names(I), "meta")])))
}
w("Meta rows against the matrix files (ids = first column of meta):\n"); tbl(rbindlist(mr))
## compare meta sources
cmp <- sapply(COH, function(C) {
  a <- ALLF[[C]]["meta"]; b <- file.path(DIR$prot, "README", paste0(basename(a)))
  if (!file.exists(b)) b <- file.path(DIR$prot, "README", paste0(C, "_meta.txt"))
  if (!file.exists(a)) return(NA); if (!file.exists(b)) return(NA)
  unname(tools::md5sum(a) == tools::md5sum(b)) })
w("PDC clinical meta byte-identical to the copy in the proteome zip README (OV is `OV_meta.txt` there): ", paste(COH, cmp, sep = "=", collapse = ", "), "\n")

## ---- 7. survival / phenotype / mirror meta ---------------------------------------------------
h(2, "7. Mirror survival, phenotype and meta")
sp <- list()
for (C in COH) {
  a <- ALLF[[C]]
  sv1 <- if (file.exists(a["survival"])) fread(a["survival"], sep = "\t", quote = "") else NULL
  ph <- if (file.exists(a["phenotype"])) fread(a["phenotype"], sep = "\t", quote = "") else NULL
  mm <- if (file.exists(a["meta_mirror"])) rd_meta(a["meta_mirror"]) else NULL
  m <- META[[C]]
  svid <- if (!is.null(sv1)) sv1[[1]] else character()
  sp[[C]] <- data.frame(cohort = C, survival_cols = if (!is.null(sv1)) paste(names(sv1), collapse = ",") else "", survival_rows = length(svid),
    surv_ids_in_meta = sum(svid %in% m$dt[[1]]), surv_nonNA_OS_days = if (!is.null(sv1)) sum(!is.na(sv1$OS_days)) else NA,
    meta_nonNA_OS_days = if (!is.null(m)) sum(!is.na(m$dt[[which(m$hd == "OS_days")]])) else NA,
    pheno_rows = if (!is.null(ph)) nrow(ph) else NA, pheno_cols = if (!is.null(ph)) ncol(ph) else NA,
    pheno_cols_not_in_meta = if (!is.null(ph)) sum(!names(ph)[-1] %in% m$hd) else NA,
    pheno_first_col = if (!is.null(ph)) names(ph)[1] else "", pheno_ids_in_meta = if (!is.null(ph)) sum(ph[[1]] %in% m$dt[[1]]) else NA,
    mirror_meta_cols = if (!is.null(mm)) length(mm$hd) else NA, mirror_meta_rows = if (!is.null(mm)) nrow(mm$dt) else NA,
    mirror_meta_cols_not_in_pdc_meta = if (!is.null(mm)) paste(setdiff(mm$hd, m$hd), collapse = ",") else "",
    pdc_meta_cols_not_in_mirror = if (!is.null(mm)) length(setdiff(m$hd, mm$hd)) else NA)
}
tbl(rbindlist(sp))
## survival agreement
agree <- sapply(COH, function(C) {
  a <- ALLF[[C]]; if (!file.exists(a["survival"])) return(NA); s <- fread(a["survival"], sep = "\t", quote = ""); m <- META[[C]]
  mi <- match(s[[1]], m$dt[[1]]); ok <- !is.na(mi); if (!any(ok)) return(NA)
  mo <- suppressWarnings(as.numeric(m$dt[[which(m$hd == "OS_days")]][mi[ok]])); so <- suppressWarnings(as.numeric(s$OS_days[ok]))
  mean(mo == so | (is.na(mo) & is.na(so)), na.rm = TRUE)
})
w("Fraction of mirror survival rows whose OS_days equals the PDC meta value for the same id: ", paste(COH, fm(agree, 3), sep = "=", collapse = ", "), "\n")
w("Mirror survival id column name: `", names(fread(ALLF$BRCA["survival"], nrows = 0)) [1], "`; the mirror meta id column: `", names(fread(ALLF$BRCA["meta_mirror"], nrows = 0, sep = "\t", quote = ""))[1], "`.\n")
ph1 <- fread(ALLF$BRCA["phenotype"], sep = "\t", quote = "", nrows = 3)
w("Phenotype columns (BRCA): ", paste(names(ph1), collapse = ", "), "\n")
w("Phenotype columns are the meta columns after `OS`/`PFS` (CIBERSORT, xCell, ESTIMATE... and others); the phenotype header is written with CRLF in the mirror.\n")

## ---- 8. TPM mirror ----------------------------------------------------------------------------
h(2, "8. RNA TPM (mirror) vs RNA UQ (PDC)")
tp <- rbindlist(lapply(COH, function(C) {
  I <- IDS[[C]]; R <- ROWS[[C]]; if (is.null(I$tpm)) return(NULL)
  data.table(cohort = C, tpm_file = basename(ALLF[[C]]["tpm"]) , tpm_samples = length(I$tpm), uq_samples = length(unique(c(I$rna_T, I$rna_N))),
    shared_samples = length(intersect(I$tpm, c(I$rna_T, I$rna_N))), tpm_genes = length(R$tpm), uq_genes = length(R$rna_T),
    shared_genes = length(intersect(R$tpm, R$rna_T)))
}))
tbl(tp)
w("TPM sample ids carry a `_T` (tumor) or `_A` (adjacent normal) suffix in the 7 cohorts that use the `removed_circRNA` file; BRCA, COAD and OV use bare ids. After stripping `_T`/`_A`:\n")
tp2 <- rbindlist(lapply(COH, function(C) {
  I <- IDS[[C]]; if (is.null(I$tpm)) return(NULL)
  suf <- sub(".*_([TA])$", "\\1", I$tpm[grepl("_[TA]$", I$tpm)]); b <- sub("_[TA]$", "", I$tpm)
  uq <- unique(c(I$rna_T, I$rna_N))
  data.table(cohort = C, n_T = sum(suf == "T"), n_A = sum(suf == "A"), n_bare = sum(!grepl("_[TA]$", I$tpm)),
    stripped_ids = uniqueN(b), stripped_in_uq_tumor = sum(unique(b) %in% I$rna_T), stripped_in_uq_any = sum(unique(b) %in% uq),
    uq_T_ids_found_as_T = sum(paste0(I$rna_T, "_T") %in% I$tpm), uq_N_ids_found_as_A = sum(paste0(I$rna_N, "_A") %in% I$tpm),
    tpm_ids_not_in_uq = paste(head(setdiff(b, uq), 6), collapse = ","))
}))
tbl(tp2)
w("The TPM file name and the corner-cell handling are described in section 1; TPM values are log2(TPM+1) per the file name (min/median/max in section 1).\n")

## ---- 9. xlsx readmes -----------------------------------------------------------------------------
h(2, "8b. Ids that do not follow a cohort's dominant pattern")
w("Per cohort and data type, ids whose pattern differs from the most frequent pattern (first 8):\n")
od <- rbindlist(lapply(COH, function(C) rbindlist(lapply(names(IDS[[C]]), function(k) {
  x <- IDS[[C]][[k]]; if (!length(x)) return(NULL); cl <- idclass(sub("_[TA]$", "", x)); top <- names(which.max(table(cl)))
  o <- x[cl != top]; if (!length(o)) return(NULL)
  data.table(cohort = C, type = k, dominant = top, n_other = length(o), examples = paste(head(o, 8), collapse = ", "))
}))))
tbl(od)
h(2, "9. README spreadsheets in the zips")
for (nm in c("CPTAC_pancancer_data_freeze_cohort_size.xlsx", "CPTAC_pancancer_data_freeze_file_description.xlsx")) {
  f <- file.path(DIR$prot, "README", nm); if (!file.exists(f)) next
  for (s in excel_sheets(f)) {
    x <- suppressMessages(as.data.frame(read_excel(f, sheet = s, col_types = "text")))
    w("**", nm, " / ", s, "** (", nrow(x), " rows x ", ncol(x), " cols)\n"); cb(capture.output(print(head(x, 45), right = FALSE, width = 200)))
  }
}
h(2, "10. PDC listing")
mf0 <- fread(file.path(D, "pdc_pancancer_files.tsv"), sep = "\t", quote = "")
w("The PDC API listing has ", nrow(mf0), " files; `file_size` is null for every entry (sizes in `downloaded_sizes.tsv`).\n")
tbl(mf0[, .(file_id, file_name, downloaded_bytes)])

h(2, "11. Open questions for the spec")
OQ <- file.path(here, "open_questions.md")
if (file.exists(OQ)) w(readLines(OQ, warn = FALSE)) else w("(none recorded)")

writeLines(buf, OUT)
cat("wrote", OUT, "\n")
