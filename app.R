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

## convenience functions
nbsp = function(n) {
    paste( rep( '&nbsp;', n ), collapse = ' ')
}
inline = function (x) {  shiny::tags$div(style="display:inline-block;", x)  }

################################################################
## UI
################################################################

ui = fluidPage(
    theme = shinytheme('flatly'),
    tags$head(tags$style("h6 {font-size: 75%; }")),
    uiOutput('app_title'),
    inline( selectizeInput('dataset', 'Data set', choices = NULL ) ),
    tags$br(),
    inline( selectizeInput('x', 'Gene (X)', choices = NULL, options = list(create=TRUE), multiple = TRUE ) ),
    inline( selectizeInput('y', 'Gene (Y)', choices = NULL, options = list(create=TRUE), multiple = TRUE ) ),
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
    actionButton("plot_btn", "Plot"),
    tags$br(),
    fluidRow(
        column(12, align="center",
               withSpinner( plotOutput( "main_plot", height = '1800px', width = '95%' ),
                           proxy.height = "200px", color = viridis::plasma(1) )
               ) ),
    h4("Data Summary"),
    verbatimTextOutput('plot_summary'),
    h5( paste( 'PI:', a.PI ) ),
    h5( paste('Contributors:', a.credits) ),
    h5( Sys.Date() ),
    downloadButton('downloadData', 'Download Table'),
    h4('Fiddly Options'),
    inline( selectizeInput('scales', 'Multigraph Scales', choices = NULL  ) ),
    inline( selectizeInput('alpha', 'Transparency', choices = NULL  )),
    inline( selectizeInput('static.size', 'Point Size multipier', choices = NULL  ) ),
    inline( selectizeInput('static.strip', 'Multi-Graph Label Size multipier', choices = NULL  ) ),
    inline( selectizeInput('static.titles', 'Top  Title Size', choices = NULL  ) ),
    inline( selectizeInput('static.labels', 'Axis Label Multiplier', choices = NULL  ) ),
    inline( selectizeInput('ncols', 'Multi-graph Columns', choices = NULL  ) ),
    inline( selectizeInput('smooth', 'Fit Line', choices = NULL  ) ),
    checkboxInput("allComplete", "Show only results with complete information:", value = TRUE),
    actionButton("plot_btn2", "Plot"),
    tags$br(),
    h4("Types of TCGA Data Available"),
    htmlOutput('datatypes'),
    tags$br(),tags$br(),
    h5('Below is an area for my notes, you can ignore...'),
    verbatimTextOutput('print1')
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

    plot_result = eventReactive(input$plot_btn | input$plot_btn2, {
        if( length(input$x) == 0 | length(input$y) == 0 ) { return( NULL ) }
        if( input$x[1] == "" | input$y[1] == "" ) { return(NULL) }
        b = bundle()
        withProgress(message = 'Working...', value = 0, {
            incProgress(0.20, message = "Plotting")
            fun_plot1(input, dbfile = b$path, roles = b$roles, dataset_label = b$label)
        })
    })
    output$main_plot = renderPlot({
        res = plot_result()
        if (is.null(res)) return(NULL)
        if (is.list(res) && !is.null(res$warning)) {
            showNotification(res$warning, type = "warning", duration = 10)
        }
        if (is.list(res) && !is.null(res$plot)) res$plot else res
    })
    output$plot_summary = renderText({
        res = plot_result()
        if (is.null(res)) return("")
        if (is.list(res) && !is.null(res$summary)) res$summary else ""
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
        tags$table(
            class = "table table-striped table-condensed",
            style = "font-size: 85%;",
            tags$thead(header),
            tags$tbody(rows)
        )
    })
    output$dlknitr = downloadHandler(
        filename =  function() {
            paste0( input$x, '.', input$y, '.', 'tcgareport.', Sys.Date(),  '.pptx' )
        },
        content = function(file) {
            ofile = file.path( tempdir(), "report.pptx" )
            rmarkdown::render('report.R',
                              intermediates_dir = tempdir(),
                              output_file = ofile,
                              powerpoint_presentation(reference_doc = file.path(getwd(), 'template.pptx') )
                              )
            file.copy( ofile, file, overwrite = TRUE )
        }  )
    output$downloadData = downloadHandler(
        filename = "csvdownload.csv",
        content = function(file) {
            b = bundle()
            write.csv(fun_table1(input, dbfile = b$path, roles = b$roles), file)
        })
    output$print1 = renderPrint({
        print( str( reactiveValuesToList(input) ) )
    })
}

shinyApp(ui = ui, server = server)
