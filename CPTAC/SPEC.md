# CPTAC → T2: builder specification (`CPTAC/build_cptac.R`)

Fixed by the lead on 2026-10-18 from `Data/profile.md` (the measured facts) and the approved plan
(`/home/nathan/.claude/plans/our-t2-databases-and-unified-stardust.md`). The builder implements
this document; where the two disagree, this document wins. Template for style and structure:
`../TCGATARGETGTEX/build_tcgatargetgtex.R` (sections, `say()`, env knobs, chunked inserts,
`finalize_t2_core`). Shared code to source from the repo root: `ensembl_to_hgnc.R`,
`t2_views.R`, `default_filters.R`. Output: `datasets/cptac.db` (env `CPTAC_OUT`).

## 0. Inputs (all under `CPTAC/Data/`, see `01-profile.R` for the exact paths)

Cohorts and their names in the files: BRCA, CCRCC (RNA/CNV/Mutation/Clinical zips say `ccRCC`),
COAD, GBM, HNSCC, LSCC, LUAD, OV (those zips say `HGSC`), PDAC, UCEC. Study: BRCA, COAD, OV are
`CPTAC-2`; the other seven `CPTAC-3`.

| type | file(s) per cohort | notes |
|---|---|---|
| prot | proteome zip `{C}_proteomics_gene_abundance_log2_reference_intensity_normalized_{Tumor,Normal}.txt` | CRLF; Ensembl rows; 9,151–12,760 genes per cohort |
| phospho | phospho zip `..._phospho_site_abundance_log2_reference_intensity_normalized_{Tumor,Normal}.txt` | row id `ENSG\|ENSP\|S123\|peptide\|n`; `-Inf` cells exist |
| rna | mirror `mirror/{C}/{C}-gene_TPM[_removed_circRNA]_tumor_normal_raw_log2(x+1)_BCM.txt` | header lacks the corner cell (one field short); `_T`/`_A` ids in 7 cohorts, bare ids in BRCA/COAD/OV; small negatives |
| cnv | CNV zip `{C}_WES_CNV_gene_ratio_log2.txt` | tumors only; 60,603 genes; LUAD CRLF |
| mut | Mutation zip `{C}_somatic_mutation_gene_level_binary.txt` | 0/1, only mutated genes listed |
| fmut | Mutation zip `{C}_somatic_mutation.maf` | 93 cols; `Hugo_Symbol`, `aaChange`, `Variant_Classification`, `Tumor_Sample_Barcode` |
| clinical | Clinical zip `{C}_meta.txt` | row 1 header, row 2 declared types (CON/BIN/ORD), then one row per CASE (`idx`) |
| gene map | proteome zip `README/Gene_annotation_and_representable_isoform_mapping_table.txt` | 108,777 rows (one per transcript), 60,669 distinct `gene`; columns `gene, transcript, protein, gene_name, gene_name_BCM_refined, Type, MANE, ...` |

Read everything with `data.table::fread` (handles CRLF); strip any trailing `\r` from names anyway.
For the TPM files, read the header line separately and prepend an id column name.

## 1. Gene symbols (HGNC)

Symbol = `gene_name` of the mapping table (one row per distinct `gene`; all 60,669 have one),
looked up by the **versioned** Ensembl id exactly as it appears in the matrices (0 mismatches
measured). Do not use `gene_name_BCM_refined` (it carries `_ENSG…` / `_PAR_Y` suffixes). 78
symbols are shared by more than one Ensembl id; the per-type collapse rules below handle them.
An Ensembl id with no symbol would be kept under its id (none expected; log the count).

## 2. Samples

