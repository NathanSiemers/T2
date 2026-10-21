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
| `GET /v1/datasets` | every dataset: `name`, `title`, `label`, `n_samples`, `n_probes`, `version`, `roles`, `defaults`, `sources` (the same list as `/meta`'s, so a client can build its data-source menu from this one answer), `handles`, `hidden` (boolean, always present: `true` for a dataset the apps must not list, e.g. DEMO; the dataset is still served by every endpoint) |
| `GET /v1/{ds}/meta` | one dataset in full: the above plus `presets`, `sources`, `clinical_columns`, `clinical_descriptions` (what each clinical column means and where it comes from: `column`, `description`, `source`; from `cmd/t2api/clinical_descriptions.tsv`), `survival_endpoints`, `tte_variables`, `handles`, `type_labels`, `about`, `default_cohorts` (array form of `defaults.cohorts`; cohort names can contain commas), `cohorts` (display names), `types` (data-type descriptions, with `label`), `datatypes`. The rules are in [DATASET-CONTRACT.md](DATASET-CONTRACT.md). |
| `GET /v1/{ds}/clinical` | `samples` (ids, in order) and `columns`: every clinical and virtual column. About 2.7 MB for TCGA (0.5 MB gzipped); fetch once per dataset version and keep it. |
| `GET /v1/{ds}/probes?q=cd8&limit=50` | names of selectable variables containing `q` (case-insensitive; the exact name first, then names starting with `q`, then the rest; shorter first); `total_matches` |
| `GET /v1/{ds}/probes?all=1` | every selectable name, in menu order (`subtype`, `cohort`, the probes, the sample-type column): `n`, `probes`. 1.7 MB for TCGA (0.6 MB gzipped); cacheable by version (`&v=`). For a client that fills its own menus (the R app's selectize). The body also carries parallel integer arrays, one entry per name: `section` (0 handle, 1 probe, 2 clinical), `type` (index into `types`, the list of type names used; clinical columns are type `clinical`, the virtual `cohort` / `subtype` `virtual`, a probe with no type row `unknown`), `kind` (0 numeric, 1 categorical). Search (`?q=`) adds `hits_typed`: `[{name, section, type, kind}]` with words instead of codes (`handle`/`probe`/`clinical`, `num`/`cat`); `probes` is unchanged. |
| `GET /v1/{ds}/values?probes=CD8A,TP53.mut,gender` | `columns` for those names (probes, clinical columns or `cohort` / `subtype`), `missing`: names the dataset does not have. At most 100 names per request. The body also carries the dataset `version`, `fill_options` and, with `&fill=`, `fill`, `filled`, `tested_n` (see [Not-detected values](#not-detected-values-fill)). |
| `GET /statz` | request and cache counters, and `usage` (see [Usage metrics](#usage-metrics-and-dos-visibility)); internal only, Nginx does not route it |

`roles`: which clinical columns play cohort / subtype / sample type, the sample-type values
that mean "not tumor" (`normal_label`), the cohort values of heme origin (`heme_values`).
`defaults`: the variables to show first (`x`, `y`, `color`, `size`, `condition`) and, where
the dataset has one, `cohorts`: the comma-separated cohort values the opening plot is limited
to (TCGA: nine of its 33 cohorts; a plot of all 33 is too busy to read). The app applies it
as the starting cohort filter; the user changes it like any other. The values come from
`dataset_meta` (`default_x`, …, `default_cohorts`). The file stores `default_cohorts` as a `|` list
(older files: commas); the api always serves `defaults.cohorts` comma-separated.

`handles`: ordered `[{name, role}]`, role `subcohort` (`subtype`, only if the dataset has one),
`cohort` (`cohort`, always present: a dataset that declares no cohort column gets a virtual one
whose single level is its `label`), `sample_type` (the real column, if declared). `tte_variables`:
`[{name,label,event_col,time_col,time_unit,description}]`, the declared list (entries whose columns
are missing or not numeric are dropped), else every numeric clinical `X` with a numeric `X.time`;
always an array. `survival_endpoints` is the list of their names. `type_labels`: `{type: label}`
from `types.label`, the type name where there is none. `about`: `{description, citation,
attribution, url, references}`, empty strings when absent; `references` is always an array
(`[]` when the dataset has none) of bibliography records in display order, with a computed
`url` (PubMed, else doi.org, else the given url):

    "about": {"description":"...", "references":[
      {"group":"The TCGA Pan-Cancer Atlas (2018)","title":"Cell-of-Origin Patterns Dominate the Molecular Classification of 10,000 Tumors from 33 Types of Cancer",
       "authors":"Hoadley KA, Yau C, et al.","journal":"Cell","year":2018,"pmid":"29625048",
       "doi":"10.1016/j.cell.2018.03.022","url":"https://pubmed.ncbi.nlm.nih.gov/29625048/","note":""}]}

A `types[]` row whose `reference` text names a PMID or DOI gains, when a bibliography record
matches, `reference_title`, `reference_authors`, `reference_journal`, `reference_year`,
`reference_url`; with no match only `reference_url`; the `reference` text itself is unchanged.
See [DATASET-CONTRACT.md](DATASET-CONTRACT.md).

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

Each preset also carries `n_samples`: how many samples of the whole dataset it holds.

How the app shows them: a preset with an `in` rule is a **group** (alternatives: one at
most is in use), one whose rules are all `not in` is an **exclusion** (any number); each is
offered only where it changes the samples of the chosen data source. The service lists
which ones those are, per data source (next section); the R app takes its lists from
there, the iPhone app (as of 1.0) still derives them from the same rules on the phone —
the three agree, and the app can switch to the lists whenever convenient.

### Data sources (parts of a collection)

`meta.sources` lists what the client offers in its "data source" menu for this dataset: the
whole collection first, then each **part** the dataset declares (`dataset_meta`: `source_col`
names a categorical clinical column, `sources` the levels offered, in order, `source_labels`
and `source_descriptions` one entry each; tcgatargetgtex declares `study` with `GTEX` and
`TARGET`). Each source says what makes sense inside it:

    {"label":"GTEx","description":"The GTEx study: ...",
     "rules":[{"column":"study","op":"in","values":["GTEX"]}],
     "n_samples":7862,
     "cohorts":["Adipose - Subcutaneous", ...],          // cohort values present, in `cohorts` table order
     "groups":[],                                        // presets to offer as alternatives here
     "exclusions":["Exclude cell lines","Exclude tumors of heme origin"],   // presets to offer as exclusions
     "single_level_columns":["study","subtype"]}         // categorical clinical columns with one value here

The rules behind `groups` / `exclusions` (sources.go, mirrored by `t2_presets.R` in the R
app): a preset is offered only where it keeps some, but not all, of the source's samples; a
group that comes to the same samples as an offered exclusion is left to the exclusion. Once
the user has chosen a group, an exclusion that no longer changes the samples of the source
and the group is not offered either (this last step depends on the choice, so the client
does it: `AppModel.exclusionChoices`, `t2_filter_choices()`). A `single_level_columns`
entry is not worth a filter panel or a colour inside the part; a categorical filter panel
should list only the levels present in the part.

The whole-collection entry has no rules and the dataset's label. A dataset without
`source_col` has that one entry.

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

## Not-detected values (`fill`)

Some types are measured on a subset of a sample's probes (CPTAC proteomics: a protein with no
quantifiable peptide in a plex has no stored value). For such a type a sample that was TESTED
but has no stored value is served as missing (null). `GET /v1/{ds}/values?probes=...&fill=zero|floor`
serves those cells differently; the default is `fill=na` (what every client got before).

- `fill=zero`: the cell is 0. `fill=floor`: the smallest stored value of that probe among the tested
  samples of the same cohort (the dataset's cohort column, the virtual `cohort`); a cohort with no
  stored value for the probe uses the probe's smallest stored value over the whole dataset; a probe
  with no stored value at all stays missing.
- Only the cells of samples tested for the probe's type and without a stored row change.
  Samples never tested stay missing; stored values (a stored NULL included) never change.
- It is applied per probe, and only to probes whose data type offers that fill (`types.fill_options` in
  the file, `types[].fill_options` in `/meta`, `na` only where the data say nothing). Other probes in the
  same request, and clinical columns, are served unchanged. A request whose `fill` applies to none of
  its probes is answered `400 fill not available for these variables`; an unknown value `400 fill must be
  na, zero or floor`.
- **The values answer carries the decision; clients read nothing else.** Every answer has
  `fill_options`: the union over the returned probes of what their types offer, in the order `na`,
  `zero`, `floor` (`["na"]` when nothing but missing applies). A client shows its "not detected" control
  only when the list has more than `na`, and offers exactly those options. When a fill other than `na`
  was applied, the answer also has `fill` (echo), `filled` (`{probe: cells changed}`, only probes with
  more than 0) and `tested_n` (`{probe: samples tested for its type}`, same probes): enough for a caption
  such as "set to 0 (1,357 of 1,549 samples)" without knowing what the type is (`type_labels` has the word).
- The cache and ETag key include the fill; with `?v=` the answer is immutable as before.

```
GET /v1/cptac/values?probes=CLDN6,CLDN6.prot&fill=zero
{"dataset":"cptac", ..., "columns":[ CLDN6 (rna, unchanged), CLDN6.prot (1,357 nulls now 0) ],
 "missing":[], "fill_options":["na","zero","floor"],
 "fill":"zero", "filled":{"CLDN6.prot":1357}, "tested_n":{"CLDN6.prot":1549}}
```

## Usage metrics and DoS visibility

The service counts what it serves, in memory, with no addresses, probe names, queries or
selections (`usage.go`). `GET /statz` (internal: Nginx routes only `/v1/` and `/healthz`) carries,
besides the existing counters, `usage`:

```
curl -s http://127.0.0.1:3860/statz | jq .usage
curl -s http://127.0.0.1:3860/statz | jq '.usage.minutes[-10:] | map({t, requests, max_per_client, distinct_clients, s: .by_status})'
```

- `since`: when the process started (the counters restart with it).
- `minutes`: the last 60 minutes, newest last (the service keeps 24 h in memory). Each has
  `t` (UTC minute), `requests`, `by_endpoint` (`datasets`, `meta`, `clinical`, `probes_all`,
  `probes_search`, `values`, `contact`, `healthz`, `statz`, `other`), `by_dataset` (loaded names;
  anything else is `other`), `by_status` (`2xx`, `304`, `4xx`, `429`, `503`, `5xx`), `by_client`
  (from the User-Agent prefix: `ios` = `T2 iOS`, `web` = `T2-shiny`, `other`), `latency`
  (`le10ms`, `le50ms`, `le200ms`, `le1s`, `gt1s`), `bytes` written, `busy` (requests refused
  because every slot was taken), `distinct_clients` and `max_per_client` (the two numbers
  derived from the client address; the addresses themselves live in a per-minute map that is
  dropped when the minute ends and are never logged or returned). Zero counts are omitted.
- `today` and `days`: the same counts (without the client numbers) per UTC day since start.

Reading it: normal traffic has `max_per_client` of a few dozen at most (an app session is a few
requests, a plot at most one `values` call) and almost all `2xx`/`304`. A burst shows as a
minute with a large `max_per_client` (one client) or a large `distinct_clients` with `429` /
`503` / `busy` counts rising (many clients), `latency.gt1s` growing, and `bytes` jumping.
`503` with `busy` means the in-flight limit was reached; `429` is the contact form's limiter.
Nginx's own refusals (`limit_req` 429s, blocked paths, fail2ban) never reach the service
and are not counted here: they are in the Nginx error log and the failure-only access log.

Once an hour the service logs one line of numbers, for example
`usage 2026-10-21T02:00Z requests=1234 ios=800 web=300 other=134 values=900 429=0 503=0 busy=0 p_latency: ≤10ms=80% ≤50ms=15% ≤200ms=4% ≤1s=1% >1s=0% distinct_clients_max=21 max_per_client=17`.
With `-usage-dir <dir>` (default off: the production container is read-only) the same record is
also appended as one JSON line (`t`, the counts above, `distinct_clients_max`, `max_per_client`)
to `<dir>/usage-YYYY-MM.jsonl`, created 0640; a write error is logged once per hour and
otherwise ignored.

**Draft for the public privacy page**, to be added if and when the hourly file is enabled:
"The service keeps hourly counts of requests by type (for example how many requests asked for
data values, how many were refused when the service was busy), by app (T2 iOS, the web app,
other) and by response time. It does not store IP addresses, the genes or other variables
you choose, or your selections; the counts cannot be traced to a person."

## Limits and safety

Dataset names are looked up in a fixed table, never used as a path. Probe names are only
ever bound parameters of fixed SQL. Databases are opened read-only and immutable. The
container has a read-only filesystem, no capabilities, an unprivileged user and a memory
ceiling without swap. No authentication yet (see NOTES.md, open questions).
