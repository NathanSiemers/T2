## app.R - combined Shiny application
## History from server.R: 5101adc 7e740ec 89e7671 a1e5ea7 4b0a2cb b67ed0d
##   2b0ecd2 3cacb04 f5af0e7 f87110f 245f470 0eb4ca9
## History from ui.R: 5101adc 7552c47 7e740ec 9040bd9 ed9ae38 a1e5ea7
##   4b0a2cb 2809b6f b67ed0d 2b0ecd2 3cacb04 f5af0e7 245f470 0eb4ca9
##   e3ae465 a760cf2

## check all required packages before starting
required_pkgs = c("shiny", "shinythemes", "shinycssloaders", "rmarkdown",
                  "DBI", "RSQLite", "curl", "jsonlite", "sqldf", "ggplot2", "ggthemes",
                  "viridis", "tidyverse", "dplyr")
missing = required_pkgs[!sapply(required_pkgs, requireNamespace, quietly = TRUE)]
if (length(missing) > 0) {
  stop("Missing R packages: ", paste(missing, collapse = ", "),
       "\nRun: install.packages(c('", paste(missing, collapse = "', '"), "'))")
}

library(shiny)
library(shinythemes)
library(shinycssloaders)
library(rmarkdown)

source('global.R')
source("lib.R")                # stops with one message when T2_API_URL is not set
source("input_validation.R")
source("t2_thanos.R")     # Thanos loader + backend_t2 (the Filter tab)

## The name this copy of the app is served under. The same code runs as "T2"
## and as "T2T" (the site that carries the Thanos filter tab); the name is the
## app directory's, because shiny-server starts R without the container's
## environment variables. Anything that is not a T2-style name falls back to T2.
T2_SITE = local({
    d = basename(getwd())
    if (grepl("^T2[A-Za-z0-9]{0,8}$", d)) d else "T2"
})
## page heading for a dataset: the canonical "T2: ..." title carries the site name
site_title = function(title) sub("^T2:", paste0(T2_SITE, ":"), title)

## convenience functions
nbsp = function(n) {
    paste( rep( '&nbsp;', n ), collapse = ' ')
}
inline = function (x) {  shiny::tags$div(style="display:inline-block;", x)  }

################################################################
## UI
################################################################

## an Appearance label: the made-up name, with what ggplot calls it underneath
gg_label = function(label, gg = NULL) {
    if (is.null(gg)) label else tagList(label, tags$div(class = "gg-name", gg))
}
## one of the fixed style menus (see T2_STYLE in plot_style.R). `prefix` and
## `default` give the Publish tab its own copy with print-scale defaults.
style_select = function(id, prefix = "", default = NULL, note = "") {
    st = T2_STYLE[[id]]
    inline(selectInput(paste0(prefix, id), gg_label(paste0(st$label, note), st$gg), choices = st$choices,
                       selected = if (is.null(default)) st$default else default))
}
## the search box over every other ggplot setting
tweak_picker = function(prefix = "") {
    selectizeInput(paste0(prefix, 'tweak_pick'), 'Add settings', choices = t2_tweak_choices(),
                   multiple = TRUE, width = '100%',
                   options = list(placeholder = 'type to search, e.g.  angle,  legend,  grid,  shape,  title text ...',
                                  plugins = list('remove_button'), maxOptions = 2000))
}
## one widget per picked setting. `defaults` (id -> value) overrides the
## registry default shown (a figure preset has its own); an existing widget
## keeps its current value.
tweak_widgets = function(input, prefix = "", defaults = list()) {
    picked = .t2_pick(input[[paste0(prefix, 'tweak_pick')]], names(T2_TWEAKS), 60)
    if (is.null(picked)) return(NULL)
    lapply(picked, function(id) {
        tw = T2_TWEAKS[[id]]
        iid = t2_tweak_input_id(id, prefix)
        cur = isolate(input[[iid]])
        lab = gg_label(tw$label, tw$gg)
        if (tw$kind == "text") {
            return(inline(textInput(iid, lab, value = if (is.null(cur)) "" else cur,
                                    placeholder = "automatic")))
        }
        def = if (!is.null(defaults[[id]])) defaults[[id]] else tw$default
        sel = if (!is.null(cur)) as.character(cur)
              else if (!is.null(def)) as.character(def) else ""
        menu = t2_tweak_menu(tw, def)
        if (tw$kind == "enum") {
            return(inline(selectInput(iid, lab, choices = menu, selected = sel)))
        }
        ## numbers and colours: a menu, plus "type your own"
        if (nzchar(sel) && !(sel %in% menu)) menu = c(sel, menu)
        inline(selectizeInput(iid, lab, choices = c("automatic" = "", menu), selected = sel,
                              options = list(create = TRUE, persist = FALSE,
                                             placeholder = "automatic")))
    })
}

## ONE appearance panel for the Plot and Publish tabs (ANALYSIS-SPEC section 10): the same ids as ever.
## It sits below the tab bar content; a figure preset writes these widgets when chosen.
appearance_panel_ui = function() {
    div(class = "t2-appearance",
        tags$hr(),
        h4('Plot appearance'),
        tags$p(class = "text-muted", "(shared between the Plot and Publish tabs; a figure preset writes these)"),
        helpText("Sizes are real ggplot values (font sizes in points). A size of 0 removes that item. ",
                 "The green line under each name is what ggplot calls the setting."),
        style_select('point_size'),
        style_select('alpha'),
        style_select('title_size'),
        style_select('subtitle_size'),
        tags$br(),
        style_select('axis_title_size'),
        style_select('axis_text_size'),
        style_select('strip_size'),
        style_select('legend_size'),
        tags$br(),
        inline( selectInput('scales', gg_label('Multi-graph scales', 'facet_wrap(scales = )'),
                            choices = T2_CONTROLS$scales$choices, selected = T2_CONTROLS$scales$default) ),
        style_select('ncols'),
        inline( selectInput('smooth', gg_label('Fit line', 'geom_smooth(method = "lm")'),
                            choices = T2_CONTROLS$smooth$choices, selected = T2_CONTROLS$smooth$default) ),
        style_select('plot_height', note = " (screen only)"),
        tags$br(),
        inline(checkboxInput("show_legend", gg_label("Show legend", "legend.position"), value = TRUE)),
        inline(checkboxInput("allComplete", "Show only results with complete information", value = TRUE)),
        tags$br(),
        ## survival (Kaplan-Meier) options - used when X is a time-to-event variable of the data set
        inline( selectizeInput('km_groups', 'Survival: # groups (Y)', choices = T2_CONTROLS$km_groups$choices,
                               selected = T2_CONTROLS$km_groups$default) ),
        inline( numericInput('surv_max_days', 'Survival: max follow-up (days)', value = T2_CONTROLS$surv_max_days$default,
                             min = min(T2_CONTROLS$surv_max_days$choices), step = 30) ),
        h4('More ggplot settings'),
        helpText("Search every other ggplot setting: all theme elements (axis text angle, legend position, ",
                 "grid lines, backgrounds, spacing ...) and the drawing settings of points, boxplots and the fit line. ",
                 "Each one you pick appears below with its current default; choose from the menu, or type your own number or #hex colour."),
        tweak_picker(),
        div(class = "t2-tweaks", uiOutput('tweak_inputs')),
        actionButton("plot_btn2", "Plot")
    )
}

## the Publish tab: a figure of a given physical size and resolution
publish_tab_ui = function() {
    pr = T2_FIG_PRESETS[[T2_FIG_DEFAULT_PRESET]]
    tagList(
        tags$br(),
        helpText("A figure for a paper or a slide: choose its real size and resolution, adjust until the ",
                 "preview reads well, then press ", tags$b("Plot"), " to download the file. The preview is the figure itself, ",
                 "drawn at the size you asked for. The appearance panel below is shared with the Plot tab; choosing a preset writes it."),
        fluidRow(
            column(4,
                selectInput('pub_preset', 'Start from', width = '100%',
                            choices = stats::setNames(names(T2_FIG_PRESETS),
                                                      vapply(T2_FIG_PRESETS, `[[`, "", "label")),
                            selected = T2_FIG_DEFAULT_PRESET),
                div(class = "t2-pub-size",
                    inline(numericInput('pub_width', 'Width', value = pr$width, min = 0.1, step = 0.1, width = '90px')),
                    inline(numericInput('pub_height', 'Height', value = pr$height, min = 0.1, step = 0.1, width = '90px')),
                    inline(selectInput('pub_units', 'Units', choices = T2_FIG_UNITS, selected = pr$units, width = '80px')),
                    inline(selectInput('pub_dpi', 'Resolution (dpi)', choices = T2_FIG_DPI, selected = pr$dpi, width = '130px'))),
                inline(selectInput('pub_format', 'File format', choices = T2_FIG_FORMATS, selected = "png", width = '200px')),
                inline(selectInput('pub_family', gg_label('Font', 'theme(text = element_text(family = ))'),
                                   choices = T2_FIG_FAMILIES, width = '300px')),
                ## a switch per text element of the figure (all on by default)
                div(class = "t2-pub-text", tags$b("Text on the figure: "),
                    inline(checkboxInput("pub_show_title", "Title", value = TRUE)),
                    inline(checkboxInput("pub_show_subtitle", "Subtitle", value = TRUE)),
                    inline(checkboxInput("pub_show_caption", "Caption (filters)", value = TRUE)),
                    inline(checkboxInput("pub_source", "Source line", value = TRUE)),
                    inline(checkboxInput("pub_show_axis_titles", "Axis titles", value = TRUE))),
                div(class = "t2-cite",
                    conditionalPanel("!input.pub_source",
                        tags$b("You have removed the source line."), " That is fine, but please cite T2 in any ",
                        "publication or presentation that uses this figure:"),
                    conditionalPanel("input.pub_source", "The source line, and the citation for T2:"),
                    tags$code(id = "t2_citation", T2_CITATION),
                    tags$a(href = "#", class = "t2-copy",
                           onclick = "navigator.clipboard.writeText(document.getElementById('t2_citation').innerText); this.innerText = 'copied'; return false;",
                           "copy"))
            ),
            column(8,
                inline(downloadButton('pub_download', 'Plot: download figure')),
                inline(HTML(nbsp(3))),
                inline(radioButtons('pub_zoom', NULL, inline = TRUE,
                                    choices = c("Fit to window" = "fit", "Print size (approx.)" = "print",
                                                "Pixel for pixel" = "pixels"), selected = "fit")),
                div(class = "t2-filter-status", textOutput('pub_readout')),
                div(class = "t2-pub-preview",
                    withSpinner(imageOutput('pub_preview', height = 'auto'), color = viridis::plasma(1),
                                proxy.height = "300px"))
            )
        )
    )
}

