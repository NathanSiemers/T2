# Citations round: answering App Review's 1.4.1 rejection of iOS 1.0

Written 2026-10-20. Status at the end of this file.

## What Apple said (verbatim, 2026-10-20)

> The app includes medical information but does not include citations for the medical
> information. Specifically, the app provides health or medical calculations in the app
> without citations, such as links to sources for this information. All apps with medical and
> health information should include citations to ensure users are provided accurate
> information. Next Steps: Include citations in the app of the sources of the recommendations
> or information, such as links to those sources. The citations to the sources should be easy
> for the user to find. Resources: Learn more about requirements for medical apps in
> guideline 1.4.1.

## Nathan's guidance and decisions (2026-10-20)

1. Emphasize to the user that the app gives no health advice: it is a tool *only* for
   scientists in biomedical research.
2. A list of sources for the major initiatives: the seminal TCGA papers (the 2018 Pan-Cancer
   Atlas) and the seminal papers of every integrated source (CPTAC, Toil / TCGA-TARGET-GTEx,
   Xena, GTEx, TARGET).
3. As in the Shiny app, a listing of the sources of the individual data types of each
   database, when available.
4. Clearly available and easy to find, without overwhelming the app. Address the reviewer
   without reclassifying out of the Medical category.
5. Build from **main** (the contract-round app, verified against the production service),
   version 1.0, build 2; not a hotfix from the tag.
6. Notice: a one-time sheet on first launch, a permanent statement at the top of About, and a
   "Methods and sources" link under the plot statistics.
7. The reference lists live in the **data** (`dataset_meta` key `references`), released with a
   data-stage; the service passes them on; the apps only render.
8. **References must be understandable to a non-scientist: the full title of the paper, the
   authors, the journal and year, and a link; never an abbreviated journal-style citation.**

## Design (three layers, as in DATASET-CONTRACT.md)

### Data layer

New `dataset_meta` key **`references`**: a JSON array, in display order, of

```json
{"group": "The TCGA Pan-Cancer Atlas (2018)",
 "title": "Cell-of-Origin Patterns Dominate the Molecular Classification of 10,000 Tumors from 33 Types of Cancer",
 "authors": "Hoadley KA, Yau C, Hinoue T, et al. (The Cancer Genome Atlas Research Network)",
 "journal": "Cell", "year": 2018, "pmid": "29625048", "doi": "10.1016/j.cell.2018.03.022",
 "url": "", "note": ""}
```

