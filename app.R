## app.R - combined Shiny application
## History from server.R: 5101adc 7e740ec 89e7671 a1e5ea7 4b0a2cb b67ed0d
##   2b0ecd2 3cacb04 f5af0e7 f87110f 245f470 0eb4ca9
## History from ui.R: 5101adc 7552c47 7e740ec 9040bd9 ed9ae38 a1e5ea7
##   4b0a2cb 2809b6f b67ed0d 2b0ecd2 3cacb04 f5af0e7 245f470 0eb4ca9
##   e3ae465 a760cf2

library(shiny)
library(shinythemes)
library(shinycssloaders)
library(rmarkdown)
library(DBI)

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
    h4(a.title),
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
    submitButton(text = "Plot", icon = NULL, width = NULL),
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
    submitButton(text = "Plot", icon = NULL, width = NULL),
    tags$br(),
    h4("Types of TCGA Data available"),
    tableOutput('datatypes'),
    tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),
    h5('Below is an area for my notes, you can ignore...'),
    verbatimTextOutput('print1')
)

################################################################
## Server
################################################################

server = function(input, output, session) {
    updateSelectizeInput(session, 'condition',  choices = mygenesplus,
                         selected = c('StromalScore.estimate'), server = TRUE)
    updateSelectizeInput(session, 'x',  choices = mygenesplus,
                         selected = 'cohort', server = TRUE)
    updateSelectizeInput(session, 'y',  choices = mygenesplus,
                         selected = 'CD8A', server = TRUE)
    updateSelectizeInput(session, 'color',  choices = mygenesplus,
                         selected = 'sample_type', server = TRUE)
    updateSelectizeInput(session, 'size',  choices = mygenesplus,
                         selected = "", server = TRUE)
    updateSelectizeInput(session, 'cohort',  choices = c('all', mycohorts ),
                         selected = NULL, server = TRUE)
    updateSelectizeInput(session, 'facet',  choices = mygenesplus,
                         selected = NULL, server = TRUE)
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
        if (input$multi_y) {
            updateSelectizeInput(session, 'color', choices = c('probe', mygenesplus),
                                 selected = 'probe', server = TRUE)
        } else {
            updateSelectizeInput(session, 'color', choices = mygenesplus,
                                 selected = 'sample_type', server = TRUE)
        }
    }, ignoreInit = TRUE)

    plot_result = reactive({
        if( length(input$x) == 0 | length(input$y) == 0 ) { return( NULL ) }
        if( input$x[1] == "" | input$y[1] == "" ) { return(NULL) }
        withProgress(message = 'Working...', value = 0, {
            incProgress(0.20, message = "Plotting")
            fun_plot1(input)
        })
    })
    output$main_plot = renderPlot({
        res = plot_result()
        if (is.null(res)) return(NULL)
        if (is.list(res) && !is.null(res$plot)) res$plot else res
    })
    output$plot_summary = renderText({
        res = plot_result()
        if (is.null(res)) return("")
        if (is.list(res) && !is.null(res$summary)) res$summary else ""
    })
    output$datatypes = renderTable( {
        types %>% select(type)
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
            write.csv(fun_table1(input), file)
        })
    output$print1 = renderPrint({
        print( str( reactiveValuesToList(input) ) )
    })
}

shinyApp(ui = ui, server = server)
