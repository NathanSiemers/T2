# T2: what is in which file

An index for whoever opens this repository cold (Nathan in RStudio, or Claude with a context
budget): one line per file, the main functions, and at the end an assessment of how the
code should be cut up (Nathan's question of 2026-10-09). Load order is app.R → global.R →
database_connection_shiny.R → lib.R (which sources the rest) → input_validation.R → t2_thanos.R.

## The Shiny app (R, repository root)

| file | lines | what it holds |
|---|---|---|
| `app.R` | 800 | the UI (six tabs) and the server: data-source switch, sticky picks, the sample choice (groups / exclusions), the Thanos instances per source, the Plot buttons, Publish, About, download |
| `lib.R` | 940 | loader of the files below; `load_dataset_bundle()` / `load_source_bundle()` / `list_sources()` (everything the app knows about a dataset, read once per file version); `plotter()` (the ggplot builder, 550 lines) with `t2_plot_refusal()`; `fun_plot1()` / `fun_table1()` (the entry points from the server) |
| `gitr.R` | 380 | `gitr()`: the data retriever (probes + clinical, filters, factor typing) and `t2_sample_keep()`, the one sample predicate; `T2_LIMITS`; `gitr_memo()` |
| `t2_api_client.R` | 230 | the same data layer over the t2api service (`T2_API_URL`): `gitr_api()`, `t2_api_bundle()`, caches |
| `dataset_registry.R` | 200 | which datasets exist, their roles (cohort / subtype / sample-type columns, heme values, parts), defaults; `dataset_meta` reader |
| `t2_presets.R` | 180 | ready-made sample subsets and data sources: `t2_read_presets()`, `t2_sources()`, `t2_filter_choices()` (what to offer), `t2_presets_mask()`; the R mirror of the service |
| `t2_thanos.R` | 215 | the Filter tab's bridge to Thanos: `backend_t2()` (columns served from gitr, per data source), `t2_describe_filters()` |
| `input_validation.R` | 120 | `sanitize_t2_input()` / `sanitize_t2_samples()` / style and tweak whitelists: nothing from the browser reaches SQL or ggplot unchecked |
| `plot_style.R` | 480 | the Appearance settings: `T2_STYLE` menus, the ggplot tweak registry (`T2_TWEAKS`), themes, fonts |
| `figure_export.R` | 180 | the Publish tab: figure presets (sizes, dpi), validation, rendering to PNG/TIFF/PDF |
| `survival_prototype.R` | 300 | Kaplan–Meier mode: `survival_km()`, `T2_ENDPOINTS`, the risk table styling |
| `marker_ops.R` | 50 | `combine_markers_median_z()`, `residualize_on()` (several Y probes; "Remove influences of") |
| `t2_search.R` | 55 | ranked search for the variable menus (`update_selectize_ranked()`) |
| `t2_descriptions.R` | 35 | what the clinical columns mean (from the service's TSV or `/meta`) |
| `t2_contact.R` | 65 | the contact form on About (POST to the service) |
| `global.R`, `database_connection_shiny.R` | 60 | site constants; the default SQLite connection (none in service mode) |

## Databases and tools

| file | what |
|---|---|
| `TCGA/`, `TCGATARGETGTEX/`, `build_demo_dataset.R` | the dataset builders (see `T2Mobile/NOTES.md` and the memory notes on rebuilding) |
| `default_filters.R` | the presets of every dataset (`T2_DEFAULT_FILTERS`), written into each database as `default_filters`; `Rscript default_filters.R check|write <db> <dataset>` |
| `dataset_meta.R` | `Rscript dataset_meta.R show|set <db> key=value` |
| `test_*.R` | headless tests: `test_app_sources.R` (data sources / presets in the app), `test_app_thanos.R` (Filter tab data path), `test_app_server.R`, `test_app_survival.R`, `test_t2_backend.R`, `test_gitr_api.R` (files vs service), `test_figure_export.R`, `test_multidataset.R`, `test_plot_style.R`; run in the rstudio container (`docker exec -w /home/rstudio/R/T2 r101101-rstudio-1 Rscript <test>`), with `T2_DATASETS_DIR` for other database copies |
| `T2Mobile/` | the query service (Go), the iPhone app, the standby unit, their docs and `NOTES.md` |

## How monolithic is this, and what would help (assessment, 2026-10-09)

The numbers: 18 R files, 4,400 lines. Sixteen are one-topic files of 35–480 lines that can
be read whole when a task touches them. Two are not: `lib.R` (940) and `app.R` (800).

What reading costs each of us: for Claude, a file read is paid in context; tonight gitr.R
was read whole (worth it: every change touched it) but lib.R only in three slices found by
grep, and app.R in four. That works, but each slice is a guess about where something is,
and a wrong guess is a second read. For Nathan in RStudio the cost is navigation and the
mental model: the 550-line `plotter()` is one function with eleven stages (fetch, summary,
multi-Y stacking, z-scores, conditioning, waterfall, aesthetics, layers, facets, labels,
theme), and a change to any stage means holding the whole function in mind.

What would help, in order of value for effort:

1. **This index.** The cheapest win: the first thing to read instead of grepping.
2. **Split `lib.R` into three files it already is in spirit** — `t2_bundle.R` (the bundle,
   sources, menu list, ~130 lines), `t2_plotter.R` (`plotter()`, the refusals, the message
   plot, ~600) and `t2_entry.R` (`fun_plot1()`, `fun_table1()`, ~120) — and keep `lib.R` as
   the loader so nothing else changes. Mechanical, half an hour, no behaviour change; the
   tests cover it.
3. **Cut `plotter()` into its stages** (`plot_data()`, `plot_aesthetics()`, `plot_layers()`,
   `plot_labels()`, each a function of the data frame and the settings). This is the one
   change that helps both of us most, and the one that needs care: the stages share a dozen
   local variables. Worth doing with the Publish and survival tests as the net.
4. **`app.R`**: move the UI builders (`filter_tab_ui()`, `publish_tab_ui()`, the CSS, the
   style selectors) into `t2_ui.R`, leaving the server (470 lines) where it is; the server's
   blocks are already commented as sections and read fine top to bottom. Splitting the
   server into functions would scatter the reactive graph, which is harder to follow than
   one long file.
5. Keep the convention of the last two days: a new feature is a new small file with a
   header that says what it holds and where its tests are.

Not worth it now: an R package (roxygen, namespaces) for an app that is sourced in a
container; the overhead would outweigh the gain for a one-maintainer code base.