- `group` is the heading the apps show (free text, entries of one group are listed together in
  their order of appearance); `title`, `authors`, `journal`, `year` are required; `pmid`,
  `doi`, `url` optional (at least one; the service derives the link: PubMed, else doi.org, else
  `url`); `note` optional one sentence for a non-scientist ("the survival data of this
  database come from this paper").
- The list is the dataset's bibliography: the seminal papers of the initiative, the cohort
  papers (CPTAC's ten cohorts), the method papers behind individual data types (GISTIC2,
  RPPA, RABIT, ESTIMATE, the MC3 mutation calls, the immune landscape), the distributors
  (UCSC Xena, PDC), the funders' attribution lines stay in `attribution`.
- `types.reference` keeps its text and gains nothing in the schema: the service joins it to
  the bibliography by PMID (`PMID:?\s*(\d+)`) or DOI, so every data type shows the full
  reference. Builders write a PMID into every `types.reference` (CPTAC's lack one today).
- `citation` (one line) stays for the Publish source line and old clients.
- Source of truth per dataset: `TCGA/references.json`, `CPTAC/references.json`,
  `TCGATARGETGTEX/references.json` in the repo, written by a Sonnet agent and **verified
  against PubMed/CrossRef** (title, authors, journal, year, PMID, DOI all checked online);
  the builders (`write_tcga_meta.R`, `build_cptac.R`, `build_tcgatargetgtex.R`,
  `build_demo_dataset.R` with an empty list) read the file through
  `t2_build_lib.R::t2_references_json()`, which validates the fields.
- `dataset_meta.R set-json <db> references @file.json` (the tool currently allows
  `tte_variables` only) writes it into the dev copies of the served files; the contract check
  (`dataset_contract_check.R`) validates the key (parsable, required fields, each type's
  PMID resolvable in the list = WARN otherwise) and `T2_META_KEYS` gains `references`.
- Release: the four dev files updated (t2api-dev stopped while writing), contract check,
  `deploy.sh data-stage <date>` + `data` as in RELEASE.md.

### API layer (Go, the only interpreter)

- `/v1/{ds}/meta`: `about.references` = the validated list with a computed `url` on every
  entry (PubMed → doi.org → given url) and `about.references` empty array when absent;
  `types[]` rows gain `reference_title`, `reference_authors`, `reference_year`,
  `reference_url` when the row's PMID/DOI matches a bibliography entry (else only
  `reference_url` from a bare PMID/DOI, else nothing). All additive. `/v1/datasets` unchanged.
- `contract_test.go`: parse, link derivation, the join, absent key.
- `API.md` and `DATASET-CONTRACT.md` updated (key table, /meta table, the rule that references
  are full-title records).

### Apps

**iOS (T2Kit + T2App), version 1.0 build 2:**

- `Models.swift`: `Reference` struct; `About.references: [Reference]` (empty when absent);
  `DataTypeInfo.referenceTitle/Authors/Year/URL` optional.
- **First-launch notice** (`ResearchNoticeView`): shown once (UserDefaults flag
  `t2ResearchNoticeSeen`; the UI tests dismiss it when present and a launch argument
  `-t2ResetNotice` shows it again for the screenshot): "T2 Cancer Genomics is a research
  tool for scientists in biomedical research. It shows public research data and statistics
  computed from them. It gives no medical advice and must not be used for diagnosis or
  treatment decisions. The sources of every data set and method are under About › Sources
  and citations." One button, "Continue".
- **About**: a first section "Research use only" with the same statement (short form) and a
  `NavigationLink` "Sources and citations" (accessibility id `sources`) to **SourcesView**;
  the "Data types" section and the T2 citation move into SourcesView so About gets shorter,
  not longer. SourcesView sections: (1) the dataset's bibliography by `group`, each entry
  title (bold), authors, journal year, a tappable link; (2) "Data types in <dataset>": type,
  label/description, the full reference (title + link) and the data link (host as label) when
  present; (3) "Methods": the statistics the app computes with their original papers
  (Kaplan–Meier 1958, Mantel 1966 log-rank, Cox 1972, Pearson 1895, Spearman 1904,
  Kruskal–Wallis 1952; a constant list in T2Kit, `MethodReferences.swift`, with links);
  (4) "T2": the T2 citation and the website.
- **Plot**: under the statistics block a small link "Methods and sources" (id
  `methods-sources`) that opens SourcesView scrolled to Methods.
- UI tests: test05 covers the notice and About › Sources (screenshots `04e-sources`,
  `04f-sources-methods`); test01 dismisses the notice if shown. Unit test: decoding a
  `references` fixture and the join fields.
- Listing (`docs/APPSTORE.md`): Description gains "T2 Cancer Genomics is intended for
  scientists in biomedical research…"; Review notes say where the citations are
  (first launch, About › Sources and citations, the plot's Methods and sources link) and
  that the app gives no medical advice; a Resolution Center reply is drafted in
  `docs/APPSTORE.md` ("Reply to the 1.4.1 rejection").

**Shiny app (`app.R`):** the research-use statement at the top of About and in the page
footer; `about.references` rendered by group with links; the data-type table's Reference
column shows the full title linked (falls back to the text); a Methods list identical to the
app's (the R constant in `t2_util.R`).

## Steps and owners

| step | owner | depends on |
|---|---|---|
| A. `references.json` for TCGA, CPTAC, Toil, verified online; methods list | Sonnet (web) | — |
| B. Go: `references`, the join, tests, docs | Sonnet | schema (this doc) |
| C. R data layer: `t2_references_json`, builders, `dataset_meta.R`, contract check | Sonnet | A |
| D. iOS: notice, About, SourcesView, plot link, tests, build 2, listing texts | Sonnet | schema |
| E. Shiny: About, footer, references, methods | Sonnet | schema |
| F. Dev data update, dev-up, `ops/test.sh all`, dev website check | lead + Sonnet | B C D E |
| G. Release: `deploy.sh service`, `data-stage`, `data`, `code`, `check` | lead | F |
| H. Mac: simulator suite against the live service; TestFlight upload (Nathan's keychain) | lead + Nathan | G |
| I. Resubmit with `asc.py`, Resolution Center reply, tag `v1.0-build2-submitted` | Nathan + lead | H |

## Status

- 2026-10-20: plan written; agents A, B, D, E started.