## data sources known at startup (every dataset and its parts): the Filter tab
## holds one (hidden) Thanos panel set per source, shown for whichever is selected
T2_SOURCES = list_sources()
## ...and every served source, hidden ones included: a hidden dataset (DEMO) is not offered in the
## menu but still opens by name (the test suites, a deliberate link)
T2_SOURCES_SERVED = list_sources(include_hidden = TRUE)

## the host of a link, for its label ("https://xenabrowser.net/datapages/" -> "xenabrowser.net")
t2_url_host = function(url) {
    h = sub("^[a-zA-Z][a-zA-Z0-9+.-]*://", "", url)
    h = sub("[/?#].*$", "", h)
    sub("^www\\.", "", h)
}

## a link target that is safe to put in an href: http(s) only, else ""
t2_safe_href = function(url) {
    url = as.character(url)[1]
    if (is.na(url) || !grepl("^https?://", url)) "" else url
}

## The About note on time-to-event analysis, from the bundle's tte list
## (/meta tte_variables): which variables switch X to a Kaplan-Meier plot, what
## each one is, and the data set's citation. NULL when the data set has none.
t2_survival_note = function(b) {
    tte = b$tte
    if (!length(tte)) return(NULL)
    listed = lapply(seq_along(tte), function(i) {
        t = tte[[i]]
        tagList(if (i > 1) (if (i < length(tte)) ", " else " or "), tags$code(t$name),
                if (nzchar(t$label) && !identical(t$label, t$name)) paste0(" (", t$label, ")"))
    })
    pairs = lapply(seq_along(tte), function(i) {
        t = tte[[i]]
        tagList(if (i > 1) ", ", tags$code(t$time_col))
    })
    descs = Filter(nzchar, vapply(tte, function(t) t$description, ""))
    tags$div(
        style = "margin-top: 16px; padding: 12px 16px; border-left: 4px solid #3B7DB4; background: #f6f8fa; font-size: 90%;",
        tags$b("Time-to-event analysis (Kaplan\u2013Meier + Cox)"),
        tags$p(style = "margin: 6px 0 4px",
            "Select ", listed, " as the ", tags$b("Gene (X)"),
            " variable to switch from a scatter plot to a ", tags$b("Kaplan\u2013Meier"),
            " survival plot: the ", tags$b("Gene (Y)"),
            " marker is split into groups (Low / Mid / High for three), with shaded confidence bands, ",
            "median survival per group, and the ", tags$b("log-rank"), " p-value plus a ",
            tags$b("Cox proportional-hazards"), " hazard ratio (per 1 SD, with 95% CI) embedded in the plot. ",
            "Faceting via ", tags$b("\u201cGraph for each\u201d"), " produces a grid of per-group KM plots."),
        tags$p(style = "margin: 2px 0 0; color: #666",
            "Each one pairs an event indicator (1 = event, 0 = censored) with its time (",
            tags$code(tte[[1]]$time_unit), "): ", pairs, ". ",
            if (length(descs)) paste(unique(descs), collapse = " "),
            if (nzchar(b$about$citation)) paste0(" Source: ", b$about$citation)))
}

## the Filter tab: Thanos cross-filtering of the samples that get plotted
filter_tab_ui = function() {
    if (!HAVE_THANOS) {
        return(tagList(tags$br(),
            helpText("Interactive filtering is not available in this installation. ",
                     T2_THANOS_NOTE)))
    }
    tagList(
        tags$br(),
        inline(actionButton("plot_btn3", "Plot")),
        inline(HTML(nbsp(3))),
        inline(tags$b(textOutput("filter_count", inline = TRUE))),
        helpText("Fine-tune which samples are plotted. Every variable chosen on the ",
                 tags$b("Select"), " tab appears here automatically; add any other variable with ",
                 tags$b("Filter columns"), ". Each histogram shows the samples passing all the ",
                 tags$i("other"), " filters, with this variable's own selection highlighted. ",
                 "The data set, cohort and sample choices on the Select tab decide which samples are shown here at all. ",
                 "Filters take effect on the plot when you press ", tags$b("Plot"), "."),
        lapply(unname(T2_SOURCES_SERVED), function(key) {
            conditionalPanel(
                condition = sprintf("input.dataset == %s",
                                    jsonlite::toJSON(key, auto_unbox = TRUE)),
                div(class = "t2-thanos", thanosUI(t2_thanos_id(key))))
        })
    )
}

