## CPTAC/test_cptac.R
## ============================================================================
## Tests for the CPTAC dataset: the builder's pure helpers (unit), the built
## datasets/cptac.db's key facts and spot values against the source files, and
## the generic T2 suite (../sql_tests.R). Spec: CPTAC/SPEC.md section 7.
##   Rscript CPTAC/test_cptac.R            (container, repo root or anywhere)
## ============================================================================
suppressMessages({ library(DBI); library(RSQLite); library(data.table) })
.f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
ROOT <- if (length(.f)) normalizePath(file.path(dirname(sub("^--file=", "", .f[1])), "..")) else getwd()
setwd(ROOT)
source("ensembl_to_hgnc.R")
Sys.setenv(CPTAC_LIB_ONLY = "1"); source("CPTAC/build_cptac.R"); Sys.setenv(CPTAC_LIB_ONLY = "")
if (file.exists("t2_api_client.R")) source("t2_api_client.R")
source("gitr.R"); source("dataset_registry.R")

np <- 0; nf <- 0
ok <- function(cond, msg, detail = "") {
  cond <- isTRUE(cond); if (cond) np <<- np + 1 else nf <<- nf + 1
  cat(sprintf("  %s %-60s %s\n", if (cond) " ok " else "FAIL", msg, detail))
}
near <- function(a, b, tol = 1e-4) length(a) == 1 && length(b) == 1 && !is.na(a) && !is.na(b) && abs(a - b) < tol

## ---------------------------------------------------------------------------
cat("\n== helpers (unit) ==\n")
pp <- parse_phospho_id(c("ENSG00000142208.15|ENSP00000450688.1|S473|ABCDEFGHIJKLMNO|1",
                         "ENSG00000000003.15|ENSP00000362111.4|T12|XYZ|2"))
ok(identical(pp$ensg, c("ENSG00000142208.15", "ENSG00000000003.15")), "phospho id: ENSG")
ok(identical(pp$ensp[1], "ENSP00000450688.1") && identical(pp$site, c("S473", "T12")), "phospho id: ENSP, site")
ok(identical(pp$peptide[2], "XYZ") && identical(pp$n, c("1", "2")), "phospho id: peptide, n")
ok(identical(phospho_probe("MAPK1", "Y187"), "MAPK1_Y187.phospho"), "phospho probe name")

d <- data.table(sym = c("A", "A", "A", "B", "B"), site = c("S1", "S1", "S2", "S1", "S1"),
                ensp = c("P1", "P2", "P3", "P5", "P4"), nn = c(10, 30, 5, 7, 7))
k <- pick_ensp(d)
ok(identical(k, c(FALSE, TRUE, TRUE, FALSE, TRUE)), "ENSP tie-break: most non-NA, ties -> smallest ENSP")

ks <- pick_by_symbol(c("E1", "E2", "E3", "E4"), c("HSPA14", "HSPA14", "X", "Y"), c(100, 200, 1, 1))
ok(identical(ks, c(FALSE, TRUE, TRUE, TRUE)), "prot/cnv collapse: keep id with most non-NA")
ks <- pick_by_symbol(c("E2", "E1"), c("S", "S"), c(5, 5))
ok(identical(ks, c(FALSE, TRUE)), "collapse tie -> smallest id")

ok(identical(fmut_value("TTN", "p.K13765E", "Missense_Mutation"), "TTN_p.K13765E_Missense_Mutation"), "fmut string")
ok(identical(fmut_value("KCNH2", "", "Intron"), "KCNH2_NA_Intron"), "fmut: empty aaChange -> NA")
ok(identical(fmut_value("TP53", "p.R213*", "Nonsense_Mutation"), "TP53_p.R213s_Nonsense_Mutation"), "fmut: * -> s")

cases <- c("C3L-01", "NX1", "604")
s <- sample_ids_for(c("C3L-01_T", "C3L-01_A", "C3L-09_T", "xx"), "tpm", cases)
ok(identical(s$sample, c("C3L-01", "C3L-01_N", "C3L-09", "xx")) && identical(s$keep, c(TRUE, TRUE, FALSE, FALSE)),
   "sample id: tpm _T -> case, _A -> case_N, unknown/unsuffixed dropped")
