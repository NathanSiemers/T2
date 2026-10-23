# The dataset contract

What a T2 dataset file promises, what the query service (`t2api`) guarantees to its clients, and
the few rules the tools (the Shiny app, the iPhone app) are allowed to assume. Three layers,
kept apart on purpose:

| layer | owns | changes by |
|---|---|---|
| **data / schema** | the SQLite file: tables below, `dataset_meta`, `types.label` | a builder run, or `dataset_meta.R` on a staged copy; released with `deploy.sh data-stage` + `data` |
| **api** (`T2Mobile/service`) | the ONLY interpreter of `dataset_meta`; everything derived (handles, time-to-event variables, type labels, normalized defaults) is derived here | `deploy.sh service` |
| **apps** | consumers of `/v1/{ds}/meta` and `/v1/{ds}/probes`; nothing dataset-specific in code | `deploy.sh code` (Shiny), TestFlight (iOS) |

The Shiny app's file mode (SQLite without the service, used by the builders' tests and the
`equiv` suite) reads the same `dataset_meta` keys **verbatim** and never re-derives anything. If a
rule needs code, it is written once, in Go.

## 1. The file

Every dataset is a file `datasets/<NAME>.db`; the file name is the dataset's name (`TCGA.db`,
`cptac.db`, `tcgatargetgtex.db`, `DEMO.db`). There is no canonical file beside the directory
(decision 2026-10-19; `tcga.db` at the top level is the legacy layout, accepted by the service
during the transition). Datasets are listed by the optional `dataset_meta` key `order` (ascending,
missing = after the ordered ones), then alphabetically.