ui = fluidPage(
    title = T2_SITE,
    theme = shinytheme('flatly'),
    tags$head(tags$style(HTML("
        h6 {font-size: 75%; }
        /* Filter tab: lay the Thanos panels out as a responsive grid */
        .t2-thanos div[id$='-panels'] { display: grid; gap: 14px 28px;
            grid-template-columns: repeat(auto-fill, minmax(400px, 1fr)); }
        .t2-thanos .thanos-panel { border: 1px solid #dce4ec; border-radius: 4px;
            padding: 10px 12px 4px 12px; background: #fff; }
        .t2-filter-status { font-size: 90%; color: #555; margin: 8px 0; }
        .t2-var-help { font-size: 85%; color: #555; margin: 4px 0 8px 0; max-width: 1100px; }
        /* every tab drawn as a tab, the selected one raised and accented */
        #tabs.nav-tabs { border-bottom: 1px solid #b4bcc2; margin-top: 6px; }
        #tabs.nav-tabs > li > a { border: 1px solid #dce4ec; border-bottom-color: #b4bcc2;
            background: #eef1f4; color: #2c3e50; margin-right: 4px; padding: 8px 18px;
            border-radius: 5px 5px 0 0; }
        #tabs.nav-tabs > li > a:hover { background: #e1e6ea; }
        #tabs.nav-tabs > li.active > a, #tabs.nav-tabs > li.active > a:hover,
        #tabs.nav-tabs > li.active > a:focus { background: #fff; color: #2c3e50; font-weight: 600;
            border: 1px solid #b4bcc2; border-top: 3px solid #18bc9c; border-bottom-color: #fff; }
        /* the ggplot name under each made-up Appearance label */
        .gg-name { font-style: italic; font-weight: normal; font-size: 80%; color: #2e8b57;
            line-height: 1.2; margin-top: 1px; }
        .t2-tweaks .shiny-input-container { vertical-align: top; }
        /* Publish tab */
        .t2-pub-style .shiny-input-container, .t2-pub-style .selectize-control { width: 175px; }
        .t2-pub-preview { border: 1px solid #dce4ec; background: #f4f6f8; padding: 12px;
            overflow: auto; max-height: 85vh; text-align: center; min-height: 320px; }
        .t2-pub-preview img { box-shadow: 0 1px 6px rgba(0,0,0,0.25); background: #fff; }
        .t2-cite { font-size: 88%; margin: 4px 0 12px 0; padding: 8px 10px; background: #f6f8fa;
            border-left: 4px solid #3B7DB4; }
        .t2-cite code { display: block; margin-top: 4px; white-space: normal; color: #2c3e50;
            background: transparent; padding: 0; }
        .t2-copy { font-size: 90%; }
        .t2-statement { font-size: 105%; margin: 8px 0 14px 0; padding: 10px 14px; background: #fff8e1;
            border-left: 4px solid #e08e0b; max-width: 1100px; }
        .t2-survival-hint { margin: 0 0 12px 0; max-width: 1100px; }
        .t2-survival-hint.t2-hint-x { font-size: 88%; color: #555; margin: 0 0 8px 0; }
        .t2-fill { margin: 2px 0 6px 0; font-size: 90%; }
        /* the quantize marker (a down-triangle) on numeric options of the variable menus */
        .t2-quant { font-size: 70%; opacity: 0.45; }
        .t2-quant-chip { font-size: 90%; margin: 0 0 6px 0; color: #555; }
        .t2-quant-chip .form-group { display: inline-block; margin: 0 0 0 6px; }
        .t2-quant-chip .radio-inline { margin-left: 6px; padding-left: 18px; }
        .t2-analysis-note { font-size: 90%; color: #555; margin: 6px 0; }
        .t2-fill .form-group { margin-bottom: 0; }
        .t2-fill label.control-label { font-weight: 600; margin-right: 8px; }
        .t2-ref { margin: 0 0 8px 0; max-width: 1100px; }
        .t2-footer { font-size: 80%; color: #666; margin: 18px 0 8px 0; border-top: 1px solid #dce4ec; padding-top: 6px; }
    "))),
    uiOutput('app_title'),
    tabsetPanel(id = 'tabs',
        ## ---- (a) what to plot + the coarse sample filters ----
        tabPanel("Select", value = "select",
            tags$br(),
            inline( selectizeInput('dataset', 'Data set', choices = NULL ) ),
            tags$br(),
            inline( selectizeInput('x', 'Gene (X)', choices = NULL, multiple = TRUE ) ),
            inline( selectizeInput('y', 'Gene (Y)', choices = NULL, multiple = TRUE ) ),
            inline(checkboxInput("multi_y", "Plot Y probes individually", value = FALSE)),
            inline(checkboxInput("zscore_y", "Z-score Y", value = FALSE)),
            uiOutput('x_survival_hint'),
            inline( selectizeInput('color', 'color', choices = NULL, options = list(render = T2_QUANT_RENDER)) ),
            inline( selectizeInput('size', 'size', choices = NULL )),
            inline( selectizeInput('cohort', 'Cohort', choices = NULL, multiple = TRUE )),
            inline( selectizeInput('facet', 'Graph for each:', choices = NULL, multiple = TRUE, options = list(render = T2_QUANT_RENDER) )),
            ## "as: values | 2 | 3 | 4 groups" for a numeric color / first facet pick
            uiOutput('quant_chip_ui'),
            inline(HTML(nbsp(5))),
            inline(checkboxInput("coordflip", "Flip X and Y", value = FALSE)),
            inline(checkboxInput("waterfall", "Waterfall", value = FALSE)),
            inline(checkboxInput("waterfall_flip", "Flip waterfall", value = FALSE)),
            tags$br(),
            ## the ready-made sample subsets of the chosen data source (t2_presets.R)
            uiOutput('preset_group_ui', inline = TRUE),
            uiOutput('preset_excl_ui', inline = TRUE),
            tags$br(),
            ## what the chosen clinical variables mean (t2_descriptions.R)
            uiOutput('var_help'),
            inline( selectizeInput('condition', 'Remove influences of:', choices = NULL, multiple = TRUE )),
            inline(HTML(nbsp(5))),
            inline(
                radioButtons('pcortype', 'Remove influence on:',
                             choices = T2_CONTROLS$pcortype$choices, selected = T2_CONTROLS$pcortype$default, inline = TRUE  ) ),
            actionButton("plot_btn", "Plot")
        ),
        ## ---- (b) the result; every Plot button lands here ----
        tabPanel("Plot", value = "plot",
            div(class = "t2-filter-status", textOutput('filter_status')),
            ## "Not-detected values": shown only when the values answer of this plot offers more than "missing"
            uiOutput('fill_ui'),
            ## the plot area is rebuilt at the chosen Plot height (appearance panel)
            fluidRow( column(12, align="center", uiOutput('main_plot_ui')) ),
            h4("Data Summary"),
            verbatimTextOutput('plot_summary'),
            downloadButton('downloadData', 'Download Table')
        ),
        ## ---- (c) Thanos: fine-tune which samples are plotted ----
        tabPanel("Filter", value = "filter", filter_tab_ui()),
        ## ---- (c2) Analysis: compare groups (filter split / quantiles / a category) on one variable ----
        tabPanel("Analysis", value = "analysis",
            tags$br(),
            helpText("Compare two or more groups of samples on one variable. A group comes from a filter ",
                     "(Selected vs Excluded), from a continuous variable cut into 2-4 equal-count groups, or from a category. ",
                     "All other filters stay in force."),
            inline( selectizeInput('analysis_group', 'Compare groups defined by', choices = NULL, options = list(render = T2_QUANT_RENDER)) ),
            inline( uiOutput('analysis_quant_ui') ),
            inline( selectizeInput('analysis_var', 'Variable to test', choices = NULL) ),
            tags$br(),
            checkboxInput('analysis_means', 'Means-based tests (Welch t / ANOVA)', FALSE),
            actionButton('analysis_run', 'Compare'),
            actionButton('analysis_screen', 'Screen all clinical variables'),
            ## model-mode seam (ANALYSIS-SPEC section 6): covariates / contrasts will render here
            uiOutput('analysis_adjust_ui'),
            uiOutput('analysis_note'),
            plotOutput('analysis_plot', height = '420px'),
            tableOutput('analysis_groups'),
            tableOutput('analysis_stats'),
            downloadButton('analysis_download', 'Download table (.csv)'),
            h4("Clinical screen"),
            tableOutput('analysis_screen_table'),
            selectInput('analysis_screen_pick', 'Open in the comparison above: pick, then press Compare', choices = NULL)
        ),
        ## ---- (e) publication-quality figure export ----
        tabPanel("Publish", value = "publish", publish_tab_ui()),
        ## ---- (f) what this is ----
        tabPanel("About", value = "about",
            h4(paste("About", T2_SITE)),
            div(class = "t2-statement", id = "t2_research_statement",
                tags$b("T2 is a research tool for scientists in biomedical research. "),
                "It shows public research data as plots, with a few summary statistics. It gives no medical advice ",
                "and must not be used for diagnosis or treatment decisions."),
            ## the survival analysis is the heart of T2: point at it first (from /meta tte_variables)
            uiOutput('about_survival_hint'),
            tags$p("T2 is a database and plotting tool for TCGA (The Cancer Genome Atlas) and other genomic databases. Every measurement ",
                   "(expression, mutation, copy number, signatures, clinical annotation, survival) ",
                   "is stored per sample, so any variable can be plotted against any other."),
            ## the active data set's own words (from the service: /meta `about`)
            uiOutput('about_dataset'),
            uiOutput('about_references'),
            tags$ul(
                tags$li(tags$b("Select"), ": choose the data set, the variables to plot (X, Y, color, size, ",
                        "one graph per category) and the cohort(s); then press Plot."),
                tags$li(tags$b("Plot"), ": the resulting graph, a summary of the samples behind it, ",
                        "and a download of the plotted table. The appearance panel below it sets point size, transparency, ",
                        "label sizes, multi-graph layout, fit line and survival-plot options, and searches every ",
                        "other ggplot setting; changes redraw the plot."),
                tags$li(tags$b("Filter"), ": interactive histograms and sliders/checkboxes for every selected ",
                        "variable (and any others you add) to fine-tune which samples are plotted."),
                tags$li(tags$b("Analysis"), ": compare groups (a filter's Selected vs Excluded, a variable cut into ",
                        "equal-count groups, or a category) on one variable with a statistical test, or screen all ",
                        "clinical variables with Benjamini-Hochberg correction; the table downloads as CSV."),
                tags$li(tags$b("Publish"), ": the current plot as a figure of a chosen physical size and ",
                        "resolution (PNG, TIFF or PDF), with a live preview; it shares the appearance panel with the Plot tab, ",
                        "and choosing a figure preset writes that panel.")
            ),
            tags$p(tags$b("Citing T2: "), T2_CITATION),
            h5( paste( 'PI:', a.PI ) ),
            h5( paste('Contributors:', a.credits) ),
            h5( Sys.Date() ),
            h4("Types of Data Available"),
            htmlOutput('datatypes'),
            h4("Statistical methods"),
            tags$p("The survival analysis in T2 (Kaplan-Meier curves, log-rank test, Cox model) uses these methods:"),
            HTML(paste(vapply(T2_METHOD_REFERENCES, t2_reference_html, ""), collapse = "")),
            h4("Clinical variables"),
            htmlOutput('clinical_help'),
            contact_ui(),
            tags$br(),tags$br(),
            h5('Below is an area for my notes, you can ignore...'),
            verbatimTextOutput('print1')
        )
    ),
    ## the shared appearance panel: below the tab content on the Plot and Publish tabs (its inputs stay bound while hidden)
    conditionalPanel("input.tabs == 'plot' || input.tabs == 'publish'", appearance_panel_ui()),
    div(class = "t2-footer", "For research use by biomedical scientists only; not medical advice. Sources: About tab.")
)

################################################################
## Server
################################################################

server = function(input, output, session) {
    ## An observer body must never end the session: a client can send any shape for
    ## an input. Errors are logged and the visitor gets a generic line; req() / validate()
    ## conditions (silent errors) pass through.
    t2_guarded = function(what, expr) {
        tryCatch(expr, error = function(e) {
            if (inherits(e, c("shiny.silent.error", "validation"))) stop(e)
            message("T2 ", what, " failed: ", conditionMessage(e))
            showNotification("Something went wrong with that request; please try again.", type = "error", duration = 8)
            invisible(NULL)
        })
    }
    ## ---- active source bundle (the single object that "knows" the data source) ----
    init_bundle = load_source_bundle(t2_default_dataset())
    bundle = reactiveVal(init_bundle)

    ## populate the data-source selector itself: every dataset and its parts
    updateSelectizeInput(session, 'dataset', choices = T2_SOURCES,
                         selected = t2_default_dataset(), server = TRUE)

    ## ---- the sample choice: one group at most, any number of exclusions ----
    ## What is offered comes from t2_filter_choices() (the same rule as the
    ## iPhone app): the groups of the source, and the exclusions that still
    ## change the samples of the source and the chosen group.
    preset_n = function(b, label, base) sum(base & t2_rules_mask(b$clin, b$presets[[match(label, vapply(b$presets, `[[`, "", "label"))]]$rules))
    ## the presets switched on when a dataset is first opened (default_filters
    ## on_by_default), as the iPhone app applies them: used until the user chooses
    preset_defaults = function(b) {
        on = vapply(b$presets, function(p) isTRUE(p$default), NA)
        labels = vapply(b$presets, `[[`, "", "label")[on]
        list(group = utils::head(intersect(labels, b$source$groups), 1),
             exclusions = intersect(labels, b$source$exclusions))
    }
    ## the user's choice so far, or the defaults: NULL input = not reported yet
    chosen_group = function(b) {
        g = isolate(input$preset_group)
        if (is.null(g)) preset_defaults(b)$group else .t2_one(g, b$source$groups, "")
    }
    output$preset_group_ui = renderUI({
        b = bundle()
        src = b$source
        if (!length(src$groups)) return(NULL)
        base = t2_rules_mask(b$clin, src$rules)
        ch = c(stats::setNames("", sprintf("All samples (%s)", format(src$n_samples, big.mark = ","))),
               stats::setNames(src$groups, vapply(src$groups, function(g)
                   sprintf("%s (%s)", g, format(preset_n(b, g, base), big.mark = ",")), "")))
        radioButtons('preset_group', 'Samples', choices = ch, inline = TRUE,
                     selected = chosen_group(b) %||% "")
    })
    ## rebuilt when the source or the GROUP changes (its choices and counts depend on
    ## those only); the exclusions already ticked are read without a dependency, so a
    ## tick never rebuilds the widget it was made in
    output$preset_excl_ui = renderUI({
        b = bundle()
        group = .t2_one(input$preset_group, b$source$groups, "")
        ch = t2_filter_choices(b$source, b$presets, b$clin, if (nzchar(group)) group else NULL)
        if (!length(ch$exclusions)) return(NULL)
        lab = vapply(ch$exclusions, function(e)
            sprintf("%s (-%s)", e, format(sum(ch$base) - preset_n(b, e, ch$base), big.mark = ",")), "")
        ticked = isolate(input$preset_excl)
        selected = if (is.null(ticked)) preset_defaults(b)$exclusions else .t2_pick(ticked, ch$exclusions, 20)
        checkboxGroupInput('preset_excl', NULL, choices = stats::setNames(ch$exclusions, lab),
                           selected = selected, inline = TRUE)
    })

    output$app_title = renderUI(h4(site_title(bundle()$title)))
    ## the survival hint of the active data set (nothing when it has no time-to-event variable)
    output$about_survival_hint = renderUI(t2_survival_hint(bundle()))
    output$x_survival_hint = renderUI(t2_survival_hint(bundle(), "t2-survival-hint t2-hint-x"))

    ## (re)populate every dataset-dependent selectize from a bundle. The picks
    ## in `keep` (the previous source's) stay where the new source has them
    ## (sticky selections, as in the iPhone app); otherwise the dataset's
    ## defaults; either falls back gracefully. A column with a single value in
    ## the part is never picked (nothing to colour or split by).
    ## the variable menu with its num column (menu kind "num": the quantize marker of
    ## color / facet / Analysis group; the other selectors ignore the column)
    variable_menu = function(b, vars, lower) {
        kind = b$menu$kind[match(vars, b$menu$name)]
        t2_menu(vars, lower = lower, num = kind == "num")
    }
    apply_bundle_choices = function(b, keep = list()) {
        single = b$source$single_level_columns
        keepv = !(b$mygenesplus %in% single)
        mgp = b$mygenesplus[keepv]
        menu = variable_menu(b, mgp, b$names_lower[keepv])   # ONE data object for the variable selectors
        d   = b$defaults
        pick = function(id, choices, fallback = "", n = 1, default = d[[id]]) {
            for (sel in list(keep[[id]], default)) {
                sel = as.character(unlist(sel)); sel = sel[sel %in% choices]
                if (length(sel)) return(utils::head(sel, n))
            }
            fallback
        }
        sel = list(condition = pick('condition', mgp, n = T2_LIMITS$condition_vars),
                   x = pick('x', mgp, if (length(mgp)) mgp[1] else "", n = T2_LIMITS$x_vars),
                   y = pick('y', mgp, if (length(b$mygenes)) b$mygenes[1] else "", n = T2_LIMITS$y_vars),
                   color = pick('color', mgp), size = pick('size', mgp),
                   facet = pick('facet', mgp, NULL, n = T2_LIMITS$facet_vars),
                   cohort = pick('cohort', unname(b$mycohorts), NULL, n = T2_LIMITS$cohorts, default = d$cohorts))
        ## ranked search (t2_search.R): the exact name first, then names starting with the text
        update_selectize_ranked(session, 'condition', menu, sel$condition)
        update_selectize_ranked(session, 'x', menu, sel$x)
        update_selectize_ranked(session, 'y', menu, sel$y)
        update_selectize_ranked(session, 'color', menu, sel$color)
        update_selectize_ranked(session, 'size', menu, sel$size)
        update_selectize_ranked(session, 'cohort', c('all', b$mycohorts), sel$cohort)
        update_selectize_ranked(session, 'facet', menu, sel$facet)
        invisible(sel)       # what the selectors are being set to
    }
    apply_bundle_choices(init_bundle)
    ## The picks shown at the moment of a dataset switch. Until the browser reports
    ## the repopulated selectors, the inputs still hold them: they must not be
    ## pushed to the NEW dataset's Filter tab (see the selected_vars observer).
    stale_picks = NULL

    ## switching datasets: take the bundle of the new data source (cached per
    ## dataset version) and repopulate all inputs from it.
    observeEvent(input$dataset, t2_guarded("dataset switch", {
        ## a client may send any shape for an input: take one value from the served list or nothing
        ds = .t2_one(input$dataset, T2_SOURCES_SERVED, "")
        req(nzchar(ds))
        if (identical(ds, bundle()$key)) return()
        b = load_source_bundle(ds)
        old = isolate(selected_vars()$vars)
        prev = isolate(sanitize_t2_input(input, bundle()))   # the picks to carry over
        bundle(b)
        sel = apply_bundle_choices(b, keep = prev[c('x', 'y', 'color', 'size', 'facet', 'condition', 'cohort')])
        ## the selections the new dataset starts with, as selected_vars will report them
        new = unlist(c(sel$x, sel$y, sel$color, sel$size, sel$facet,
                       if (!identical(isolate(input$pcortype), 'none')) sel$condition))
        new = unique(new[!is.na(new) & nzchar(new)])
        ## arm the guard, unless the old picks ARE the new selections (then pushing them is right)
        stale_picks <<- if (setequal(old, new)) NULL else old
        ## the not-detected choice belongs to the data source it was made on
        fill_choice("na"); fill_state(NULL)
    }), ignoreInit = TRUE)

    ## ---- quantize chip (Select tab): "as: values | 2 | 3 | 4 groups" ----
    ## Shown under the pickers when the color pick (or the FIRST facet pick; later
    ## facet picks stay as they are, to keep the chip to one line) is a bare numeric
    ## variable or a t2q:: token. Choosing k rewrites that selector to the token (an
    ## extra menu row so selectize accepts it); 'values' rewrites it back. The
    ## rewrite happens ONLY in the chip's own event, and only when it changes the
    ## value, so a re-rendered chip reporting its initial state cannot loop.
    quant_chip_state = function(v, b) {      # list(name, k) for a numeric / token pick, else NULL
        v = as.character(unlist(v))[1]
        if (is.na(v) || !nzchar(v)) return(NULL)
        q = t2_quant_parse(v)
        if (!is.null(q)) return(if (identical(.t2_menu_kind(b, q$name), "num")) q else NULL)
        if (v %in% b$mygenesplus && identical(.t2_menu_kind(b, v), "num")) list(name = v, k = 0L) else NULL
    }
    output$quant_chip_ui = renderUI({
        req(identical(input$tabs, "select"))
        b = bundle()
        one = function(id, what, st) tags$div(class = "t2-quant-chip",
            tags$span(paste0(what, ": ", st$name)),
            radioButtons(id, NULL, choices = c("values" = 0, "2" = 2, "3" = 3, "4" = 4), selected = st$k,
                         inline = TRUE),
            tags$span("groups"))
        cs = quant_chip_state(input$color, b)
        fs = quant_chip_state(utils::head(as.character(unlist(input$facet)), 1), b)
        tagList(if (!is.null(cs)) one('quant_chip_color', "color", cs),
                if (!is.null(fs)) one('quant_chip_facet', "graph for each", fs))
    })
    quant_rewrite = function(id, chip) {
        b = bundle()
        cur = as.character(unlist(isolate(input[[id]])))
        st = quant_chip_state(utils::head(cur, 1), b)
        if (is.null(st)) return(invisible(NULL))
        k = .t2_num(chip, c(0, 2:4), 0)
        target = if (k == 0) st$name else t2_quant_token(st$name, k)
        if (identical(target, cur[1])) return(invisible(NULL))       # nothing to change: no loop
        new = c(target, cur[-1])
        mgp = b$mygenesplus[!(b$mygenesplus %in% b$source$single_level_columns)]
        menu = variable_menu(b, mgp, b$names_lower[!(b$mygenesplus %in% b$source$single_level_columns)])
        if (k > 0) {                                                  # the token must be an offered option
            row = data.frame(label = t2_quant_label(st$name, k), value = target, num = 0L, stringsAsFactors = FALSE)
            low = c(attr(menu, "names_lower"), tolower(target))
            menu = rbind(menu, row); attr(menu, "names_lower") = low
        }
        update_selectize_ranked(session, id, menu, new)
    }
    observeEvent(input$quant_chip_color, t2_guarded("quantize chip (color)",
        quant_rewrite('color', input$quant_chip_color)), ignoreInit = TRUE)
    observeEvent(input$quant_chip_facet, t2_guarded("quantize chip (facet)",
        quant_rewrite('facet', input$quant_chip_facet)), ignoreInit = TRUE)

    ## when multi_y is toggled on, add "probe" to color choices and select it
    observeEvent(input$multi_y, t2_guarded("multi-Y switch", {
        b = bundle()
        mgp = b$mygenesplus
        stc = b$handles$name[b$handles$role == "sample_type"]     # the sample-type handle, if the data set has one
        if (.t2_flag(input$multi_y)) {
            update_selectize_ranked(session, 'color', c('probe', mgp), 'probe')
        } else {
            update_selectize_ranked(session, 'color', variable_menu(b, mgp, b$names_lower), if (length(stc)) stc[1] else "")
        }
    }), ignoreInit = TRUE)

    ## ---- Thanos: one instance per dataset, started on first use ----
    ## A Thanos instance is bound to one backend (= one dataset) for life, so
    ## each dataset gets its own; switching datasets swaps which one is shown
    ## and consulted. A filter set up for one dataset can therefore never be
    ## applied to another whose fields may not even exist.
    th_env = new.env(parent = emptyenv())
    th_for = function(b) {
        if (!HAVE_THANOS || !(b$key %in% T2_SOURCES_SERVED)) return(NULL)
        if (!is.null(th_env[[b$key]])) return(th_env[[b$key]])
        be = backend_t2_shared(b)
        ds = b$key
        ## the Select tab's sample choice as this instance's universe; NULL (no
        ## restriction, nothing to recompute) while another source is active
        base = reactive({
            if (!identical(bundle()$key, ds)) return(NULL)
            be$base_mask(cohort = .t2_pick(input$cohort, c('all', unname(b$mycohorts)), T2_LIMITS$cohorts),
                         rules  = sanitize_t2_samples(input, b)$rules)
        })
        ## no extra debounce: server state then always equals what the browser
        ## has sent, so a Plot click right after a filter change sees it
        th = isolate(thanosServer(t2_thanos_id(ds), be, base_mask = base,
                                  debounce_ms = 0, debounce_checkbox_ms = 0))
        th_env[[ds]] = list(th = th, backend = be, base = base)
        th_env[[ds]]
    }
    th_for(init_bundle)
    observeEvent(bundle(), th_for(bundle()))

    ## every variable chosen on the Select tab gets a Thanos panel (additive:
    ## panels stay until removed on the Filter tab). Debounced together with
    ## the dataset name, so after a dataset switch the push waits for the
    ## repopulated selectors rather than sending the previous dataset's picks.
    selected_vars = reactive({
        ## capped per selector BEFORE anything reaches the database: a browser can
        ## send any number of names, whatever the selector shows
        cap = function(v, n) utils::head(as.character(unlist(v)), n)
        ## a t2q:: token stands for its source variable (the Filter tab knows columns only)
        v = c(cap(input$x, T2_LIMITS$x_vars), cap(input$y, T2_LIMITS$y_vars),
              t2_quant_source(cap(input$color, 1)), cap(input$size, 1),
              t2_quant_source(cap(input$facet, T2_LIMITS$facet_vars)),
              if (!identical(input$pcortype, 'none')) cap(input$condition, T2_LIMITS$condition_vars))
        list(dataset = bundle()$key, vars = unique(v[!is.na(v) & nzchar(v)]))
    })
    selected_vars_d = debounce(selected_vars, 500)
    observeEvent(selected_vars_d(), {
        sv = selected_vars_d()
        b = bundle()
        if (!identical(sv$dataset, b$key)) return()
        ## just after a dataset switch the inputs still hold the previous dataset's
        ## picks (the browser has not reported the repopulated selectors yet):
        ## skip them, whatever the timing, and resume with the first real change
        if (!is.null(stale_picks)) {
            if (setequal(sv$vars, stale_picks)) return()
            stale_picks <<- NULL
        }
        h = th_for(b)
        if (is.null(h)) return()
        v = intersect(sv$vars, h$backend$get_columns())
        if (length(v) == 0) return()
        h$backend$prefetch(v)      # one query for all of them
        h$th$add_vars(v)
    })

    ## which samples the Filter tab currently lets through, for dataset bundle b:
    ##   keep  NULL when Thanos adds nothing beyond the Select tab's own filters,
    ##         else the surviving sample ids
    ##   note  one line for the plot summary (NULL when there is no Filter tab)
    ##   mask/base  the full-length logical vectors over backend$samples (the Analysis
    ##         tab builds its group splits from them; see docs/ANALYSIS-SPEC.md)
    filter_state = function(b) {
        h = th_for(b)
        if (is.null(h)) return(list(keep = NULL, note = NULL, active = character(0), n_kept = NA, n_base = NA,
                                    mask = NULL, base = NULL))
        m = h$th$mask()
        base = h$base()
        base = if (is.null(base)) rep(TRUE, length(m)) else (base & !is.na(base))
        active = t2_describe_filters(h$th$filters(), h$backend)
        if (identical(m, base)) {
            return(list(keep = NULL, active = character(0), n_kept = sum(m), n_base = sum(base),
                        mask = m, base = base,
                        note = sprintf("Filter tab: no additional filtering (%d samples).", sum(m))))
        }
        list(keep = h$backend$samples[m], active = active, n_kept = sum(m), n_base = sum(base), mask = m, base = base,
             note = sprintf("Filter tab: %d of %d samples pass. %s", sum(m), sum(base),
                            if (length(active)) paste0("Active filters: ", paste(active, collapse = "; "), ".")
                            else "Samples with missing values (NA) are excluded for at least one variable."))
    }

    ## the caption line "Filtered: ..." for bundle b with the current Select-tab picks and Filter
    ## tab (fs = filter_state(b)); "" when nothing is filtered
    filter_caption_for = function(b, inp, samp, fs)
        t2_filter_caption(samp = samp, b = b, cohort = inp$cohort, rules = fs$active,
                          n_kept = fs$n_kept, n_base = fs$n_base)

    ## live count next to the Filter tab's Plot button
    output$filter_count = renderText({
        h = th_for(bundle())
        if (is.null(h)) return("")
        base = h$base()
        n_base = if (is.null(base)) h$backend$n_rows() else sum(base, na.rm = TRUE)
        sprintf("%s of %s samples selected", format(h$th$n_selected(), big.mark = ","),
                format(n_base, big.mark = ","))
    })

    ## ---- what the chosen clinical variables mean; the whole list on About ----
    output$var_help = renderUI({
        b = bundle()
        inp = sanitize_t2_input(input, b)
        t2_describe_vars(c(inp$x, inp$y, inp$color, inp$size, inp$facet), b$descriptions)
    })
    output$clinical_help = renderUI({
        d = bundle()$descriptions
        if (!length(d)) return(helpText("No descriptions are available for this data set."))
        tags$table(class = "table table-striped table-condensed", style = "font-size: 85%;",
                   tags$thead(tags$tr(tags$th("Column"), tags$th("Meaning"))),
                   tags$tbody(lapply(names(d), function(n) tags$tr(tags$td(tags$code(n)), tags$td(d[[n]])))))
    })
    contact_server(input, output, session)

    ## ---- Appearance: one widget per extra ggplot setting picked in the search box ----
    ## Rebuilt when the pick list changes; a widget that already exists keeps
    ## its current value. What these widgets send is validated against the
    ## registry in sanitize_t2_tweaks() before anything reaches ggplot.
    output$tweak_inputs = renderUI(tweak_widgets(input))

    ## ---- plotting: any of the three Plot buttons ----
    ## the not-detected values choice (per session): "na" | "zero" | "floor". The control itself is drawn
    ## only from what the last plot's values answer offered (fill_state), never from types or dataset names.
    fill_choice = reactiveVal("na")
    fill_state = reactiveVal(NULL)       # t2_fill_of() of the last plot's data (NULL: no plot yet / a new source)
    fill_bump = reactiveVal(0)           # a changed choice draws the plot again, like pressing Plot
    ## a changed appearance setting redraws the current plot (debounced; never before a first Plot press)
    style_bump = reactiveVal(0)
    plot_clicks = reactive(sum(input$plot_btn, input$plot_btn2, input$plot_btn3, fill_bump(), style_bump()))
    style_state = reactive(list(sanitize_t2_style(input), sanitize_t2_tweaks(input), input$scales, input$smooth,
                                input$show_legend, input$allComplete, input$km_groups, input$surv_max_days))
    style_state_d = debounce(style_state, 800)
    observeEvent(style_state_d(), {
        if (isolate(sum(input$plot_btn, input$plot_btn2, input$plot_btn3, fill_bump())) > 0) style_bump(style_bump() + 1)
    }, ignoreInit = TRUE)
    ## the plot's height on the page is, like every Appearance setting, taken at
    ## the moment Plot is pressed
    plot_height = reactiveVal(t2_style_default('plot_height'))
    observeEvent(plot_clicks(), {
        plot_height(.t2_num(input$plot_height, T2_STYLE$plot_height$choices,
                            t2_style_default('plot_height')))
    })
    ## what the last plot was drawn from; the download hands out the same table
    plot_snapshot = NULL
    plot_seq = 0           # which plot this is: a refusal is announced once per plot, not on every resize redraw
    last_notice = list(seq = -1, text = "")
    plot_result = eventReactive(plot_clicks(), {
        plot_seq <<- plot_seq + 1
        ## nothing is drawn until a Plot button has been pressed
        req(plot_clicks() > 0)
        b = bundle()
        ## whitelist + validate every input before it reaches the plotter/SQL
        inp = sanitize_t2_input(input, b)
        if( length(inp$x) == 0 | length(inp$y) == 0 ) { return( NULL ) }
        fs = filter_state(b)
        samp = sanitize_t2_samples(input, b)
        gg = sanitize_t2_tweaks(input)
        note = paste0("Samples: ", samp$label, ".", if (!is.null(fs$note)) paste0(" ", fs$note) else "")
        ctx = t2_plot_ctx(b, keep = fs$keep, rules = samp$rules, fill = fill_choice())
        plot_snapshot <<- list(inp = inp, b = b, ctx = ctx, note = note, gg = gg)
        fcap = filter_caption_for(b, inp, samp, fs)
        withProgress(message = 'Working...', value = 0, {
            incProgress(0.20, message = "Plotting")
            ## an answer of the data service that failed is not shown as it is (URLs, host names)
            tryCatch(fun_plot1(inp, reactive = FALSE, ctx = ctx, gg = gg, filter_caption = fcap),
                     error = function(e) {
                         m = conditionMessage(e)
                         safe = t2_user_message(m)
                         if (identical(safe, m)) stop(e)
                         list(warning = safe)
                     })
        })
    })
    observe({
        res = tryCatch(plot_result(), error = function(e) NULL)
        fill_state(t2_result_fill(res))
    })
    output$fill_ui = renderUI({
        info = fill_state()
        opts = info$options
        if (length(opts) < 2) return(NULL)           # nothing but "missing" applies: no control at all
        lab = c(na = "Missing", zero = "Zero", floor = "Detection floor")
        cur = isolate(fill_choice())
        div(class = "t2-fill",
            radioButtons('not_detected', "Not-detected values", inline = TRUE,
                         choices = stats::setNames(opts, lab[opts]), selected = if (cur %in% opts) cur else "na"))
    })
    observeEvent(input$not_detected, {
        v = .t2_one(input$not_detected, c("na", "zero", "floor"), "na")
        if (!identical(v, fill_choice())) { fill_choice(v); fill_bump(fill_bump() + 1) }
    }, ignoreInit = TRUE)
    ## pressing Plot anywhere shows the result
    observeEvent(input$plot_btn,  updateTabsetPanel(session, 'tabs', selected = 'plot'))
    observeEvent(input$plot_btn2, updateTabsetPanel(session, 'tabs', selected = 'plot'))
    observeEvent(input$plot_btn3, updateTabsetPanel(session, 'tabs', selected = 'plot'))

    ## the size comes from the browser (clientData), which a client can forge: both
    ## sides are clamped, so a hostile page cannot ask for a 30000 x 16000 px plot
    clamp_px = function(v) if (length(v) != 1 || !is.numeric(v) || is.na(v)) NULL else min(max(v, 200), 3000)
    output$main_plot = renderPlot({
        res = plot_result()
        if (is.null(res)) return(NULL)
        if (is.list(res) && !is.null(res$warning)) {
            txt = t2_user_message(res$warning)
            if (!(identical(last_notice$seq, plot_seq) && identical(last_notice$text, txt))) {
                last_notice <<- list(seq = plot_seq, text = txt)
                showNotification(txt, type = "warning", duration = 10)
            }
            if (is.null(res$plot)) return(NULL)
        }
        ## Survival mode returns a ggsurvplot (a list with $plot + $table); print
        ## the whole object so the risk table renders too, not just the curve.
        if (inherits(res, "ggsurvplot")) return(res)
        if (is.list(res) && !is.null(res$plot)) res$plot else res
    },
    width  = function() clamp_px(session$clientData$output_main_plot_width),
    height = function() clamp_px(plot_height()))
    ## a fixed-height container (not height = "auto": an auto-height plot
    ## collapses while it redraws, the page scrollbar comes and goes, the width
    ## changes, and the plot redraws for ever)
    output$main_plot_ui = renderUI({
        withSpinner( plotOutput( "main_plot", height = paste0(plot_height(), 'px'), width = '95%' ),
                    color = viridis::plasma(1) )
    })
    ## the Filter tab's contribution to this plot, so it never applies unseen
    filter_note = function() {
        res = plot_result()
        if (is.null(res) || is.null(plot_snapshot$note)) "" else plot_snapshot$note
    }
    output$filter_status = renderText(filter_note())
    output$plot_summary = renderText({
        res = plot_result()
        if (is.null(res)) return("")
        txt = if (!is.null(attr(res, "t2summary"))) attr(res, "t2summary")
              else if (is.list(res) && !is.null(res$summary)) res$summary else ""
        note = filter_note()
        if (nzchar(note)) paste0(txt, "\n\n", note) else txt
    })
    ## ---- Publish: the current selections as a figure of a real size ----
    ## Not tied to the Plot buttons: it draws what the Select tab and the Filter
    ## tab say right now, with its OWN style values (the pub_ inputs), and the
    ## download is rendered from the very same specification as the preview.
    pub_preset = reactive(T2_FIG_PRESETS[[sanitize_t2_figure(input)$preset]])
    ## choosing a preset fills in its size and its print- or slide-scale sizes
    observeEvent(input$pub_preset, {
        pr = pub_preset()
        updateNumericInput(session, 'pub_width', value = pr$width)
        updateNumericInput(session, 'pub_height', value = pr$height)
        updateSelectInput(session, 'pub_units', selected = pr$units)
        updateSelectInput(session, 'pub_dpi', selected = pr$dpi)
        ## the style menus are the SHARED ones (plot_height is screen-only: no preset carries it)
        for (id in setdiff(names(pr$style), "plot_height")) updateSelectInput(session, id, selected = pr$style[[id]])
    }, ignoreInit = TRUE)

    pub_fig = reactive(sanitize_t2_figure(input))
    ## everything that decides what is drawn (not how large the file is)
    pub_spec = reactive({
        ## only the Publish tab draws a figure: no work on every input change elsewhere
        req(identical(input$tabs, "publish"))
        b = bundle()
        inp = sanitize_t2_input(input, b)
        if (length(inp$x) == 0 || length(inp$y) == 0) return(NULL)
        fig = pub_fig()
        pr = T2_FIG_PRESETS[[fig$preset]]
        ## (inp already carries the shared appearance styles)
        ## the preset's own defaults for unlisted settings (publish-only base), then the shared tweaks
        gg = utils::modifyList(pr$gg, sanitize_t2_tweaks(input))
        fs = filter_state(b)
        samp = sanitize_t2_samples(input, b)
        list(b = b, inp = inp, ctx = t2_plot_ctx(b, keep = fs$keep, rules = samp$rules, fill = fill_choice()), gg = gg,
             base_size = fig$base_size, family = fig$family, fig_width = fig$width,
             ## each text element of the figure has its own switch (Publish tab)
             caption = if (fig$source_line) T2_CITATION else "",
             filter_caption = if (fig$show_caption) filter_caption_for(b, inp, samp, fs) else "",
             fill_caption = fig$show_caption,           # the not-detected line is part of the caption
             show = fig[c("show_title", "show_subtitle", "show_axis_titles")])
    })
    pub_draw = function(s) {
        t2_apply_text_switches(
            fun_plot1(s$inp, reactive = FALSE, ctx = s$ctx, gg = s$gg,
                      base_size = s$base_size, base_family = s$family, caption = s$caption,
                      fig_width = s$fig_width, filter_caption = s$filter_caption, fill_caption = s$fill_caption),
            title = s$show$show_title, subtitle = s$show$show_subtitle, axis_titles = s$show$show_axis_titles)
    }
    ## redraw about a second after the last change, not on every keystroke
    pub_spec_d = debounce(pub_spec, 900)
    pub_fig_d  = debounce(pub_fig, 900)
    pub_result = reactive({ s = pub_spec_d(); if (is.null(s)) NULL else pub_draw(s) })

    output$pub_readout = renderText({
        fig = pub_fig()
        paste0(t2_figure_readout(fig), if (!is.null(fig$note)) paste0("   NOTE: ", fig$note) else "")
    })
    output$pub_preview = renderImage({
        res = pub_result()
        obj = t2_figure_object(res)
        if (is.null(obj)) {
            msg = if (is.list(res) && !is.null(res$warning)) res$warning
                  else "Choose X and Y on the Select tab to see a figure here."
            validate(need(FALSE, msg))
        }
        fig = pub_fig_d()
        zoom = .t2_one(input$pub_zoom, c("fit", "print", "pixels"), "fit")
        f = tempfile(fileext = ".png")
        ## the same rendering as the download; a fit-to-window view of a
        ## high-resolution figure is drawn with fewer pixels, same layout
        t2_render_figure(obj, f, fig$width, fig$height, t2_preview_dpi(fig, zoom), "png")
        list(src = f, contentType = "image/png", alt = "figure preview",
             style = switch(zoom,
                            fit    = "max-width: 100%; max-height: 80vh; height: auto; width: auto;",
                            print  = sprintf("width: %.3fin; height: auto;", fig$width),
                            pixels = ""))
    }, deleteFile = TRUE)
    output$pub_download = downloadHandler(
        filename = function() {
            b = bundle()
            t2_figure_filename(sanitize_t2_input(input, b), pub_fig())
        },
        content = function(file) {
            s = pub_spec()
            obj = if (is.null(s)) NULL else t2_figure_object(pub_draw(s))
            if (is.null(obj)) stop("Nothing to plot: choose X and Y on the Select tab.")
            fig = pub_fig()
            t2_render_figure(obj, file, fig$width, fig$height, fig$dpi, fig$format)
        })

    ## ---- Analysis: compare groups on one variable (group_compare.R; ANALYSIS-SPEC.md) ----
    ## Everything computes on the Analysis tab only. A grouping is built from the stable sample
    ## vector (row i = backend$samples[i]); every other filter stays in force (the mask).
    an_get = function(h, v, kind) {        # one variable over all rows; categories in the served level order
        h$backend$prefetch(v)
        x = h$backend$get_column(v)
        if (identical(kind, "cat")) {
            lv = h$backend$get_column_info(v)$levels
            factor(as.character(x), levels = if (length(lv)) lv else NULL)
        } else x
    }
    ## the one-line description of ONE active filter column
    an_describe = function(h, col) {
        d = t2_describe_filters(h$th$filters()[col], h$backend)
        if (length(d)) d[1] else col
    }
    ## the grouping the sanitizer accepted -> list(g = t2_group_*, label = display name)
    an_grouping = function(b, h, grouping, fs) {
        n = length(h$backend$samples)
        universe = if (is.null(fs$mask)) rep(TRUE, n) else (fs$mask & fs$base)
        switch(grouping$kind,
            split_loo = {
                col = grouping$col
                x = an_get(h, col, "num")
                s = h$th$streams(col, split_range = FALSE, drop_na = FALSE)
                m_sel = sum(is.na(x[s$selected])); m_exc = sum(is.na(x[s$excluded]))
                miss = c(if (m_exc > 0) sprintf("Excluded includes %d samples missing %s.", m_exc, col),
                         if (m_sel > 0) sprintf("Selected includes %d samples missing %s.", m_sel, col))
                list(g = t2_group_from_streams(s, n, missing_note = miss), label = paste0("Split: ", an_describe(h, col)))
            },
            split_whole = list(g = t2_group_from_streams(list(selected = which(fs$mask),
                                                              excluded = which(fs$base & !fs$mask)), n),
                               label = "Split: all filters together"),
            quant = {
                h$backend$prefetch(grouping$name)
                list(g = t2_group_quantized(h$backend$get_column(grouping$name), universe = universe, k = grouping$k),
                     label = t2_quant_label(grouping$name, grouping$k))
            },
            cat = {
                h$backend$prefetch(grouping$name)
                list(g = t2_group_categorical(h$backend$get_column(grouping$name), universe = universe,
                                              levels = h$backend$get_column_info(grouping$name)$levels),
                     label = grouping$name)
            })
    }
    ## the sanitized pick without a test variable (the screen needs the grouping only)
    an_sanitize_grouping = function(b, h, with_var = TRUE) {
        inp = list(analysis_group = input$analysis_group, analysis_quant_k = input$analysis_quant_k,
                   analysis_means = input$analysis_means,
                   analysis_var = if (with_var) input$analysis_var else b$mygenesplus[1])
        sanitize_t2_analysis(inp, b, active_cols = names(h$th$filters()))
    }

    ## the choices: filter splits first, then every served variable (ranked search, t2_search.R)
    analysis_group_menu = reactive({
        req(identical(input$tabs, "analysis"))
        b = bundle(); h = th_for(b)
        req(h)
        cols = names(h$th$filters())
        custom = stats::setNames(vapply(cols, t2_split_token, ""),
                                 vapply(cols, function(v) paste0("Split: ", an_describe(h, v)), ""))
        if (length(cols) >= 2) custom = c(custom, stats::setNames(t2_split_token(), "Split: all filters together"))
        kind = b$menu$kind[match(b$mygenesplus, b$menu$name)]
        m = t2_menu(c(unname(custom), b$mygenesplus), lower = c(tolower(unname(custom)), b$names_lower),
                    num = c(rep(0L, length(custom)), kind == "num"))    # split tokens: no marker
        m$label = c(names(custom), b$mygenesplus)      # t2_menu() drops names: the custom rows carry readable labels
        m
    })
    observe(t2_guarded("analysis choices", {
        menu = analysis_group_menu()
        cur = isolate(.t2_one(input$analysis_group, menu$value, ""))
        update_selectize_ranked(session, 'analysis_group', menu, if (nzchar(cur)) cur else menu$value[1])
    }))
    observe(t2_guarded("analysis variable choices", {
        req(identical(input$tabs, "analysis"))
        b = bundle()
        vars = c(b$mygenesplus, tte_names(b))
        cur = isolate(.t2_one(input$analysis_var, vars, ""))
        update_selectize_ranked(session, 'analysis_var', t2_menu(vars, lower = c(b$names_lower, tolower(tte_names(b)))),
                                if (nzchar(cur)) cur else vars[1])
    }))
    ## the number of groups, only for a continuous grouping variable
    output$analysis_quant_ui = renderUI({
        g = .t2_one(input$analysis_group, bundle()$mygenesplus, "")
        if (!identical(.t2_menu_kind(bundle(), g), "num")) return(NULL)
        radioButtons('analysis_quant_k', 'Number of groups', choices = T2_CONTROLS$quant_k$choices, inline = TRUE,
                     selected = .t2_num(isolate(input$analysis_quant_k), T2_CONTROLS$quant_k$choices, T2_CONTROLS$quant_k$default))
    })
    output$analysis_adjust_ui = renderUI(NULL)

    an_filters_line = function(fs)
        paste0("Maintained filters: ", if (length(fs$active)) paste(fs$active, collapse = "; ") else "none beyond the Select tab", ".")
    an_p = function(p) vapply(p, fmtp, "")
    an_num = function(v) ifelse(is.na(v), "", sprintf("%.4g", v))
    an_snapshot = NULL

    analysis_result = eventReactive(input$analysis_run, t2_guarded("analysis", {
        req(identical(input$tabs, "analysis"))
        b = bundle(); h = th_for(b)
        validate(need(!is.null(h), "The analysis needs the Filter tab, which is not available."))
        a = an_sanitize_grouping(b, h)
        validate(need(!is.null(a), "Pick a grouping and a variable."))
        fs = filter_state(b)
        gl = an_grouping(b, h, a$grouping, fs)
        g = gl$g
        validate(need(is.null(g$refused), g$refused))
        tte = NULL; x = NULL; ent = NULL
        max_days = .t2_num(input$surv_max_days, T2_CONTROLS$surv_max_days$choices, T2_CONTROLS$surv_max_days$default)
        if (identical(a$var_kind, "tte")) {
            ent = b$tte[[a$var]]
            tte = list(time = an_get(h, ent$time_col, "num"), event = an_get(h, ent$event_col, "num"))
        } else x = an_get(h, a$var, a$var_kind)
        res = t2_group_test(x, g$grp, a$var_kind, means = a$means, tte = tte, max_days = max_days)
        validate(need(is.null(res$refused), res$refused))
        snap = list(label = gl$label, g = g, res = res, a = a, x = x, tte = tte, ent = ent, max_days = max_days,
                    filters = an_filters_line(fs), dataset = b$key)
        an_snapshot <<- snap
        snap
    }))
    output$analysis_note = renderUI({
        s = analysis_result()
        notes = c(s$g$note, s$res$test$note, s$filters)
        div(class = "t2-analysis-note", lapply(notes[nzchar(notes)], tags$div))
    })
    output$analysis_plot = renderPlot({
        s = analysis_result()
        switch(s$a$var_kind,
            num = t2_plot_group_box(s$x, s$g$grp, s$a$var, s$label),
            cat = t2_plot_group_counts(s$x, s$g$grp, s$a$var, s$label),
            tte = t2_plot_group_km(s$tte$time, s$tte$event, s$g$grp, s$ent$label %||% s$a$var,
                                   unit = t2_tte_unit(s$ent$time_unit %||% "days"), max_days = s$max_days))
    }, height = 420)
    an_fmt_groups = function(d) {
        for (v in names(d)) if (is.numeric(d[[v]])) d[[v]] = if (v %in% c("n", "count", "events")) as.character(d[[v]]) else an_num(d[[v]])
        d
    }
    output$analysis_groups = renderTable(an_fmt_groups(analysis_result()$res$groups), na = "")
    output$analysis_stats = renderTable({
        t = analysis_result()$res$test
        data.frame(term = t$term, method = t$method, statistic = an_num(t$statistic), df = an_num(t$df),
                   p = an_p(t$p), note = t$note, stringsAsFactors = FALSE)
    })
    output$analysis_download = downloadHandler(
        filename = function() sprintf("t2-analysis-%s-%s.csv", gsub("[^A-Za-z0-9.-]+", "-", bundle()$key), format(Sys.Date())),
        content = function(file) {
            s = an_snapshot
            if (is.null(s)) stop("Nothing to download: press Compare first.")
            tab = t2_group_result_table(s$res, header = c(s$label, sprintf("universe n = %d", s$g$n_universe), s$filters))
            utils::write.table(tab, file, sep = ",", row.names = FALSE, col.names = FALSE, qmethod = "double")
        })

    ## ---- the clinical screen: the grouping against every handle + clinical variable ----
    screen_result = eventReactive(input$analysis_screen, t2_guarded("analysis screen", {
        req(identical(input$tabs, "analysis"))
        b = bundle(); h = th_for(b)
        validate(need(!is.null(h), "The analysis needs the Filter tab, which is not available."))
        a = an_sanitize_grouping(b, h, with_var = FALSE)
        validate(need(!is.null(a), "Pick a grouping."))
        fs = filter_state(b)
        gl = an_grouping(b, h, a$grouping, fs)
        validate(need(is.null(gl$g$refused), gl$g$refused))
        own = a$grouping$col %||% a$grouping$name       # the grouping's own source column is circular
        mn = b$menu
        vars = setdiff(intersect(mn$name[mn$section %in% c("handle", "clinical")], h$backend$get_columns()), own)
        kinds = stats::setNames(mn$kind[match(vars, mn$name)], vars)
        max_days = .t2_num(input$surv_max_days, T2_CONTROLS$surv_max_days$choices, T2_CONTROLS$surv_max_days$default)
        h$backend$prefetch(vars)                         # one query for the whole list
        out = withProgress(message = "Screening", value = 0.5,
            t2_group_screen(vars, function(v) an_get(h, v, kinds[[v]]), kinds, gl$g$grp, means = a$means, max_days = max_days))
        flagged = out$variable %in% names(h$th$filters())
        out$note[flagged] = trimws(paste("[filtered]", out$note[flagged]))
        list(table = out, label = gl$label, g = gl$g, filters = an_filters_line(fs), means = a$means)
    }))
    output$analysis_screen_table = renderTable({
        s = screen_result(); t = s$table
        data.frame(variable = t$variable, kind = t$kind, method = ifelse(is.na(t$method), "", t$method),
                   n = ifelse(is.na(t$n), "", as.character(t$n)), p = an_p(t$p), p_bh = an_p(t$p_bh), note = t$note,
                   stringsAsFactors = FALSE)
    })
    observe(t2_guarded("analysis screen choices", {
        t = tryCatch(screen_result()$table, error = function(e) NULL)
        if (!is.null(t)) updateSelectInput(session, 'analysis_screen_pick', choices = t$variable)
    }))
    ## picking a row puts its variable into the comparison above; the user presses Compare
    observeEvent(input$analysis_screen_pick, t2_guarded("analysis screen pick", {
        t = screen_result()$table
        v = .t2_one(input$analysis_screen_pick, t$variable, "")
        req(nzchar(v))
        update_selectize_ranked(session, 'analysis_var', t2_menu(c(bundle()$mygenesplus, tte_names(bundle())),
                                lower = c(bundle()$names_lower, tolower(tte_names(bundle())))), v)
    }), ignoreInit = TRUE)

    output$datatypes = renderUI({
        b = bundle()
        type_df = b$types      # read with the bundle (files or service)
        ## convert PMID references to clickable PubMed links
        type_df$reference = sapply(type_df$reference, function(ref) {
            if (is.na(ref)) return(ref)
            ref = htmltools::htmlEscape(ref)       # the data is trusted; escaped anyway
            pmid = regmatches(ref, regexpr("PMID:\\d+", ref))
            if (length(pmid) > 0) {
                pmid_num = sub("PMID:", "", pmid)
                url = paste0("https://pubmed.ncbi.nlm.nih.gov/", pmid_num)
                sub(pmid, paste0('<a href="', url, '" target="_blank">', pmid, '</a>'), ref, fixed = TRUE)
            } else ref
        })
        ## make source_url clickable, labelled by the host of the link
        type_df$source_link = sapply(type_df$source_url, function(url) {
            if (!is.na(url) && nzchar(t2_safe_href(url)))
                paste0('<a href="', htmltools::htmlEscape(url, attribute = TRUE), '" target="_blank">',
                       htmltools::htmlEscape(t2_url_host(url)), '</a>')
            else ""
        })
        header = tags$tr(
            tags$th("Type"), tags$th("Description"),
            tags$th("Example Probes"), tags$th("Source File"),
            tags$th("Reference"), tags$th("Data")
        )
        has = function(col) if (col %in% names(type_df)) !is.na(type_df[[col]]) & nzchar(type_df[[col]]) else rep(FALSE, nrow(type_df))
        full_ref = has("reference_title")
        rows = lapply(seq_len(nrow(type_df)), function(i) {
            rec = if (full_ref[i]) list(title = type_df$reference_title[i], authors = type_df$reference_authors[i],
                                        journal = type_df$reference_journal[i], year = type_df$reference_year[i],
                                        url = type_df$reference_url[i])
            tags$tr(
                tags$td(tags$code(type_df$type[i])),
                tags$td(type_df$description[i]),
                tags$td(tags$code(type_df$example[i])),
                tags$td(tags$small(type_df$source_file[i])),
                tags$td(HTML(if (full_ref[i]) t2_reference_html(rec) else type_df$reference[i])),
                tags$td(HTML(type_df$source_link[i]))
            )
        })
        ## Time-to-event variables are clinical columns (not `types` rows), so note
        ## them explicitly: selecting one as X switches to time-to-event analysis.
        ## Generated from the data set's own list (/meta tte_variables); nothing for a data set without one.
        survival_note <- t2_survival_note(b)
        tagList(
            tags$table(
                class = "table table-striped table-condensed",
                style = "font-size: 85%;",
                tags$thead(header),
                tags$tbody(rows)
            ),
            survival_note
        )
    })
    ## the dataset's bibliography: full titles, authors, journal, year and links, grouped
    output$about_references = renderUI({
        refs = bundle()$about$references
        if (!length(refs)) return(NULL)
        grp = vapply(refs, function(r) as.character(r$group %||% ""), "")
        tagList(h4("Sources and references"),
            lapply(unique(grp), function(g) tagList(
                if (nzchar(g)) h5(g),
                HTML(paste(vapply(refs[grp == g], t2_reference_html, ""), collapse = "")))))
    })
    ## the data set's own About prose (/meta about): description, citation, attribution, link
    output$about_dataset = renderUI({
        a = bundle()$about
        if (!any(nzchar(unlist(a)))) return(NULL)
        tagList(
            if (nzchar(a$description)) tags$p(a$description),
            if (nzchar(a$citation)) tags$p(tags$b("Citation: "), a$citation),
            if (nzchar(a$attribution)) tags$p(tags$i(a$attribution)),
            if (nzchar(t2_safe_href(a$url))) tags$p(tags$a(href = t2_safe_href(a$url), target = "_blank", t2_url_host(a$url))))
    })
    ## the table behind the last plot (same dataset, variables and samples);
    ## before any plot, the table for the current selections
    output$downloadData = downloadHandler(
        filename = "csvdownload.csv",
        content = function(file) {
            snap = plot_snapshot
            if (is.null(snap)) {
                b = bundle()
                snap = list(inp = sanitize_t2_input(input, b), b = b,
                            ctx = t2_plot_ctx(b, keep = isolate(filter_state(b))$keep,
                                              rules = isolate(sanitize_t2_samples(input, b))$rules,
                                              fill = isolate(fill_choice())))
            }
            write.csv(fun_table1(snap$inp, ctx = snap$ctx), file)
        })
    output$print1 = renderPrint({
        print( str( reactiveValuesToList(input) ) )
    })
}

shinyApp(ui = ui, server = server)