s <- sample_ids_for(c("604", "100002921", "C3L-01"), "tpm", cases)
ok(identical(s$sample, c("604", "100002921", "C3L-01")) && identical(s$keep, c(TRUE, FALSE, TRUE)) && !any(s$normal),
   "sample id: bare tpm ids are tumors, only case ids kept")
s <- sample_ids_for(c("604", "100002921", "NX1"), "tpm", cases, bare_ok = c("604"))
ok(identical(s$keep, c(TRUE, FALSE, FALSE)), "sample id: bare tpm tumor only if a column of the RNA UQ Tumor file")
s <- sample_ids_for(c("NX1", "C3L-01"), "normal", cases)
ok(identical(s$sample, c("NX1_N", "C3L-01_N")), "sample id: _Normal file -> case_N")
s <- sample_ids_for(c("C3L-01"), "tumor", cases)
ok(identical(s$sample, "C3L-01") && !s$normal, "sample id: _Tumor file -> case")

ok(identical(norm_clin_names(c("PTM_SEA_KINASE-PSP_Akt1/AKT1", "CIBERSORT_T_cell_CD4+_naive", " x (y) ", "A__B")),
             c("PTM_SEA_KINASE_PSP_Akt1_AKT1", "CIBERSORT_T_cell_CD4_naive", "x_y", "A_B")), "clinical names normalised")
ok(identical(clin_collide(c("TP53", "Age", "subtype", "POLE_status"), c("TP53", "CD8A")),
             c("TP53_clin", "Age", "subtype_clin", "POLE_status")), "clinical collision suffix _clin")
ok(identical(coerce_event(c("Yes", "No", "1", "0", NA)), c(1, 0, 1, 0, NA)), "events Yes/No/0/1 -> numeric")

