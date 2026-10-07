# T2 - a TCGA database and shiny tool for the 2018 release of TCGA Pan-Cancer studies

Nathan Siemers

## Getting started

00-master.R is the master R script that builds the database.  It will
wipe out the old database if all subcomponents are run.


The build scripts are now organized mostly around the idea that each
data type gets a build file.

The repetitive database connection calls in 00-master are likely not
needed, only intended to ensure that database connection doesn't drop.

### Rebuilding the databases (as last done 2026-10-07)

Run each builder from a frozen clone of the repository, so that edits to the working tree
during a build cannot change it (the pipeline `source()`s each step when it reaches it):

    git clone /scratch/nathan/R/T2 /scratch/nathan/R/T2-rebuild-<date>
    cd T2-rebuild-<date>
    rm -rf TCGA/Data && ln -s ../../T2/TCGA/Data TCGA/Data        # inputs are gitignored, 21 GB
    ln -s ../../T2/TCGA/microbe.csv TCGA/microbe.csv
    rm -rf TCGATARGETGTEX/Data && ln -s ../../T2/TCGATARGETGTEX/Data TCGATARGETGTEX/Data

Then, in two containers at once (the builds are single-threaded and independent; image
`rstudio:2026.03`, user 501:1000, no swap, `--oom-score-adj 1000` so a build dies before
the machine does; the caps are far above the peaks seen, 51 GB for TCGA and 48 GB for Toil):

    cd TCGA && Rscript 00-master.R > ../rebuild_tcga.log 2>&1        # ~1.5 h, 330 GB cap
    ./run_ttg_demo.sh > rebuild_ttg.log 2>&1                          # ~30 min, 160 GB cap

`00-master.R` logs `==> STEP <script> started/done` per step (`grep '==> STEP' rebuild_tcga.log`),
builds `tcga.db.building`, runs `sql_tests.R` and renames to `tcga.db` only if the suite
passes (`PROMOTED` in the log). Every input, including the GDC viral-read table, is read from
`TCGA/Data`; nothing is downloaded unless `download = TRUE`. Step times on 2026-10-07: rna 10.7
min, cnv 25.2, cnc 12.5, mut 5.3, final indexing 14.7, the rest under a minute each.

A finished database is one file in rollback-journal mode (bytes 18-19 `0101`), with the
tables `sparse` (how each type was loaded), `default_filters` (presets), `types`, `env_env`.

### Pulling all the data of one type

Do not write `SELECT ... FROM tcgai WHERE type = 'rna'`: there is no type-only index (it
cost 8.6 GB and nothing used it), so that is a full scan of the 577 M-row table (3.5 min).
Use the view `bytype` (builds from 2026-10-07 on), which starts from `probe_types` and reads
each probe's rows as one contiguous range of the covering index:

    SELECT probe, sample, value FROM bytype WHERE type = 'rppa';   -- 2 M rows, 2 s
    SELECT probe, sample, value FROM bytype WHERE type = 'rna';    -- 195 M rows, ~150 s
    SELECT probe, count(*) FROM bytype WHERE type = 'sig' GROUP BY probe;
    SELECT sample, value FROM bytype WHERE probe = 'CD8A';         -- 0.01 s

(`probekey` and `samplekey` are in the view too.) Categorical data by type: the `tcgacats`
view, `WHERE type = 'fmut'`, which has its own type-leading index. `Util/index_bench.py`
measures all of this on a bench copy; its 2026-10-07 results are summarised in
`T2Mobile/NOTES.md`.
Verify before serving: the SQL suite counts, `T2Mobile/service/test.sh equiv` against a private
`t2api` on the new files, and a diff against the served files; `Util/index_bench.py` measures
the indexes. Serve from a NEW directory and change the compose volumes; never overwrite a
served file.

## The Shiny app: tabs and the Filter tab

`app.R` is organised as five tabs: **Select** (data set, variables, cohort),
**Plot** (every Plot button lands here), **Filter**, **Appearance** (plot
cosmetics and survival options) and **About** (data types).

The **Filter** tab embeds [Thanos](https://github.com/NathanSiemers/Thanos),
an interactive cross-filter: one histogram plus slider/checkboxes per variable.
Variables chosen on the Select tab appear there automatically and any other
variable can be added. Cohort and the two Exclude checkboxes on the Select tab
decide which samples the Filter tab shows; the Filter tab's survivors are what
gets plotted (and downloaded) the next time Plot is pressed. Each data set has
its own set of filters.

The **Appearance** tab's settings are real ggplot values (font sizes in
points, point size, alpha; 0 switches an item off), each labelled with what
ggplot calls it, plus the plot's height on the page. Under "More ggplot
settings" a search box offers every other setting: all theme elements of the
installed ggplot2 and the drawing settings of the layers T2 uses (about 440 in
all). The registry, its menus and the server-side validation of every value
live in `plot_style.R`; nothing a browser sends is parsed or evaluated.

The **Publish** tab makes a figure of a chosen physical size and resolution
(PNG, TIFF or PDF) from the current selections. The preview and the download
are drawn by the same function at the same size in inches, so the preview is
the figure. It keeps its own style values, started from presets with
print-scale defaults (text 5-8 pt, thin rules, compact legend); see
`figure_export.R`. `fonts/` holds open fonts metric-compatible with Arial
(Liberation Sans) and Cambria (Caladea); `plot_style.R` points `XDG_DATA_HOME`
at the app directory so both the PNG/TIFF and the PDF device find them (set
`T2_NO_BUNDLED_FONTS` to disable that).

Thanos is loaded from source: `T2_THANOS` names its loader file (default
`../Thanos/thanos.R`); version 0.3.0 or later is required. Without it the app
runs normally and the Filter tab says so. The bridge is `t2_thanos.R`.

Tests (run from this directory):

    Rscript test_t2_backend.R     # Thanos backend == gitr(), pre-filter predicate
    Rscript test_app_thanos.R     # which samples reach the plot / KM / download
    Rscript test_plot_style.R     # every Appearance / ggplot setting applies; value validation
    Rscript test_figure_export.R  # figure files: exact size/dpi, preview == download, limits, fonts
    CHROMOTE_CHROME=/path/to/chrome NOT_CRAN=true Rscript test_app_browser.R   # real-browser UI checks
