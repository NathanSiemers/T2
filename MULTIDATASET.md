# Multi-dataset support in T2

This branch adds the ability to serve **multiple, independent datasets** from the
T2 schema and Shiny app — datasets that need not be numerically comparable and
whose clinical tables may have completely different column sets.

## The design question

T2's core is a tidy/EAV store: integer-keyed dimension tables (`samples`,
`probes`, `types`), giant long fact tables (`tcgai` ≈ 577 M rows, `tcgacati`), a
`tested` table that separates *sparse-zero* from *genuinely missing*, wide
`clin`/`clinpheno` tables, and dense views (`tcga`, `tcgas`, `tcgacat`,
`tcgacats`) that join them. The app reads choice-lists at startup and `gitr()`
routes every query through those views.

The obvious way to add a second dataset is to bolt a `project`/`dataset` column
onto every tidy row and filter by it. **We deliberately did not do that.** For
this problem it is the wrong tool:

| Constraint | Consequence for a `dataset`-column design |
|---|---|
| Datasets are **not numerically comparable** | The only thing a shared fact table buys you is cross-dataset JOINs — which are semantically meaningless here. You pay for a capability you can't use. |
| New `clin` has **different columns** | A single wide clinical table degenerates into a sparse union-of-all-columns full of NULLs; every query must remember which columns belong to which dataset. |
| `tcgai` is **577 M rows / 36 GB** | Adding `dataset` to the key and rebuilding every composite index is a multi-hour, high-risk rewrite of existing data. |
| Correctness | Every query everywhere must remember to filter by dataset, or it silently mixes incomparable values — a permanent footgun. |

The dataset boundary is a **physical partition, not a row-level attribute.**

## The design we chose: one file per dataset + a registry

Each dataset is a **separate SQLite file** with the **same schema shape**
(`samples`, `probes`, `allprobes`, `types`, `datatypes`, `tested`, `tcgai`,
`tcgacati`, `probe_types`, `clinpheno`, `cohorts` + the four views). The app
holds a **current dataset** and rebuilds its connection and *all* selectize
choice-lists when you switch.

Benefits:

- **Zero migration of the existing 36 GB db.** `tcga.db` is untouched — just
  registered as dataset `TCGA`.
- **Each dataset keeps its own clinical column set natively.** No sparse union
  table; the divergent-columns problem dissolves.
- **Isolation / correctness.** Incomparable numeric scales can never mix; a load
  bug in one dataset cannot corrupt another. Indexes stay small and optimal.
- **Adding a dataset reuses the schema/build code unchanged** — point it at a new
  file.
- If cross-dataset queries are *ever* wanted, SQLite `ATTACH DATABASE` provides
  them on demand without changing the storage model.

This mirrors the namespace pattern already proven in the sibling LimmaViewer app.

## Datasets are self-describing

A dataset's clinical columns differ, so the app cannot hard-code which column is
"the cohort" or "the sample type". Each non-canonical dataset therefore carries a
small **`dataset_meta(key, value)`** table naming its **role map**:

| key | meaning | TCGA value |
|---|---|---|
| `title` / `label` | display strings | "T2: TCGA 2018 Pan-Cancer Database" |
| `cohort_col` | clin column used as the cohort facet (virtual `cohort`) | `tumtype` |
| `subtype_col` | clin column used as the virtual `subtype` | `Subtype_Selected` |
| `sampletype_col` | clin column holding sample type (empty = none) | `sample_type` |
| `normal_label` | value of `sampletype_col` meaning "normal" (for *Exclude Non-tumor*) | `Solid Tissue Normal` |
| `heme_values` | comma-sep cohort values to drop for *Exclude heme* | `LAML,THYM,DLBC` |
| `sampletype_levels` | ordered factor levels for the sample-type column | (7 TCGA levels) |
| `default_x/y/color/size/condition` | initial selectize selections | `cohort` / `CD8A` / `sample_type` / … |

The canonical `tcga.db` predates this convention, so its role map is supplied as
a hard-coded fallback in `dataset_registry.R`. Any column a dataset lacks simply
disables the corresponding virtual column or filter — e.g. the DEMO dataset has
no sample-type concept, so *Exclude Non-tumor* and *Exclude heme* become no-ops
automatically.

## Code map

| File | Change |
|---|---|
| `dataset_registry.R` | **new** — discovers datasets (`tcga.db` + `datasets/*.db`), resolves each one's role map (TCGA fallback → `dataset_meta` → generic introspection), exposes `list_datasets()`, `dataset_info()`, `dataset_db_path()`. |
| `database_connection_shiny.R` | added `open_dataset_con(dbfile)`; default `con` still points at `tcga.db` for startup. |
| `gitr.R` | added `dbfile` + `roles` params; the TCGA-specific clinical synthesis (`subtype`/`cohort`/`lcohort`), the nonormal/noheme filters, and sample-type factoring are now driven by the role map and guarded by column presence. |
| `lib.R` | added `load_dataset_bundle(name)` — opens the chosen db and computes every dataset-anchored object (probe lists, cohorts, role map, defaults, title); `plotter`/`fun_plot1`/`fun_table1` thread `dbfile`/`roles`/`dataset_label`; de-hardcoded the TCGA-only `complete.cases` columns and plot caption. |
| `app.R` | added a **Data set** dropdown; the server keeps a `bundle` reactive, repopulates every selectize on switch, and threads the active dataset into plotting, the CSV download, and the data-types table. |
| `build_demo_dataset.R` | **new** — builds a small, clearly-synthetic second dataset (`datasets/DEMO.db`) with a deliberately different clinical schema and numeric scale, to prove the machinery. |
| `test_multidataset.R`, `test_app_server.R` | **new** — smoke tests for the registry/bundle/gitr stack and for the live Shiny server (load TCGA, switch to DEMO, switch back). |

## How to add a new dataset

1. **Build a `<NAME>.db`** with the standard T2 schema shape. Two options:
   - run the existing `00-master.R` build pipeline pointed at new source files
     (full pipeline), or
   - construct it directly the way `build_demo_dataset.R` does (tables + the four
     views + indexes).
2. **Add a `dataset_meta(key, value)` table** naming the role map and defaults
   (see the table above). Omit/blank any role the dataset doesn't have.
3. **Drop the file in `datasets/`** (i.e. `datasets/<NAME>.db`).
4. Restart the app — the **Data set** dropdown auto-discovers it. No code change.

> Note: `datasets/*.db` and `tcga.db` are gitignored (large/reproducible build
> artifacts). Ship the **builder script**, not the `.db`.

## Validation

```
Rscript build_demo_dataset.R   # builds datasets/DEMO.db
Rscript test_multidataset.R    # registry + bundle + gitr, TCGA & DEMO
Rscript test_app_server.R      # live server: load TCGA, switch DEMO, switch back
```

All checks pass: TCGA behaviour is unchanged (12 804 samples, same defaults),
and DEMO loads, switches, and plots on its own divergent schema with the
sample-type-dependent filters correctly disabled.