## ---------------------------------------------------------------------------
DB <- file.path(Sys.getenv("T2_DATASETS_DIR", "datasets"), "cptac.db")   # the same copy the registry sees
if (!file.exists(DB)) {
  cat("\n(dataset", DB, "not built -- skipping db + suite tests)\n")
} else {
  con <- dbConnect(SQLite(), DB, flags = SQLITE_RO)
  q <- function(s, ...) dbGetQuery(con, s, ...)
  q1 <- function(s, ...) q(s, ...)[1, 1]
  cat("\n== Built dataset facts ==\n")
  cl <- as.data.table(q("SELECT * FROM clinpheno"))
  ok(length(unique(cl$cancer_type)) == 10, "10 cancer_types", paste(sort(unique(cl$cancer_type)), collapse = ","))
  tum <- cl[sample_type == "Primary Tumor", .N, by = cancer_type]
  exp_tum <- c(BRCA = 122, CCRCC = 103, COAD = 107, GBM = 99, HNSCC = 108, LSCC = 108, LUAD = 110, OV = 83, PDAC = 105, UCEC = 95)
  got <- setNames(tum$N, tum$cancer_type)[names(exp_tum)]
  ok(all(got == exp_tum), "tumor counts per cohort (SPEC section 7)", paste(names(got), got, collapse = " "))
  nor <- cl[sample_type == "Solid Tissue Normal", .N, by = cancer_type]
  nexp <- c(CCRCC = 80, COAD = 100, HNSCC = 62, LSCC = 99, LUAD = 101, OV = 19, PDAC = 44, UCEC = 18)
  ngot <- setNames(nor$N, nor$cancer_type)
  ok(all(ngot[names(nexp)] >= nexp) && !any(c("BRCA", "GBM") %in% names(ngot)), "normals >= proteome normals; none in BRCA/GBM",
     paste(names(ngot), ngot, collapse = " "))
  ok(all(grepl("_N$", cl$sample[cl$sample_type == "Solid Tissue Normal"])) && !any(grepl("_N$", cl$sample[cl$sample_type == "Primary Tumor"])),
     "normal samples are exactly the *_N ids")
  ok(identical(names(cl)[1:5], c("sample", "case", "cancer_type", "study", "sample_type")), "clinpheno leading columns")
  ok(all(cl$OS %in% c(0, 1, NA)) && all(cl$PFI %in% c(0, 1, NA)), "OS / PFI in {0,1,NA}")
  ok(is.numeric(cl$OS) && is.numeric(cl$OS.time) && is.numeric(cl$Age), "OS, OS.time, Age numeric")
  ok(!is.null(cl$KDM5C_mutation) && is.character(cl$KDM5C_mutation) && all(cl$KDM5C_mutation %in% c("0", "1", NA)), "BIN flags stored as text (KDM5C_mutation in 0/1/NA)")
  ok(all(is.na(cl$CIBERSORT_B_cell_naive[cl$sample_type == "Solid Tissue Normal"])), "normals: tumor-derived scores are NA")
  ok(any(!is.na(cl$Age[cl$sample_type == "Solid Tissue Normal"])), "normals: Age copied from the case")
  ok(all(sapply(cl[, which(sapply(cl, is.character)), with = FALSE], function(x) all(is.na(x) | validUTF8(x)))), "all text valid UTF-8")

  pr <- q("SELECT probe, key FROM probes")
  pt <- q("SELECT probekey, COUNT(DISTINCT type) n FROM (SELECT probekey, type FROM tcgai UNION SELECT probekey, type FROM tcgacati) GROUP BY probekey")
  ok(all(pt$n == 1), "every probe has exactly one type", paste(nrow(pt), "probes with data"))
  ty <- q("SELECT DISTINCT p.probe, d.type FROM tcgai d JOIN probes p ON p.key = d.probekey")
  sfx <- ifelse(grepl("\\.(prot|phospho|cnv|mut)$", ty$probe), sub(".*\\.", "", ty$probe), "rna")
  ok(all(sfx == ty$type), "tcgai probe suffix matches its type")
  ok(!any(grepl("\\.fmut$", ty$probe)) &&
     q1("SELECT COUNT(*) FROM probe_types pt JOIN probes p ON p.key = pt.probekey WHERE p.probe LIKE '%.fmut'") == 0,
     "fmut probes not in probe_types")
  cat(sprintf("  info  typed probes with a dot in the symbol part: %d of %d (allowed, see SPEC section 3)\n",
              sum(grepl("\\..*\\.(prot|phospho|cnv|mut|fmut)$", pr$probe)), nrow(pr)))
  ok(all(c("CD8A", "CD8A.prot", "TP53.mut", "TP53.fmut") %in% pr$probe), "CD8A, CD8A.prot, TP53.mut, TP53.fmut exist")
  ok(any(grepl("^AKT1_S[0-9]+\\.phospho$", pr$probe)) , "an AKT1 phosphosite exists", paste(head(grep("^AKT1_S[0-9]+\\.phospho$", pr$probe, value = TRUE), 3), collapse = ","))
  dtp <- q("SELECT * FROM datatypes"); ok(setequal(dtp$type, c("rna","prot","phospho","cnv","mut","fmut")), "datatypes: 6 types")
  sp <- q("SELECT * FROM sparse"); ok(all(sp$sparse[sp$type %in% c("rna", "mut")] == 1) && all(sp$sparse[sp$type %in% c("prot","phospho","cnv","fmut")] == 0), "sparse flags")
  ok(q1("SELECT COUNT(*) FROM tcgai WHERE type='fmut'") == 0 && q1("SELECT COUNT(*) FROM tcgacati WHERE type!='fmut'") == 0, "fmut only in tcgacati, nothing else there")
  ok(q1("SELECT COUNT(*) FROM tested WHERE type='fmut'") == 0, "no tested rows for fmut")
  ok(q1("SELECT COUNT(*) FROM tcgai WHERE type!='rna' AND value IS NULL") == 0, "no NULL values outside rna")
  ok(q1("SELECT COUNT(*) FROM tcgai WHERE type='mut' AND value != 1") == 0, "mut stores only 1s")

  ## ---- spot values against the source files --------------------------------
  cat("\n== Spot values (db vs source files) ==\n")
  gm <- fread("CPTAC/Data/Proteome_BCM_GENCODE_v34_harmonized_v1/Proteome_BCM_GENCODE_v34_harmonized_v1/README/Gene_annotation_and_representable_isoform_mapping_table.txt",
              sep = "\t", quote = "", na.strings = NULL, colClasses = "character", select = c("gene", "gene_name"))
  gm <- unique(gm)
  dbval <- function(probe, sample, type) {
    r <- q("SELECT d.value FROM tcgai d JOIN probes p ON p.key=d.probekey JOIN samples s ON s.key=d.samplekey
            WHERE p.probe=? AND s.sample=? AND d.type=?", params = list(probe, sample, type))
    if (nrow(r)) r$value[1] else NA_real_
  }
  D <- "CPTAC/Data"
  rdm <- function(f, short = FALSE) {
    x <- if (short) { h <- strsplit(sub("\r$", "", readLines(f, 1)), "\t")[[1]]
                      y <- fread(f, header = FALSE, skip = 1, sep = "\t", quote = ""); setnames(y, c("id", h)); y }
         else { y <- fread(f, sep = "\t", quote = ""); setnames(y, 1, "id"); y }
    x
  }
  spots <- list()
  chk <- function(label, src, db) {
    if (length(src) != 1 || length(db) != 1) { ok(FALSE, label, sprintf("lookup gave %d source / %d db values", length(src), length(db))); return(invisible()) }
    ok(near(src, db, 1e-5) || (is.na(src) && is.na(db)), label, sprintf("source %s | db %s", format(src, digits = 8), format(db, digits = 8)))
  }
  PF <- file.path(D, "Proteome_BCM_GENCODE_v34_harmonized_v1/Proteome_BCM_GENCODE_v34_harmonized_v1")
  ## prot (CCRCC tumor + normal)
  pT <- rdm(file.path(PF, "CCRCC_proteomics_gene_abundance_log2_reference_intensity_normalized_Tumor.txt"))
  pN <- rdm(file.path(PF, "CCRCC_proteomics_gene_abundance_log2_reference_intensity_normalized_Normal.txt"))
  for (g in c("CD8A", "EGFR")) {
    e <- gm[gene_name == g, gene]; e <- intersect(e, pT$id)[1]
    for (sc in list(c("C3L-00004", "T"), c("C3L-01287", "N"))) {
      src <- if (sc[2] == "T") pT[id == e][[sc[1]]] else pN[id == e][[sc[1]]]
      chk(sprintf("prot %s %s%s", g, sc[1], if (sc[2] == "N") "_N" else ""), src,
          dbval(paste0(g, ".prot"), if (sc[2] == "N") paste0(sc[1], "_N") else sc[1], "prot"))
    }
  }
  ## phospho (CCRCC tumor): first two rows with a unique (gene, site) pair and values
  ph <- rdm(file.path(D, "Phosphoproteome_BCM_GENCODE_v34_harmonized_v1/Phosphoproteome_BCM_GENCODE_v34_harmonized_v1/CCRCC_phospho_site_abundance_log2_reference_intensity_normalized_Tumor.txt"))
  pi <- parse_phospho_id(ph$id); pi$sym <- gm$gene_name[match(pi$ensg, gm$gene)]
  pi$pair <- paste(pi$sym, pi$site); u <- which(!(pi$pair %in% pi$pair[duplicated(pi$pair)]) & is.finite(ph[["C3L-00004"]]) & is.finite(ph[["C3L-00010"]]))
  ok(length(u) >= 2, "phospho: at least two unique (gene, site) rows with values in both samples", paste(length(u)))
  for (i in u[c(2, min(500, length(u)))]) for (sm in c("C3L-00004", "C3L-00010"))
    chk(sprintf("phospho %s %s", phospho_probe(pi$sym[i], pi$site[i]), sm), ph[[sm]][i], dbval(phospho_probe(pi$sym[i], pi$site[i]), sm, "phospho"))
  ## rna (CCRCC TPM): formula log2(sum(2^x - 1 over ids of the symbol, negatives clamped) + 1)
  tf <- Sys.glob(file.path(D, "mirror/CCRCC/CCRCC-gene_TPM*"))[1]
  tp <- rdm(tf, short = TRUE)
  for (g in c("CD8A", "TP53")) for (sm in c("C3L-00004_T", "C3L-00004_A")) {
    e <- intersect(gm[gene_name == g, gene], tp$id); x <- pmax(unlist(tp[id %in% e, ..sm]), 0)
    src <- log2(sum(2^x - 1) + 1)
    chk(sprintf("rna %s %s", g, sm), src, { v <- dbval(g, sub("_A$", "_N", sub("_T$", "", sm)), "rna"); if (is.na(v)) 0 else v })
  }
  ## cnv
  cn <- rdm(file.path(D, "CNV_BCM_v1/CNV_BCM_v1/ccRCC_WES_CNV_gene_ratio_log2.txt"))
  for (g in c("ERBB2", "EGFR")) for (sm in c("C3L-00004", "C3L-00010")) {
    e <- intersect(gm[gene_name == g, gene], cn$id)[1]
    chk(sprintf("cnv %s %s", g, sm), cn[id == e][[sm]], dbval(paste0(g, ".cnv"), sm, "cnv"))
  }
  ## mut (binary): stored 1 or absent = 0
  mb <- rdm(file.path(D, "Mutation_BCM_v1/Mutation_BCM_v1/ccRCC_somatic_mutation_gene_level_binary.txt"))
  for (g in c("VHL", "PBRM1")) for (sm in c("C3L-00004", "C3L-00010", "C3L-00183")) {
    e <- intersect(gm[gene_name == g, gene], mb$id); src <- max(unlist(mb[id %in% e, ..sm]))
    v <- dbval(paste0(g, ".mut"), sm, "mut"); chk(sprintf("mut %s %s", g, sm), src, if (is.na(v)) 0 else v)
  }
  ## fmut: two MAF rows exist as strings in tcgacati
  maf <- fread(file.path(D, "Mutation_BCM_v1/Mutation_BCM_v1/ccRCC_somatic_mutation.maf"), sep = "\t", quote = "", colClasses = "character",
               select = c("Hugo_Symbol", "aaChange", "Variant_Classification", "Tumor_Sample_Barcode"))
  for (i in c(3, 200)) {
    v <- fmut_value(maf$Hugo_Symbol[i], maf$aaChange[i], maf$Variant_Classification[i])
    n <- q1("SELECT COUNT(*) FROM tcgacati c JOIN probes p ON p.key=c.probekey JOIN samples s ON s.key=c.samplekey
             WHERE p.probe=? AND s.sample=? AND c.value=?", params = list(paste0(maf$Hugo_Symbol[i], ".fmut"), maf$Tumor_Sample_Barcode[i], v))
    ok(n >= 1, sprintf("fmut %s %s", maf$Tumor_Sample_Barcode[i], v), paste(n, "row(s)"))
  }
  dbDisconnect(con)

  cat("\n== gitr ==\n")
  roles <- dataset_info("cptac")$roles
  ok(roles$cohort_col == "cancer_type" && roles$sampletype_col == "sample_type", "roles: cancer_type / sample_type")
  vars <- c("CD8A", "CD8A.prot", "cohort", "sample_type", "OS", "OS.time")
  d <- suppressWarnings(gitr(vars, dbfile = DB, roles = roles))
  ok(nrow(d) > 1500, "gitr returns > 1,500 rows", paste(nrow(d), "rows; cols:", paste(intersect(vars, names(d)), collapse = ",")))
  d2 <- suppressWarnings(gitr(vars, dbfile = DB, roles = roles, nonormal = TRUE))
  nnormal <- sum(d$sample_type == "Solid Tissue Normal", na.rm = TRUE)
  ok(nrow(d) - nrow(d2) == nnormal && nnormal > 0 && !any(d2$sample_type == "Solid Tissue Normal", na.rm = TRUE),
     "nonormal removes exactly the Solid Tissue Normal rows", sprintf("%d -> %d (normals %d)", nrow(d), nrow(d2), nnormal))
  ok(all(d$OS %in% c(0, 1, NA)), "gitr OS in {0,1}")

  cat("\n== Generic T2 suite (../sql_tests.R) ==\n")
  source("sql_tests.R")
  r <- run_sql_tests(DB, "cptac", verbose = FALSE)
  fails <- r$results[r$results$status == "FAIL", , drop = FALSE]
  ok(isTRUE(r$ok) && !nrow(fails), "sql_tests.R passes on datasets/cptac.db", sprintf("%d checks", nrow(r$results)))
  if (nrow(fails)) for (i in seq_len(nrow(fails))) cat("      FAIL:", fails$test[i], "-", fails$detail[i], "\n")
  w <- r$results[r$results$status == "WARN", , drop = FALSE]
  if (nrow(w)) for (i in seq_len(nrow(w))) cat("      WARN:", w$test[i], "-", w$detail[i], "\n")
}

cat(sprintf("\n==== %d PASS / %d FAIL ====\n", np, nf))
if (length(grep("^--file=", commandArgs(FALSE)))) quit(status = if (nf > 0) 1 else 0)
