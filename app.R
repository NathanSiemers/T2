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

## convenience functions
nbsp = function(n) {
    paste( rep( '&nbsp;', n ), collapse = ' ')
}
inline = function (x) {  shiny::tags$div(style="display:inline-block;", x)  }

################################################################
## UI
################################################################

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
    theme = shinytheme('flatly'),
    tags$head(tags$style(HTML("
        h6 {font-size: 75%; }
        /* Filter tab: lay the Thanos panels out as a responsive grid */
        .t2-thanos div[id$='-panels'] { display: grid; gap: 14px 28px;
            grid-template-columns: repeat(auto-fill, minmax(400px, 1fr)); }
        .t2-thanos .thanos-panel { border: 1px solid #dce4ec; border-radius: 4px;
            padding: 10px 12px 4px 12px; background: #fff; }
        .t2-filter-status { font-size: 90%; color: #555; margin: 8px 0; }
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
            fluidRow(
                column(12, align="center",
                       withSpinner( plotOutput( "main_plot", height = '1800px', width = '95%' ),
                                   proxy.height = "200px", color = viridis::plasma(1) )
                       ) ),
            h4("Data Summary"),
            verbatimTextOutput('plot_summary'),
            downloadButton('downloadData', 'Download Table')
        ),
        ## ---- (c) Thanos: fine-tune which samples are plotted ----
        tabPanel("Filter", value = "filter", filter_tab_ui()),
        ## ---- (d) plot appearance ----
        tabPanel("Appearance", value = "appearance",
            h4('Fiddly Options'),
            inline( selectizeInput('scales', 'Multigraph Scales', choices = NULL  ) ),
            inline( selectizeInput('alpha', 'Transparency', choices = NULL  )),
            inline( selectizeInput('static.size', 'Point Size multipier', choices = NULL  ) ),
            inline( selectizeInput('static.strip', 'Multi-Graph Label Size multipier', choices = NULL  ) ),
            inline( selectizeInput('static.titles', 'Top  Title Size', choices = NULL  ) ),
            inline( selectizeInput('static.labels', 'Axis Label Multiplier', choices = NULL  ) ),
            inline( selectizeInput('ncols', 'Multi-graph Columns', choices = NULL  ) ),
            inline( selectizeInput('smooth', 'Fit Line', choices = NULL  ) ),
            ## survival (Kaplan-Meier) options — used when X is a time-to-event endpoint
            inline( selectizeInput('km_groups', 'Survival: # groups (Y)', choices = c(2, 3, 4, 5, 6), selected = 3) ),
            inline( numericInput('surv_max_days', 'Survival: max follow-up (days)', value = 365 * 5, min = 30, step = 30) ),
            checkboxInput("allComplete", "Show only results with complete information:", value = TRUE),
            actionButton("plot_btn2", "Plot")
        ),
        ## ---- (e) what this is ----
        tabPanel("About", value = "about",
            h4("About T2"),
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
                        "fit line and survival-plot options.")
            ),
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

    output$app_title = renderUI(h4(bundle()$title))

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

    ## ---- dataset-independent fixed-choice inputs (set once) ----
    updateSelectizeInput(session, 'smooth',  choices = c("TRUE", "FALSE"),
                         selected = 'TRUE', server = TRUE)
    updateSelectizeInput(session, 'scales',  choices = c("free", "fixed", "free_x", "free_y"),
                         selected = 'fixed', server = TRUE)
    updateSelectizeInput(session, 'static.size',  choices = 1:20 / 20,
                         selected = "0.5", server = TRUE)
    updateSelectizeInput(session, 'static.strip',  choices = 1:20 / 20,
                         selected = "0.5", server = TRUE)
    updateSelectizeInput(session, 'static.labels',  choices = 1:20 / 20,
                         selected = "0.6", server = TRUE)
    updateSelectizeInput(session, 'static.titles',  choices = 1:20 / 20,
                         selected = "0.6", server = TRUE)
    updateSelectizeInput(session, 'alpha',  choices = 1:50 / 50,
                         selected = '0.12', server = TRUE)
    updateSelectizeInput(session, 'ncols',  choices = 1:50,
                         selected = 8, server = TRUE)
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
        v = c(input$x, input$y, input$color, input$size, input$facet,
              if (!identical(input$pcortype, 'none')) input$condition)
        v = as.character(unlist(v))
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

    ## ---- plotting: any of the three Plot buttons ----
    plot_clicks = reactive(sum(input$plot_btn, input$plot_btn2, input$plot_btn3))
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
        plot_snapshot <<- list(inp = inp, b = b, keep = fs$keep, note = fs$note)
        withProgress(message = 'Working...', value = 0, {
            incProgress(0.20, message = "Plotting")
            fun_plot1(inp, reactive = FALSE, dbfile = b$path, roles = b$roles, dataset_label = b$label,
                      keep_samples = fs$keep)
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
