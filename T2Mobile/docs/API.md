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
| `GET /v1/{ds}/meta` | one dataset in full: the above plus `presets`, `clinical_columns`, `clinical_descriptions` (what each clinical column means and where it comes from: `column`, `description`, `source`; from `cmd/t2api/clinical_descriptions.tsv`), `survival_endpoints`, `cohorts` (display names), `types` (data-type descriptions), `datatypes` |
| `GET /v1/{ds}/clinical` | `samples` (ids, in order) and `columns`: every clinical and virtual column. About 2.7 MB for TCGA (0.5 MB gzipped); fetch once per dataset version and keep it. |
| `GET /v1/{ds}/probes?q=cd8&limit=50` | names of selectable variables containing `q` (case-insensitive; names starting with `q` first); `total_matches` |
| `GET /v1/{ds}/values?probes=CD8A,TP53.mut,gender` | `columns` for those names (probes, clinical columns or `cohort` / `subtype`), `missing`: names the dataset does not have. At most 100 names per request. The body also carries the dataset `version`. |
| `GET /statz` | request and cache counters |

`roles`: which clinical columns play cohort / subtype / sample type, the sample-type values
that mean "not tumor" (`normal_label`), the cohort values of heme origin (`heme_values`).
`defaults`: the variables to show first (`x`, `y`, `color`, `size`, `condition`) and, where
the dataset has one, `cohorts`: the comma-separated cohort values the opening plot is limited
to (TCGA: nine of its 33 cohorts; a plot of all 33 is too busy to read). The app applies it
as the starting cohort filter; the user changes it like any other. For a dataset other than
TCGA the values come from `dataset_meta` (`default_x`, …, `default_cohorts`).

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
from its roles (`source: "derived"`): exclude non-tumor, exclude heme. A database whose table
drops no cohort also gets the derived "Exclude tumors of heme origin" (the role map's heme
values that are levels of `cohort`), so every collection with blood or lymphoid cohorts
offers it.

How the app shows them: a preset with an `in` rule is a **group** (alternatives: one at
most is in use), one whose rules are all `not in` is an **exclusion** (any number); each is
offered only where it changes the samples of the chosen data source.

## Caching

Data change only when a database file is replaced. Every dataset has a `version` (changes
with the file; listed by `/v1/datasets`, in `/meta` and in every `/values` body).

- **Pass the version you know: `...&v=<version>`.** The URL then names one database build:
  the response has `Cache-Control: public, max-age=31536000, immutable` and can be kept for
  good by the app, Nginx or a CDN. If that version is no longer the one served, the answer
  is **`409`** (`{"error":"dataset version changed: ..."}`): reload `/v1/datasets`, drop
  what was cached for the old version, and ask again with the new one.
- Without `v` the response is `Cache-Control: no-cache`: it must be revalidated by `ETag`
  before reuse (`If-None-Match` is answered `304`). `/v1/datasets` and `/meta` are how a
  client learns the current version, so they are always asked without `v` and never taken
  from a cache unchecked. The ETag is a fixed-length hash; it changes with the dataset
  version. `gzip` is used when the
client accepts it (a 12,804-value numeric column: 64 KB plain, 24 KB gzipped).

## Errors

`400` bad request (no probes, more than 100, a name over 200 characters, or **none of the
first 10 names is a variable of the dataset**), `404` unknown dataset or path, `405` not
GET, `409` the `v` given is not the version served, `500` internal error, `503` the dataset
file is being replaced (the service restarts by itself; retry after a few seconds). Body:
`{"error":"..."}`. A single unknown *probe* is not an error: it is listed in `missing`.

Names are checked against the dataset's variable list (`allprobes`, plus the clinical
columns) in memory before anything else: a made-up name costs no query and is never
cached.

## Contact form

`POST /v1/contact` with JSON `{"name","affiliation","email","message","started","app"}`
(`started` = seconds since the form appeared; `website` is a honeypot that must stay
empty). The server keeps every message in an append-only file (`T2_CONTACT_DIR`), the only
thing it writes; delivery to the owner is a cron job on the host that mails new lines to the
local user and keeps a readable `inbox.md` beside the file (`~/bin/t2-contact-mail.sh`). No
address or credential is in the app or the service. Limits: 16 KB body, 200-character
name and affiliation, 4,000-character message, valid UTF-8, no control characters, 5
messages per client address and 200 per day, plus Nginx's 1 request per minute per address.
Answers: `200 {"ok":true}` (also for a dropped bot), `400`, `415`, `429`, `503` (store full
or unwritable), `404` when the form is not enabled (`T2_CONTACT_DIR` unset).

## Replacing a database (operators)

The service loads sample order, key maps and clinical columns from a file once, and every
cached column belongs to that file. **Never copy over a file that is being served.** Put
the new files in a new directory (or under a new name), point the service's volume at it,
and restart the service. As a safety net the service checks on every request that the file
it loaded is still the same file (size, modification time, inode); if not, it answers `503`
and exits so that Docker starts it again with everything loaded afresh.

## Limits and safety

Dataset names are looked up in a fixed table, never used as a path. Probe names are only
ever bound parameters of fixed SQL. Databases are opened read-only and immutable. The
container has a read-only filesystem, no capabilities, an unprivileged user and a memory
ceiling without swap. No authentication yet (see NOTES.md, open questions).
