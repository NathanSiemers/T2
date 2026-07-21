# TCGA-TARGET-GTEx (UCSC Toil) → T2 dataset

Builds `datasets/tcgatargetgtex.db`, a third T2 dataset (after `tcga.db` and
`datasets/DEMO.db`) servable by the T2 Shiny app with **no app code change** —
the app auto-discovers any `datasets/*.db` (see `../MULTIDATASET.md`).

## What it is

UCSC Xena's **"TCGA TARGET GTEx"** cohort (Toil RSEM recompute): ~19,131
samples — **TCGA 10,535 / GTEX 7,862 / TARGET 734** — all RNA-seq'd through one
identical pipeline, so expression is **internally comparable across the three
studies**. (It is *not* numerically comparable to `tcga.db`'s PANCAN RNA, which
is a different pipeline — hence a separate dataset file, per the T2
multi-dataset design.) Clinical annotation is intentionally light.

Only one real data type is loaded: gene-level **RNA expression** (`type='rna'`).
The other T2 data types (CNV, mutation, RPPA, methylation, signatures, …) do not
exist for this cohort and are simply absent — every app feature that depends on
them degrades to a no-op automatically.

## Files

| File | Role |
|---|---|
| `00-download.R` | downloads the 3 UCSC source files into `Data/` (idempotent) |
| `build_tcgatargetgtex.R` | builds the db end-to-end (schema, clinical, RNA, views) |
| `Data/` | downloaded sources (gitignored) |
| `../sql_tests.R` | reusable SQL test suite — validate the built db |
| `../ensembl_to_hgnc.R` | **reusable** Ensembl→HGNC collapse (sourced by the build) |
| `../t2_views.R` | **reusable** core view/index DDL (sourced by the build) |

The build **sources shared libraries from the parent** (`ensembl_to_hgnc.R`,
`t2_views.R`) rather than forking them, so the next dataset reuses the same code.

## Build

```sh
Rscript TCGATARGETGTEX/00-download.R          # ~1.3 GB, idempotent
Rscript TCGATARGETGTEX/build_tcgatargetgtex.R # -> datasets/tcgatargetgtex.db
Rscript sql_tests.R datasets/tcgatargetgtex.db tcgatargetgtex   # validate
```

Fast smoke build (subset, scratch output):

```sh
TTG_SUBSET_GENES=1500 TTG_SUBSET_SAMPLES=3000 TTG_OUT=/tmp/ttg.db \
  Rscript TCGATARGETGTEX/build_tcgatargetgtex.R
```

Env knobs: `TTG_OUT` (output path), `TTG_SUBSET_GENES`, `TTG_SUBSET_SAMPLES`
(0 = all), `TTG_PROBE_CHUNK` (insert chunk size).

## Key data decisions

**Expression source.** `TcgaTargetGtex_rsem_gene_tpm` (Ensembl gene ids,
`log2(tpm+0.001)`).

**Ensembl → HGNC.** The matrix is Ensembl-keyed but T2/the app are gene-symbol
centric. Using the gencode.v23 probemap (`id`→`gene`) we translate to HGNC and:
- genes sharing a symbol are **summed in linear space** (un-log → add → re-log)
  — summing logs would multiply expression, which is wrong;
- an Ensembl id mapping to **>1** HGNC symbol is **dropped** (ambiguous);
- an Ensembl id with **no** symbol is **kept as-is** under its Ensembl id.

This logic lives in `../ensembl_to_hgnc.R` for reuse (biomaRt/ensembldb could
supply the same id→symbol map if a probemap weren't available).

**Output unit = `log2(TPM+1)`** (not the source's `log2(tpm+0.001)`). Because we
collapse in linear space we re-log ourselves, and `+1` maps unexpressed genes
(tpm 0) to exactly **0**. That is what lets them collapse into T2's sparse-zero
model: zeros are stored implicitly and the dense `tcgas` view reconstructs them
(`CASE WHEN … ELSE 0`). With the `+0.001` offset, "unexpressed" would be
`-9.97`, defeating sparsity and bloating the fact table.

**Role map** (`dataset_meta`, resolved by `../dataset_registry.R`):

| role | column | values |
|---|---|---|
| `cohort_col` | `disease` | 94 primary-disease/tissue values (the `tumtype` analog; drives the cohort dropdown + cohorts table, labelled with study) |
| `subtype_col` | `study` | TCGA / TARGET / GTEX — the "major cohort" handle (virtual `subtype`) |
| `sampletype_col` | `sample_type` | original UCSC sample types |
| `normal_label` | — | **multi-value**: `Solid Tissue Normal, Normal Tissue, Cell Line` |

`study`, `primary_site`, `detailed_category`, `gender` are also selectable
clinical columns. "Exclude Non-tumor" drops all three normal labels at once —
GTEX "Normal Tissue" is genuinely distinct from TCGA "Solid Tissue Normal", and
both (plus GTEX "Cell Line") are non-tumor. Supporting a multi-value
`normal_label` required a small, backward-compatible change to the shared
`gitr.R`/`dataset_registry.R` (single string still works).

**Heme filter.** `heme_values` lists heme diseases (AML, ALL, DLBC, Thymoma, and
GTEX Whole Blood / Spleen / EBV-lymphocytes / leukemia cell line). The one TARGET
disease containing a literal comma ("…, Induction Failure Subproject") is omitted
because `dataset_meta` list values are comma-separated.
