## app.R - combined Shiny application
## History from server.R: 5101adc 7e740ec 89e7671 a1e5ea7 4b0a2cb b67ed0d
##   2b0ecd2 3cacb04 f5af0e7 f87110f 245f470 0eb4ca9
## History from ui.R: 5101adc 7552c47 7e740ec 9040bd9 ed9ae38 a1e5ea7
##   4b0a2cb 2809b6f b67ed0d 2b0ecd2 3cacb04 f5af0e7 245f470 0eb4ca9
##   e3ae465 a760cf2

## check all required packages before starting
required_pkgs = c("shiny", "shinythemes", "shinycssloaders", "rmarkdown",
                  "DBI", "RSQLite", "sqldf", "ggplot2", "ggthemes",
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
library(DBI)

source('global.R')
source('database_connection_shiny.R')
source("lib.R")
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
style_select = function(id, prefix = "", default = NULL) {
    st = T2_STYLE[[id]]
    inline(selectInput(paste0(prefix, id), gg_label(st$label, st$gg), choices = st$choices,
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

## the Publish tab: a figure of a given physical size and resolution
publish_tab_ui = function() {
    pr = T2_FIG_PRESETS[[T2_FIG_DEFAULT_PRESET]]
    sty = function(id) style_select(id, "pub_", pr$style[[id]])
    tagList(
        tags$br(),
        helpText("A figure for a paper or a slide: choose its real size and resolution, adjust until the ",
                 "preview reads well, then press ", tags$b("Plot"), " to download the file. The preview is the figure itself, ",
                 "drawn at the size you asked for. These settings are separate from the Appearance tab: ",
                 "sizes that suit the screen do not suit a 3.5 inch figure."),
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
                h5("Sizes at final print size"),
                div(class = "t2-pub-style",
                    sty('title_size'), sty('subtitle_size'), sty('axis_title_size'), sty('axis_text_size'),
                    sty('strip_size'), sty('legend_size'), sty('point_size'), sty('alpha'), sty('ncols')),
                inline(checkboxInput("pub_show_legend", gg_label("Show legend", "legend.position"), value = TRUE)),
                inline(checkboxInput("pub_source", "Show source line", value = TRUE)),
                div(class = "t2-cite",
                    conditionalPanel("!input.pub_source",
                        tags$b("You have removed the source line."), " That is fine, but please cite T2 in any ",
                        "publication or presentation that uses this figure:"),
                    conditionalPanel("input.pub_source", "The source line, and the citation for T2:"),
                    tags$code(id = "t2_citation", T2_CITATION),
                    tags$a(href = "#", class = "t2-copy",
                           onclick = "navigator.clipboard.writeText(document.getElementById('t2_citation').innerText); this.innerText = 'copied'; return false;",
                           "copy")),
                h5("More ggplot settings"),
                tweak_picker("pub_"),
                div(class = "t2-tweaks", uiOutput('pub_tweak_inputs'))
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

## datasets known at startup: the Filter tab holds one (hidden) Thanos panel
## set per dataset, shown for whichever dataset is selected
T2_DATASETS = list_datasets()

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
                 "Cohort and the Exclude checkboxes on the Select tab decide which samples are shown here at all. ",
                 "Filters take effect on the plot when you press ", tags$b("Plot"), "."),
        lapply(T2_DATASETS, function(ds) {
            conditionalPanel(
                condition = sprintf("input.dataset == %s",
                                    jsonlite::toJSON(ds, auto_unbox = TRUE)),
                div(class = "t2-thanos", thanosUI(t2_thanos_id(ds))))
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
            inline( selectizeInput('color', 'color', choices = NULL) ),
            inline( selectizeInput('size', 'size', choices = NULL )),
            inline( selectizeInput('cohort', 'Cohort', choices = NULL, multiple = TRUE )),
            inline( selectizeInput('facet', 'Graph for each:', choices = NULL, multiple = TRUE  )),
            inline(HTML(nbsp(5))),
            inline(checkboxInput("coordflip", "Flip X and Y", value = FALSE)),
            inline(checkboxInput("waterfall", "Waterfall", value = FALSE)),
            inline(checkboxInput("waterfall_flip", "Flip waterfall", value = FALSE)),
            inline(checkboxInput("nonormal", "Exclude Non-tumor", value = FALSE)),
            inline(checkboxInput("noheme", "Exclude tumors of heme origin", value = FALSE)),
            tags$br(),
            inline( selectizeInput('condition', 'Remove influences of:', choices = NULL, multiple = TRUE )),
            inline(HTML(nbsp(5))),
            inline(
                radioButtons('pcortype', 'Remove influence on:',
                             choices = c('none', 'x', 'y', 'both'), selected = 'none', inline = TRUE  ) ),
            actionButton("plot_btn", "Plot")
        ),
        ## ---- (b) the result; every Plot button lands here ----
        tabPanel("Plot", value = "plot",
            div(class = "t2-filter-status", textOutput('filter_status')),
            ## the plot area is rebuilt at the chosen Plot height (Appearance tab)
            fluidRow( column(12, align="center", uiOutput('main_plot_ui')) ),
            h4("Data Summary"),
            verbatimTextOutput('plot_summary'),
            downloadButton('downloadData', 'Download Table')
        ),
        ## ---- (c) Thanos: fine-tune which samples are plotted ----
        tabPanel("Filter", value = "filter", filter_tab_ui()),
        ## ---- (d) plot appearance ----
        tabPanel("Appearance", value = "appearance",
            h4('Fiddly Options'),
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
                                choices = c("fixed", "free", "free_x", "free_y"), selected = "fixed") ),
            style_select('ncols'),
            inline( selectInput('smooth', gg_label('Fit line', 'geom_smooth(method = "lm")'),
                                choices = c("TRUE", "FALSE"), selected = "TRUE") ),
            style_select('plot_height'),
            tags$br(),
            inline(checkboxInput("show_legend", gg_label("Show legend", "legend.position"), value = TRUE)),
            inline(checkboxInput("allComplete", "Show only results with complete information", value = TRUE)),
            tags$br(),
            ## survival (Kaplan-Meier) options — used when X is a time-to-event endpoint
            inline( selectizeInput('km_groups', 'Survival: # groups (Y)', choices = c(2, 3, 4, 5, 6), selected = 3) ),
            inline( numericInput('surv_max_days', 'Survival: max follow-up (days)', value = 365 * 5, min = 30, step = 30) ),
            h4('More ggplot settings'),
            helpText("Search every other ggplot setting: all theme elements (axis text angle, legend position, ",
                     "grid lines, backgrounds, spacing ...) and the drawing settings of points, boxplots and the fit line. ",
                     "Each one you pick appears below with its current default; choose from the menu, or type your own number or #hex colour."),
            tweak_picker(),
            div(class = "t2-tweaks", uiOutput('tweak_inputs')),
            actionButton("plot_btn2", "Plot")
        ),
        ## ---- (e) publication-quality figure export ----
        tabPanel("Publish", value = "publish", publish_tab_ui()),
        ## ---- (f) what this is ----
        tabPanel("About", value = "about",
            h4(paste("About", T2_SITE)),
            tags$p("T2 is a database and plotting tool for large tumor-profiling compendia: ",
                   "the TCGA Pan-Cancer 2018 release and companion datasets. Every measurement ",
                   "(expression, mutation, copy number, signatures, clinical annotation, survival) ",
                   "is stored per sample, so any variable can be plotted against any other."),
            tags$ul(
                tags$li(tags$b("Select"), ": choose the data set, the variables to plot (X, Y, color, size, ",
                        "one graph per category) and the cohort(s); then press Plot."),
                tags$li(tags$b("Plot"), ": the resulting graph, a summary of the samples behind it, ",
                        "and a download of the plotted table."),
                tags$li(tags$b("Filter"), ": interactive histograms and sliders/checkboxes for every selected ",
                        "variable (and any others you add) to fine-tune which samples are plotted."),
                tags$li(tags$b("Appearance"), ": point size, transparency, label sizes, multi-graph layout, ",
                        "fit line and survival-plot options, and a search over every other ggplot setting."),
                tags$li(tags$b("Publish"), ": the current plot as a figure of a chosen physical size and ",
                        "resolution (PNG, TIFF or PDF), with a live preview.")
            ),
            tags$p(tags$b("Citing T2: "), T2_CITATION),
            h5( paste( 'PI:', a.PI ) ),
            h5( paste('Contributors:', a.credits) ),
            h5( Sys.Date() ),
            h4("Types of Data Available"),
            htmlOutput('datatypes'),
            tags$br(),tags$br(),
            h5('Below is an area for my notes, you can ignore...'),
            verbatimTextOutput('print1')
        )
    )
)

################################################################
## Server
################################################################

server = function(input, output, session) {
    ## ---- active dataset bundle (the single object that "knows" the dataset) ----
    init_bundle = load_dataset_bundle(default_dataset())
    bundle = reactiveVal(init_bundle)

    ## populate the dataset selector itself
    updateSelectizeInput(session, 'dataset', choices = list_datasets(),
                         selected = default_dataset(), server = TRUE)

    output$app_title = renderUI(h4(site_title(bundle()$title)))

    ## (re)populate every dataset-dependent selectize from a bundle. Defaults
    ## that aren't valid choices for the selected dataset fall back gracefully.
    apply_bundle_choices = function(b) {
        mgp = b$mygenesplus
        d   = b$defaults
        pick = function(sel, choices, fallback = "") {
            sel = sel[sel %in% choices]
            if (length(sel)) sel else fallback
        }
        updateSelectizeInput(session, 'condition', choices = mgp,
                             selected = pick(d$condition, mgp), server = TRUE)
        updateSelectizeInput(session, 'x', choices = mgp,
                             selected = pick(d$x, mgp, if (length(mgp)) mgp[1] else ""), server = TRUE)
        updateSelectizeInput(session, 'y', choices = mgp,
                             selected = pick(d$y, mgp, if (length(b$mygenes)) b$mygenes[1] else ""), server = TRUE)
        updateSelectizeInput(session, 'color', choices = mgp,
                             selected = pick(d$color, mgp), server = TRUE)
        updateSelectizeInput(session, 'size', choices = mgp,
                             selected = pick(d$size, mgp), server = TRUE)
        updateSelectizeInput(session, 'cohort', choices = c('all', b$mycohorts),
                             selected = NULL, server = TRUE)
        updateSelectizeInput(session, 'facet', choices = mgp,
                             selected = NULL, server = TRUE)
    }
    apply_bundle_choices(init_bundle)

    ## switching datasets: rebuild the bundle (new connection + choice lists)
    ## and repopulate all inputs from it.
    observeEvent(input$dataset, {
        req(input$dataset)
        if (identical(input$dataset, bundle()$name)) return()
        b = load_dataset_bundle(input$dataset)
        bundle(b)
        apply_bundle_choices(b)
    }, ignoreInit = TRUE)

    ## when multi_y is toggled on, add "probe" to color choices and select it
    observeEvent(input$multi_y, {
        mgp = bundle()$mygenesplus
        stc = bundle()$roles$sampletype_col
        if (input$multi_y) {
            updateSelectizeInput(session, 'color', choices = c('probe', mgp),
                                 selected = 'probe', server = TRUE)
        } else {
            updateSelectizeInput(session, 'color', choices = mgp,
                                 selected = if (!is.null(stc) && !is.na(stc)) stc else "",
                                 server = TRUE)
        }
    }, ignoreInit = TRUE)

    ## ---- Thanos: one instance per dataset, started on first use ----
    ## A Thanos instance is bound to one backend (= one dataset) for life, so
    ## each dataset gets its own; switching datasets swaps which one is shown
    ## and consulted. A filter set up for one dataset can therefore never be
    ## applied to another whose fields may not even exist.
    th_env = new.env(parent = emptyenv())
    th_for = function(b) {
        if (!HAVE_THANOS || !(b$name %in% T2_DATASETS)) return(NULL)
        if (!is.null(th_env[[b$name]])) return(th_env[[b$name]])
        be = backend_t2_shared(b)
        ds = b$name
        ## the Select tab's pre-filters as this instance's universe; NULL (no
        ## restriction, nothing to recompute) while another dataset is active
        base = reactive({
            if (!identical(bundle()$name, ds)) return(NULL)
            be$base_mask(cohort   = .t2_pick(input$cohort, c('all', unname(b$mycohorts)), 200),
                         nonormal = .t2_flag(input$nonormal),
                         noheme   = .t2_flag(input$noheme))
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
        v = c(cap(input$x, T2_LIMITS$x_vars), cap(input$y, T2_LIMITS$y_vars),
              cap(input$color, 1), cap(input$size, 1), cap(input$facet, T2_LIMITS$facet_vars),
              if (!identical(input$pcortype, 'none')) cap(input$condition, T2_LIMITS$condition_vars))
        list(dataset = bundle()$name, vars = unique(v[!is.na(v) & nzchar(v)]))
    })
    selected_vars_d = debounce(selected_vars, 500)
    observeEvent(selected_vars_d(), {
        sv = selected_vars_d()
        b = bundle()
        if (!identical(sv$dataset, b$name)) return()
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
    filter_state = function(b) {
        h = th_for(b)
        if (is.null(h)) return(list(keep = NULL, note = NULL))
        m = h$th$mask()
        base = h$base()
        base = if (is.null(base)) rep(TRUE, length(m)) else (base & !is.na(base))
        active = t2_describe_filters(h$th$filters(), h$backend)
        if (identical(m, base)) {
            return(list(keep = NULL,
                        note = sprintf("Filter tab: no additional filtering (%d samples).", sum(m))))
        }
        list(keep = h$backend$samples[m],
             note = sprintf("Filter tab: %d of %d samples pass. %s", sum(m), sum(base),
                            if (length(active)) paste0("Active filters: ", paste(active, collapse = "; "), ".")
                            else "Samples with missing values (NA) are excluded for at least one variable."))
    }

    ## live count next to the Filter tab's Plot button
    output$filter_count = renderText({
        h = th_for(bundle())
        if (is.null(h)) return("")
        base = h$base()
        n_base = if (is.null(base)) h$backend$n_rows() else sum(base, na.rm = TRUE)
        sprintf("%s of %s samples selected", format(h$th$n_selected(), big.mark = ","),
                format(n_base, big.mark = ","))
    })

    ## ---- Appearance: one widget per extra ggplot setting picked in the search box ----
    ## Rebuilt when the pick list changes; a widget that already exists keeps
    ## its current value. What these widgets send is validated against the
    ## registry in sanitize_t2_tweaks() before anything reaches ggplot.
    output$tweak_inputs = renderUI(tweak_widgets(input))

    ## ---- plotting: any of the three Plot buttons ----
    plot_clicks = reactive(sum(input$plot_btn, input$plot_btn2, input$plot_btn3))
    ## the plot's height on the page is, like every Appearance setting, taken at
    ## the moment Plot is pressed
    plot_height = reactiveVal(t2_style_default('plot_height'))
    observeEvent(plot_clicks(), {
        plot_height(.t2_num(input$plot_height, T2_STYLE$plot_height$choices,
                            t2_style_default('plot_height')))
    })
    ## what the last plot was drawn from; the download hands out the same table
    plot_snapshot = NULL
    plot_result = eventReactive(plot_clicks(), {
        ## nothing is drawn until a Plot button has been pressed
        req(plot_clicks() > 0)
        b = bundle()
        ## whitelist + validate every input before it reaches the plotter/SQL
        inp = sanitize_t2_input(input, b)
        if( length(inp$x) == 0 | length(inp$y) == 0 ) { return( NULL ) }
        fs = filter_state(b)
        gg = sanitize_t2_tweaks(input)
        plot_snapshot <<- list(inp = inp, b = b, keep = fs$keep, note = fs$note, gg = gg)
        withProgress(message = 'Working...', value = 0, {
            incProgress(0.20, message = "Plotting")
            fun_plot1(inp, reactive = FALSE, dbfile = b$path, roles = b$roles, dataset_label = b$label,
                      keep_samples = fs$keep, gg = gg)
        })
    })
    ## pressing Plot anywhere shows the result
    observeEvent(input$plot_btn,  updateTabsetPanel(session, 'tabs', selected = 'plot'))
    observeEvent(input$plot_btn2, updateTabsetPanel(session, 'tabs', selected = 'plot'))
    observeEvent(input$plot_btn3, updateTabsetPanel(session, 'tabs', selected = 'plot'))

    output$main_plot = renderPlot({
        res = plot_result()
        if (is.null(res)) return(NULL)
        if (is.list(res) && !is.null(res$warning)) {
            showNotification(res$warning, type = "warning", duration = 10)
            if (is.null(res$plot)) return(NULL)
        }
        ## Survival mode returns a ggsurvplot (a list with $plot + $table); print
        ## the whole object so the risk table renders too, not just the curve.
        if (inherits(res, "ggsurvplot")) return(res)
        if (is.list(res) && !is.null(res$plot)) res$plot else res
    })
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
        for (id in names(pr$style)) updateSelectInput(session, paste0('pub_', id), selected = pr$style[[id]])
    }, ignoreInit = TRUE)
    output$pub_tweak_inputs = renderUI(tweak_widgets(input, "pub_", pub_preset()$gg))

    pub_fig = reactive(sanitize_t2_figure(input))
    ## everything that decides what is drawn (not how large the file is)
    pub_spec = reactive({
        b = bundle()
        inp = sanitize_t2_input(input, b)
        if (length(inp$x) == 0 || length(inp$y) == 0) return(NULL)
        fig = pub_fig()
        pr = T2_FIG_PRESETS[[fig$preset]]
        st = sanitize_t2_style(input, "pub_", pr$style)
        st$plot_height = NULL
        inp[names(st)] = st
        ## the preset's own defaults for unlisted settings, then the user's picks
        gg = utils::modifyList(pr$gg, sanitize_t2_tweaks(input, "pub_"))
        list(b = b, inp = inp, keep = filter_state(b)$keep, gg = gg,
             base_size = fig$base_size, family = fig$family, fig_width = fig$width,
             caption = if (fig$source_line) T2_CITATION else "")
    })
    pub_draw = function(s) {
        fun_plot1(s$inp, reactive = FALSE, dbfile = s$b$path, roles = s$b$roles,
                  dataset_label = s$b$label, keep_samples = s$keep, gg = s$gg,
                  base_size = s$base_size, base_family = s$family, caption = s$caption,
                  fig_width = s$fig_width)
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

    output$datatypes = renderUI({
        b = bundle()
        type_con = RSQLite::dbConnect(RSQLite::SQLite(), b$path, flags = RSQLite::SQLITE_RO)
        on.exit(DBI::dbDisconnect(type_con), add = TRUE)
        ## description columns are optional; fall back to a bare type list
        type_df = tryCatch(
            DBI::dbGetQuery(type_con, "SELECT type, description, example, reference, source_file, source_url FROM types ORDER BY type"),
            error = function(e) {
                tdf = DBI::dbGetQuery(type_con, "SELECT type FROM types ORDER BY type")
                tdf$description = ""; tdf$example = ""; tdf$reference = ""
                tdf$source_file = ""; tdf$source_url = ""
                tdf
            })
        ## convert PMID references to clickable PubMed links
        type_df$reference = sapply(type_df$reference, function(ref) {
            pmid = regmatches(ref, regexpr("PMID:\\d+", ref))
            if (length(pmid) > 0) {
                pmid_num = sub("PMID:", "", pmid)
                url = paste0("https://pubmed.ncbi.nlm.nih.gov/", pmid_num)
                sub(pmid, paste0('<a href="', url, '" target="_blank">', pmid, '</a>'), ref, fixed = TRUE)
            } else ref
        })
        ## make source_url clickable
        type_df$source_link = sapply(type_df$source_url, function(url) {
            if (!is.na(url) && url != "") paste0('<a href="', url, '" target="_blank">Xena</a>')
            else ""
        })
        header = tags$tr(
            tags$th("Type"), tags$th("Description"),
            tags$th("Example Probes"), tags$th("Source File"),
            tags$th("Reference"), tags$th("Data")
        )
        rows = lapply(seq_len(nrow(type_df)), function(i) {
            tags$tr(
                tags$td(tags$code(type_df$type[i])),
                tags$td(type_df$description[i]),
                tags$td(tags$code(type_df$example[i])),
                tags$td(tags$small(type_df$source_file[i])),
                tags$td(HTML(type_df$reference[i])),
                tags$td(HTML(type_df$source_link[i]))
            )
        })
        ## Survival endpoints are clinical columns (not `types` rows), so note
        ## them explicitly: selecting one as X switches to time-to-event analysis.
        survival_note <- tags$div(
            style = "margin-top: 16px; padding: 12px 16px; border-left: 4px solid #3B7DB4; background: #f6f8fa; font-size: 90%;",
            tags$b("Survival endpoints — time-to-event analysis (Kaplan–Meier + Cox)"),
            tags$p(style = "margin: 6px 0 4px",
                "Select ", tags$code("OS"), " (Overall Survival), ", tags$code("PFI"),
                " (Progression-Free Interval), ", tags$code("DSS"),
                " (Disease-Specific Survival), or ", tags$code("DFI"),
                " (Disease-Free Interval) as the ", tags$b("Gene (X)"),
                " variable to switch from a scatter plot to a ", tags$b("Kaplan–Meier"),
                " survival plot: the ", tags$b("Gene (Y)"),
                " marker is split into tertiles (Low / Mid / High), with shaded confidence bands, ",
                "median survival per tertile, and the ", tags$b("log-rank"), " p-value plus a ",
                tags$b("Cox proportional-hazards"), " hazard ratio (per 1 SD, with 95% CI) embedded in the plot. ",
                "Faceting via ", tags$b("“Graph for each”"), " produces a grid of per-group KM plots."),
            tags$p(style = "margin: 2px 0 0; color: #666",
                "Each endpoint pairs an event indicator (1 = event, 0 = censored) with its time in days ",
                "(", tags$code("OS.time"), ", ", tags$code("PFI.time"), ", ",
                tags$code("DSS.time"), ", ", tags$code("DFI.time"), "). Source: Liu ",
                tags$i("et al."), " 2018, ",
                tags$i("An Integrated TCGA Pan-Cancer Clinical Data Resource"),
                " (Cell 173:400–416, ",
                tags$a(href = "https://pubmed.ncbi.nlm.nih.gov/29625055", target = "_blank", "PMID:29625055"),
                ").")
        )
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
    ## the table behind the last plot (same dataset, variables and samples);
    ## before any plot, the table for the current selections
    output$downloadData = downloadHandler(
        filename = "csvdownload.csv",
        content = function(file) {
            snap = plot_snapshot
            if (is.null(snap)) {
                b = bundle()
                snap = list(inp = sanitize_t2_input(input, b), b = b,
                            keep = isolate(filter_state(b))$keep)
            }
            write.csv(fun_table1(snap$inp, dbfile = snap$b$path, roles = snap$b$roles,
                                 keep_samples = snap$keep), file)
        })
    output$print1 = renderPrint({
        print( str( reactiveValuesToList(input) ) )
    })
}

shinyApp(ui = ui, server = server)
