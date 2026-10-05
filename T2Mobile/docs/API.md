# t2api — the contract

Read-only HTTP + JSON. Everything is a GET. Base path `/v1`. Implemented in `service/`
(Go); this document is what a client (the iOS app) or a reimplementation codes against.

## Semantics: what "the values of a probe" means

Identical to `gitr()` in the T2 R code, and checked against it value by value by
`service/test_equivalence.R` (all clinical columns and ~200 probes of every data type, on
all three datasets). The data are exact; only the format differs.

- **Samples.** A dataset's samples are the rows of its `clinpheno` table, in that order.
  Every column the API returns has one entry per sample, in that order. Get the order (and
  the sample ids) once from `/clinical`.
- **Numeric probes** (expression, copy number, scores ...) belong to a data type. For a
  sample that was *tested* for that type: the stored value; `null` if the stored value is
  NULL; and **0 if nothing is stored** (sparse zero). For a sample not tested: `null`.
- **Categorical probes**: the stored text, `null` where nothing is stored.
- **Numeric probes declared "factor"** in the `datatypes` table (mutations `.mut`, `.fmut`,
  copy-number calls `.cnc` ...) are returned as categorical, their numbers as level names
  (`"0"`, `"1"`), as `gitr()` returns factors.
- **Clinical columns** are `clinpheno`'s: text is categorical, numbers numeric. The virtual
  columns `cohort` and `subtype` are copies of the dataset's role columns (`lcohort` is the
  table's own `cohort`, when it has one). The sample-type column uses the dataset's declared
  level order; a value outside it is `null`.
- **One deviation from the stored bytes:** JSON must be valid UTF-8, so a byte that is not
  becomes a space. This affects one label today ("Sympathetic Nervous System" in
  tcgatargetgtex has a stray Mac non-breaking space, 0xCA). Fix it in the database build.

## Column objects

    {"name":"CD8A","kind":"num","type":"rna","values":[8.01,6.87,null,...]}
    {"name":"TP53.mut","kind":"cat","type":"mut","levels":["0","1"],"codes":[-1,0,1,...]}

`values`: numbers, exact (shortest text that round-trips the stored 64-bit float), `null` =
missing. `codes`: index into `levels` from 0, `-1` = missing. `type`: the data type
(`rna`, `mut`, ...), or `clinical` / `virtual`.

## Endpoints

| Request | Returns |
|---|---|
| `GET /healthz` | `ok` |
| `GET /v1/datasets` | every dataset: `name`, `title`, `label`, `n_samples`, `n_probes`, `version`, `roles`, `defaults` |
| `GET /v1/{ds}/meta` | one dataset in full: the above plus `presets`, `clinical_columns`, `survival_endpoints`, `cohorts` (display names), `types` (data-type descriptions), `datatypes` |
| `GET /v1/{ds}/clinical` | `samples` (ids, in order) and `columns`: every clinical and virtual column. About 2.7 MB for TCGA (0.5 MB gzipped); fetch once per dataset version and keep it. |
| `GET /v1/{ds}/probes?q=cd8&limit=50` | names of selectable variables containing `q` (case-insensitive; names starting with `q` first); `total_matches` |
| `GET /v1/{ds}/values?probes=CD8A,TP53.mut,gender` | `columns` for those names (probes, clinical columns or `cohort` / `subtype`), `missing`: names the dataset does not have. At most 50 names per request. |
| `GET /statz` | request and cache counters |

`roles`: which clinical columns play cohort / subtype / sample type, the sample-type values
that mean "not tumor" (`normal_label`), the cohort values of heme origin (`heme_values`).
`defaults`: the variables to show first (`x`, `y`, `color`, `size`, `condition`).

### Presets (default filters)

`meta.presets` is the list of ready-made sample subsets the app offers as one-tap choices:

    {"label":"GTEx normal tissues","description":"Healthy donor tissue from GTEx (no cell lines)",
     "default":false,"source":"database",
     "rules":[{"column":"study","op":"in","values":["GTEX"]},
              {"column":"sample_type","op":"in","values":["Normal Tissue"]}]}

A sample is in the preset if **every** rule holds; a rule holds if the sample's value of
`column` is (`in`) or is not (`not in`) one of `values`. `default: true` = switched on when
the dataset is first opened. They come from the dataset's own `default_filters` table
(`source: "database"`; defined in `default_filters.R` in the T2 repository and written by
every dataset build). A database built before that table existed gets two presets derived
from its roles (`source: "derived"`): exclude non-tumor, exclude heme.

## Caching

Data change only when a database file is replaced. Every dataset has a `version` (changes
with the file) and every data response carries `ETag` and `Cache-Control: public,
max-age=86400`; `If-None-Match` is answered `304`. So the app can keep what it has fetched,
and Nginx or a CDN can serve repeats without reaching the service. `gzip` is used when the
client accepts it (a 12,804-value numeric column: 64 KB plain, 24 KB gzipped).

## Errors

`400` bad request (no probes, more than 50, a name over 200 characters), `404` unknown
dataset or path, `405` not GET, `500` query failed. Body: `{"error":"..."}`. An unknown
*probe* is not an error: it is listed in `missing`.

## Limits and safety

Dataset names are looked up in a fixed table, never used as a path. Probe names are only
ever bound parameters of fixed SQL. Databases are opened read-only and immutable. The
container has a read-only filesystem, no capabilities, an unprivileged user and a memory
ceiling without swap. No authentication yet (see NOTES.md, open questions).