Numeric fact values are stored rounded to 6 decimals (`round(x, 6)` in the builder, after every
transform), so float noise never reaches the file, the api or the apps (rule of 2026-10-19; applies
from each dataset's next rebuild). Future builds store `tcgai` WITHOUT ROWID with primary key
`(probekey, type, samplekey)` and no separate heap (the covering index is the table).

Tables (the names are historical; every dataset uses them): `samples(key, sample)`,
`probes(key, probe)`, `allprobes(probe)` (= probes + the clinical column names offered as
variables), `types(key, type, description, example, reference, source_url, source_file, label)`,
`datatypes(type, r_datatype)` with `r_datatype ∈ {numeric, factor}`, `tested(sample, value, type)`,
`tcgai(samplekey, probekey, type, value)` (numeric facts), `tcgacati(samplekey, probekey, type,
value)` (categorical facts), `probe_types(probekey, type)`, `clinpheno(sample, ...)`,
`cohorts(cohort, lcohort, cohortstring)`, `dataset_meta(key, value)`, `default_filters`, `sparse(type,
sparse, default_value)`; views `tcgas, tcga, tcgacats, tcgacat, bytype` from `t2_views.R`
(`finalize_t2_core()`).

Naming rule for probes (a convention the builders follow; the api resolves it): **one probe name
belongs to one type**. The type of a name is the text after its last dot when that text is a
`datatypes` type (`TP53.mut`, `CD8A.prot`, `MAPK1_Y187.phospho`), otherwise the `probe_types` row
(bare RNA names, including GENCODE names such as `AL627309.1`). Sparse model per type: `sparse=1`
means a tested sample without a row reads 0 (NA is a stored NULL row); `sparse=0` means no row =
NA.

### `dataset_meta` keys

Lists are `|`-separated. Every key is optional for the api (fallbacks below), but the conformance
check (`dataset_contract_check.R`) requires the ones marked **req** of every file built here.

| key | meaning |
|---|---|
| `order` | listing position (integer; TCGA = 1) |
| `hidden` (optional) | `1` / `true` / `yes` (any case, surrounding blanks ignored) = the apps do not list the dataset (DEMO); anything else or absent = listed. The conformance check accepts exactly those words and their opposites (`0` / `false` / `no`) and FAILs any other value, so the check and the service's `metaTrue` agree on every accepted spelling. The api serves it as `"hidden": bool` in `/v1/datasets` and still answers every endpoint for it |
| `title` **req**, `label` **req** | display strings (`"T2: CPTAC Pan-Cancer …"`, `"CPTAC Pan-Cancer"`) |
| `cohort_col` **req** | clinical column that becomes the virtual `cohort` |
| `subtype_col` | clinical column that becomes the virtual `subtype` (the sub-cohort handle); empty = none |
| `sampletype_col`, `sampletype_levels`, `normal_label` | the sample-type column, its level order, the value(s) meaning "normal" |
| `heme_values` | cohort values dropped by the derived "Exclude tumors of heme origin" preset |
| `default_x`, `default_y`, `default_color`, `default_size`, `default_condition`, `default_cohorts` | opening picks; `default_cohorts` is a `\|` list in the file (the api serves it comma-separated) |
| `source_col`, `sources`, `source_labels`, `source_descriptions` | the dataset's parts (Toil: GTEX, TARGET) |
| `tte_variables` **req** (may be `[]`) | JSON array of `{"name","label","event_col","time_col","time_unit","description"}` |
| `about` **req**, `citation`, `attribution`, `about_url` | the dataset's About prose; `attribution` is the sentence a data provider requires (CPTAC: the NCI sentence) |
| `references` (optional) | JSON array, in display order, of full-title bibliography records `{"group","title","authors","journal","year","pmid","doi","url","note"}`: `title`, `authors` and `year` (integer) are required, and at least one of `pmid`, `doi`, `url`; `journal` may be `""` (a program page or data portal) (the api drops a record without a title and logs it), `pmid`, `doi`, `url`, `note` optional strings (give a pmid or doi where one exists). These are records for non-scientists: the full title of the paper, never a bare "Author 2018" tag. `group` is the heading the apps list the entry under |

`types.label` **req**: the word a plot title uses for the type (`mut`/`fmut` → "mutation", `cnv` →
"CNA", `prot` → "protein", `phospho` → "phosphosite", `rna` → "" since a bare name needs no word).

`types.fill_options` (optional column): `|`-separated subset of `na|zero|floor`, `na` first (absent column, NULL or
empty = `na` only). For a probe of the type, a sample that is tested for the type but has no stored value may be
served as missing (`na`, the default), 0 (`zero`) or the detection floor (`floor`: the probe's smallest stored value
among the tested samples of the same cohort, else over the dataset). Meaningful only for types loaded in full
(`sparse = 0`: CPTAC `prot`, `phospho`); the api ignores it for sparse types. The api serves it as `types[].fill_options`
in `/meta` and, decisively, as `fill_options` in every values answer (the union over the probes returned): **apps read
`fill_options` from the values answer only, never from the types rows**, and show the not-detected control only when
it lists more than `na`.

### Time-to-event variables

A tte variable is a pair of clinical columns: `event_col` numeric with 1 = event, 0 = censored
(NULL = unknown), `time_col` numeric, ≥ 0, in `time_unit` (TCGA's Clinical Data Resource has real
0-day times; the conformance check fails a negative time and warns on zeros; the tools drop
non-positive times as analysis policy). v1 accepts `time_unit = "days"` only.
`name` is the handle the apps offer as an X variable (`OS`); `label` the long name ("Overall
Survival").

## 2. What the api guarantees (`/v1/{ds}/meta`, additive only)

Nothing that exists today is removed or retyped (the shipped iPhone app requires `roles`,
`presets`, `clinical_columns`, `survival_endpoints` as a string array, `defaults` as a string map).

| field | content |
|---|---|
| `handles` | ordered `[{name, role}]`, role ∈ `cohort`, `subcohort`, `sample_type`; `name` is the real column (`cohort`, `subtype`, the `sampletype_col`) |
| `tte_variables` | the declared list; for a file without the key: every clinical pair `X` + `X.time` with numeric `X` (label `X`, unit days) |
| `survival_endpoints` | the names of `tte_variables` (never null; `[]` when none) |
| `type_labels` | `{type: label}` from `types.label`, falling back to the type name |
| `about` | `{description, citation, attribution, url, references}`; `references` is always an array (`[]` when the key is absent, never null) of `{group, title, authors, journal, year, pmid, doi, url, note}` in the input order, where `url` is computed: PubMed (`https://pubmed.ncbi.nlm.nih.gov/<pmid>/`) when there is a pmid, else `https://doi.org/<doi>`, else the url given in the data |
| `types[]` reference join | each row keeps its `reference` text; the api extracts the first `PMID:?\s*(\d+)` (else a DOI) and, when a `references` record has that pmid (or doi, case-insensitive), adds `reference_title`, `reference_authors`, `reference_journal`, `reference_year`, `reference_url`; with no matching record but a PMID/DOI found, only `reference_url`; otherwise nothing is added |
| `default_cohorts` | the list as a JSON array (lists are always arrays on the wire; cohort names may contain commas) |
| `defaults.cohorts` | the same list comma-joined, kept only for the shipped iPhone 1.0 |
| `roles`, `defaults`, `presets`, `sources`, `cohorts`, `types`, `datatypes`, `clinical_columns`, `clinical_descriptions`, `version`, `n_samples`, `n_probes` | as today |

The virtual `cohort` column always exists: from `cohort_col`, or a single level equal to `label`
when a file declares none. `subtype` exists when `subtype_col` is set. A dataset's own `cohort`
column is renamed `lcohort`.

### The variable list (`/v1/{ds}/probes`)

`?all=1` returns the names as today. `?all=1&typed=1` returns the same names with, per entry,
`section` (handle | probe | clinical), `type` (a `types` name, or `clinical` / `virtual`) and
`kind` (num | cat), columnar and code-indexed to stay small. Search (`?q=`) hits carry the same
three fields with `typed=1`. The apps build their menus from these fields, not from the order of
the list or from literal names.

Clients never derive what the api derives and never fall back to a rule of their own when a field is
absent: an api without the field is an old api, and the client says so.

## 3. What the tools may assume (and nothing else)

1. The variable list tells them what to offer and what each name is (section, type, kind).
2. `handles` tells them which columns are the cohort, the sub-cohort and the sample type.
3. `tte_variables` tells them which X variables are time-to-event and which columns to read.
4. `type_labels` gives the words for titles; `about` the About prose.
5. Presets and sources are `in` / `not in` rules on categorical columns; a preset whose rules
   are all `not in` is an exclusion.
6. A factor type with numeric levels (`.mut` 0/1) is plotted with its full level set, so an
   absent level still shows as an empty group.

The Shiny app is an api client only (decision 2026-10-19): the SQL reader `gitr()` and `sql_tests.R`
remain as the builders' library and as the equivalence oracle for values, not as a second app mode.

Analysis policy that is NOT dataset knowledge and stays in the tools: Kaplan–Meier excludes
normal samples; follow-up caps and group counts; z-scores and residualization require numeric
variables; the limits in `T2_LIMITS`.

## 4. Conformance

`Rscript dataset_contract_check.R [--quick] <db> <name>` (also run by `sql_tests.R`): required tables and
columns, `sample` column, the **req** keys present, non-empty and parsable, each tte pair present and numeric
with events in {0, 1, NULL} and unit `days`, `types.label` non-NULL, role columns present in
`clinpheno`, `default_cohorts` values are cohort levels, every `datatypes.type` in `types`, one
type per probe. Integrity of the data it describes: `samples`, `probes`, `clinpheno`, `types`,
`datatypes`, `allprobes` and `tested` have unique, non-NULL keys; `tested.sample` / `tested.type`
resolve and every `tested.value` is 1 (the views ignore the column); every `probes` row is in `allprobes`;
every `types` row has a `datatypes` row; a type stored in `tcgacati` is declared `factor`;
`default_x/y/color/size/condition` name a variable of the dataset (a probe, a clinical column, or the
virtual `cohort` / `lcohort` / `subtype`); `sampletype_levels` contain every value of the sample-type
column; `normal_label`, `heme_values` and `sources` are real levels of their columns.
The **deep** part (the default; `--quick` or `deep = FALSE` skips it) scans every row of `tcgai` and
`tcgacati` for NULL or orphan `samplekey` / `probekey` / `type` and (`tcgai`) duplicate
`(probekey, type, samplekey)`: one pass over the table, minutes on TCGA. Builders run it deep;
`dataset_meta.R` runs it after each write with `deep = FALSE`. Every builder runs the check last;
a file that fails it is not released.
