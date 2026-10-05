# T2 - a TCGA database and shiny tool for the 2018 release of TCGA Pan-Cancer studies

Nathan Siemers

## Getting started

00-master.R is the master R script that builds the database.  It will
wipe out the old database if all subcomponents are run.


The build scripts are now organized mostly around the idea that each
data type gets a build file.

The repetitive database connection calls in 00-master are likely not
needed, only intended to ensure that database connection doesn't drop.

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

Thanos is loaded from source: `T2_THANOS` names its loader file (default
`../Thanos/thanos.R`); version 0.3.0 or later is required. Without it the app
runs normally and the Filter tab says so. The bridge is `t2_thanos.R`.

Tests (run from this directory):

    Rscript test_t2_backend.R     # Thanos backend == gitr(), pre-filter predicate
    Rscript test_app_thanos.R     # which samples reach the plot / KM / download
    Rscript test_plot_style.R     # every Appearance / ggplot setting applies; value validation
    CHROMOTE_CHROME=/path/to/chrome NOT_CRAN=true Rscript test_app_browser.R   # real-browser UI checks