- The **case universe** of a cohort = the `idx` values of its `{C}_meta.txt` (BRCA 122, CCRCC 103,
  COAD 110, GBM 99, HNSCC 108, LSCC 108, LUAD 110, OV 93, PDAC 105, UCEC 113 incl. `NX1..NX18`).
  A matrix column whose case is not in the meta is **dropped and counted in the log** (expected:
  the extra TPM ids, BRCA's numeric TPM ids).
- **T2 sample id**: tumor = the case id as written (`C3L-01287`, `01BR001`, `604`, `11LU013`);
  normal adjacent tissue = case id + `_N` (`C3L-01287_N`, `NX1_N`). Which it is comes from the
  file (`_Tumor` / `_Normal` file name; TPM suffix `_T` → tumor, `_A` → normal). In the bare-id
  TPM files (BRCA, COAD, OV) a column is a tumor sample **iff its id is a column of the cohort's
  PDC RNA UQ Tumor file** (`RNA_BCM_v1/{C}_RNAseq_gene_RSEM_coding_UQ_1500_log2_Tumor.txt`, BCM's
  own tumor labelling; BRCA 121, COAD 106, OV 82 ids); every other column is dropped and counted.
  Nothing in those three files is treated as normal. (Measured 2026-10-18: the OV TPM file has
  columns for four normal-only cases, 01OV008/010/013/019; without this rule they became tumors.)
- A sample exists if any type has a column for it. `sample_type` = `Primary Tumor` or
  `Solid Tissue Normal`. Ids are never shared across cohorts (measured); assert uniqueness anyway.
- `tested(sample, value=1, type)`: one row per (sample, type) that has a column for the sample in
  that type's file(s) (after the case filter). For `fmut` no `tested` rows (categorical).

## 3. Probe names and types

| type | probe name | sparse | default | r_datatype | what is stored |
|---|---|---|---|---|---|
| rna | `CD8A` (bare) | 1 | 0 | numeric | log2(TPM+1) after collapse; values ≠ 0 stored, NA stored as NULL rows (as TOIL) |
| prot | `CD8A.prot` | 0 | – | numeric | log2 intensity as shipped; every non-NA value stored, NA = no row |
| phospho | `MAPK1_Y187.phospho` | 0 | – | numeric | as shipped; `-Inf`/`Inf`/NaN → NA (no row) |
| cnv | `CD8A.cnv` | 0 | – | numeric | log2 ratio as shipped; non-NA stored |
| mut | `TP53.mut` | 1 | 0 | factor | only the 1s stored; tested = all columns of the binary file |
| fmut | `TP53.fmut` | 0 | – | factor | `tcgacati`: `Hugo_Symbol_aaChange_Variant_Classification` |

No probe name may contain a dot other than the type suffix; assert. One probe name ↔ one type
(a `.prot` name never appears in `tcgai` with another type); `probes.probe` UNIQUE.

**rna**: `collapse_ensembl_to_hgnc(expr, map, from_log=TRUE, log_base=2, log_offset=1,
relog_offset=1)` with `map = load_ensembl_hgnc_map(mapping[, .(gene, gene_name)])`. Before the
collapse clamp negatives to 0 (`x[x < 0] <- 0`; measured min −0.01). Genes sharing a symbol are
summed in linear space (same as TOIL). Run it per cohort (different gene sets: 59,361 vs 60,669)
and union the probes; a probe missing from a cohort's file is simply untested there? **No**:
`tested` is per (sample, type), not per probe, so a gene absent from a cohort's TPM file would
read as 0 for that cohort's samples. The 1,308 genes present only in the BRCA/COAD/OV files are
circRNA-related ids; to keep "0 means unexpressed" true, **restrict rna to the 59,361 genes common
to all ten files** before the collapse. Log the number dropped.

**prot**: per Ensembl id, symbol via the map. When two ids share a symbol (`HSPA14` only, per
profile; code the general rule): keep the row with more non-NA values over all cohorts, drop the
other, log it. Proteome gene sets differ per cohort (7,783 common, 15,100 union): a gene absent
from a cohort's file is NA for that cohort's samples, which the `sparse=0` rule gives for free.
Probe = `SYMBOL.prot`.

**phospho**: split the row id on `|`: `ENSG, ENSP, site, peptide, n`. Probe = `SYMBOL_site.phospho`
(e.g. `MAPK1_Y187.phospho`; site is always one `[STY]digits` token, measured). The (SYMBOL, site)
pair occurs with more than one ENSP for 344 pairs: pool the rows per (SYMBOL, site) across all
cohorts, keep the ENSP with the most non-NA values over all cohorts, drop the other ENSP rows,
log the count. Within one file the (ENSG, ENSP, site) triple is unique (measured); assert, and if
it ever is not, keep the row with more non-NA values.

**cnv**: restrict to `Type == "protein_coding"` genes of the mapping table (~20k; the full 60,603
would be 60 M rows of little use). Collapse by symbol: keep the row with more non-NA values.

**mut**: symbol via map; two ids on one symbol → elementwise max (OR). Store only cells == 1.
`datatypes` row `mut, factor`.

**fmut**: value = `paste(Hugo_Symbol, aaChange, Variant_Classification, sep = "_")` with `*`
replaced by `s` and an empty `aaChange` written as `NA` (TCGA's format: `TTN_p.K13765E_Missense_Mutation`,
`KCNH2_NA_Intron`). Keep all variant classes (TCGA does). Probe = `Hugo_Symbol.fmut`. Sample =
`Tumor_Sample_Barcode` (must be a case id; drop + count others). Several rows per (sample, probe)
are fine (readers keep the smallest). Rows go to `tcgacati`; fmut probes go into `probes` and
`allprobes` but must NOT appear in `probe_types` (build_t2_probe_types reads tcgai only: good).

## 4. clinpheno (one row per T2 sample)

Columns, in this order: `sample`, `case`, `cancer_type` (BRCA … UCEC), `study` (CPTAC-2/3),
`sample_type`, then the meta columns. Meta handling:
- drop `idx` (→ `case`), `Tumor`, `Normal` (replaced by `sample_type`);
- rename survival: `OS_days→OS.time`, `OS_event→OS`, `PFS_days→PFI.time`, `PFS_event→PFI`; coerce
  the events to 0/1 numeric (assert the values are in {0,1,NA} after coercion; if the source says
  Yes/No, map Yes→1, No→0 and say so in the log);
- normalise every other name: `gsub("[^A-Za-z0-9_]+", "_", x)`, squeeze `_+`, strip leading/
  trailing `_`; assert uniqueness after normalisation;
- rename `POLE` → `POLE_status`; then, generically, any clinical column equal to a probe name of
  any type or to `cohort`, `subtype`, `lcohort` gets `_clin` appended (log it);
- union of the ten column sets; a cohort lacking a column has NA there;
- CON columns numeric; BIN/ORD columns kept as text as shipped (the app factors them);
- **normal rows** (`_N` samples) copy from their case only: `Age, Sex, BMI, Tobacco_smoking_history,
  Stage, Histologic_Grade, Path_Stage_pT, Path_Stage_pN, Tumor_Size_cm, OS, OS.time, PFI, PFI.time`;
  every other meta column is NA for a normal (they are tumor-derived scores). `NX*` normals have
  their own meta row: same whitelist rule.
- All text valid UTF-8 (`iconv(x, "UTF-8", "UTF-8", sub = " ")`), as TOIL does.

`allprobes` = all probe names (every type, fmut included) + every clinpheno column name except
`sample`.

## 5. cohorts, types, datatypes, dataset_meta, default_filters

`cohorts(cohort, lcohort, cohortstring)`, one row per cancer_type, ordered by code:

| cohort | lcohort | cohortstring |
|---|---|---|
| BRCA | breast invasive carcinoma | BRCA (breast invasive carcinoma, CPTAC-2) |
| CCRCC | clear cell renal cell carcinoma | CCRCC (clear cell renal cell carcinoma, CPTAC-3) |
| COAD | colon adenocarcinoma | COAD (colon adenocarcinoma, CPTAC-2) |
| GBM | glioblastoma | GBM (glioblastoma, CPTAC-3) |
| HNSCC | head and neck squamous cell carcinoma | HNSCC (… , CPTAC-3) |
| LSCC | lung squamous cell carcinoma | LSCC (…, CPTAC-3) |
| LUAD | lung adenocarcinoma | LUAD (…, CPTAC-3) |
| OV | high-grade serous ovarian carcinoma | OV (…, CPTAC-2) |
| PDAC | pancreatic ductal adenocarcinoma | PDAC (…, CPTAC-3) |
| UCEC | uterine corpus endometrial carcinoma | UCEC (…, CPTAC-3) |

`types(key, type, description, example, reference, source_url, source_file)`, six rows. Reference
for all: "Li Y et al., Proteogenomic data and resources for pan-cancer analysis. Cancer Cell 2023;
41:1397-1406 (CPTAC Pan-Cancer harmonized data freeze v1, BCM pipeline, GENCODE v34). Data generated
by the National Cancer Institute Clinical Proteomic Tumor Analysis Consortium (CPTAC)."
source_url `https://pdc.cancer.gov/pdc/cptac-pancancer` (rna: also the LinkedOmicsKB mirror
`https://kb.linkedomics.org/download`). Descriptions:
- rna: "Gene-level RNA-seq expression, BCM pipeline, Ensembl genes collapsed to HGNC symbols (summed in linear space), log2(TPM+1). Tumors and normal adjacent tissue." example `CD8A`.
- prot: "Gene-level protein abundance from TMT mass spectrometry, log2 intensity normalized to the cohort's pooled reference (BCM harmonized). Comparable within a cohort; across cohorts only with care, each cohort has its own reference. Missing when the protein was not quantified." example `CD8A.prot`.
- phospho: "Phosphosite abundance (one site per probe, GENE_S123.phospho), log2 intensity normalized to the cohort's reference, BCM harmonized. Missing when the site was not quantified." example `MAPK1_Y187.phospho`.
- cnv: "Gene-level somatic copy number from whole-exome sequencing, log2 ratio tumor/normal (0 = neutral), protein-coding genes, BCM pipeline." example `ERBB2.cnv`.
- mut: "Somatic mutation present (1) or absent (0) per gene, whole-exome sequencing, BCM pipeline." example `TP53.mut`.
- fmut: "Somatic mutations spelled out: gene, protein change and variant class (TP53_p.R273H_Missense_Mutation), from the BCM MAF." example `TP53.fmut`.

`datatypes`: rna/prot/phospho/cnv numeric; mut/fmut factor. `set_t2_sparse(con, "rna", TRUE, 0)`,
`set_t2_sparse(con, "mut", TRUE, 0)`, `set_t2_sparse(con, t, FALSE)` for prot, phospho, cnv, fmut.

`dataset_meta` (lists `|`-separated):
```
title              T2: CPTAC Pan-Cancer Proteogenomics (2023 harmonized freeze)
label              CPTAC Pan-Cancer
cohort_col         cancer_type
subtype_col        (empty string)
sampletype_col     sample_type
normal_label       Solid Tissue Normal
heme_values        (empty)
sampletype_levels  Primary Tumor|Solid Tissue Normal
default_x          cohort
default_y          CD8A
default_color      sample_type
default_size       (empty)
default_condition  (empty)
default_cohorts    BRCA|CCRCC|COAD|GBM|HNSCC|LSCC|LUAD|OV|PDAC|UCEC
```
Then `source(file.path(ROOT, "default_filters.R")); write_default_filters(con, "cptac")` (the
`cptac` entry exists; it uses `sample_type`). Then `finalize_t2_core(con)`.

## 6. Build mechanics

- Env knobs: `CPTAC_OUT` (default `datasets/cptac.db`), `CPTAC_COHORTS` (comma list, default all),
  `CPTAC_TYPES` (default `rna,prot,phospho,cnv,mut,fmut`), `CPTAC_SUBSET_GENES` (0 = all; applies to
  rna/prot/phospho/cnv row counts for smoke builds), `CPTAC_CHUNK` (probe chunk for inserts).
- Build to `<OUT>.building`, create indexes/views, then rename to `<OUT>` (atomic promote; the
  `.gitignore` already ignores `*.db.building*`). Never write to a file that may be served.
- Insert `tcgai` in probe chunks like TOIL; keep memory sane (phospho: process per cohort, melt,
  filter, append). Print a BUILD SUMMARY: samples by cancer_type × sample_type, probes per type,
  tcgai/tcgacati rows per type, tested rows per type, dropped columns/rows per rule, elapsed.
- Expected sizes: ~1,567+ samples (tumors 1,043 + normals ≥ 524, plus RNA-only normals), tcgai
  roughly 15 M (prot) + 60–90 M (phospho) + 25 M (rna) + 20 M (cnv) rows; a full build of an hour
  or two is normal. Run in the container:
  `docker exec -u rstudio -w /home/rstudio/R/T2 r101101-rstudio-1 Rscript CPTAC/build_cptac.R`
  (with `CPTAC_OUT=/home/rstudio/R/T2-devdata/scratch/cptac-smoke.db CPTAC_SUBSET_GENES=800
  CPTAC_COHORTS=CCRCC,OV` for a smoke build; create the directory if needed; never write smoke
  builds into `datasets/`).

## 7. Tests (`CPTAC/test_cptac.R`, template `../TCGATARGETGTEX/test_tcgatargetgtex.R`)

Unit (no db needed): phospho id parsing and probe naming; the ENSP tie-break; the prot
"most non-NA" collapse; the fmut string (`*`→`s`, empty aaChange → `NA`); the sample id rule
(`_T`/`_A`, bare, `_Normal` file → `_N`); the clinical name normalisation and collision suffix.
Built db facts: 10 cancer_types; tumor counts per cohort equal the meta tumor rows
(BRCA 122, CCRCC 103, COAD 107, GBM 99, HNSCC 108, LSCC 108, LUAD 110, OV 83, PDAC 105, UCEC 95)
— COAD has three meta cases with no data at all, OV has 93 meta rows of which 83 are tumors;
normal counts ≥ proteome normals (CCRCC 80, COAD 100, HNSCC 62, LSCC 99, LUAD 101, OV 19, PDAC 44,
UCEC 18; BRCA, GBM 0); every probe has exactly one type; no probe with two dots; `CD8A`,
`CD8A.prot`, `TP53.mut`, `TP53.fmut` exist and `MAPK1_Y187.phospho` and an `AKT1_S…phospho` site exist;
spot values: for 2 genes × 2 samples per type the db value equals the source file's (rna after
the collapse formula); `gitr()` on `c("CD8A","CD8A.prot","cohort","sample_type","OS","OS.time")`
returns > 1,500 rows; `nonormal = TRUE` removes exactly the `Solid Tissue Normal` rows; OS ∈ {0,1}.
Then `source("sql_tests.R"); run_sql_tests("datasets/cptac.db", "cptac")` — must pass (WARNs on
sparse=0 types are expected; FAILs are not).

## 8. README

`CPTAC/README.md` in the shape of `../TCGATARGETGTEX/README.md`: what the dataset is, files,
build commands, key data decisions (this document condensed), the CPTAC attribution sentence.
