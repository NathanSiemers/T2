library(shiny)
library(shinythemes)
library(rmarkdown)
library(DBI)


source("lib.R")


## for testing only
l.input = list(gene1 = 'CDKN2A.cnv', gene2 = 'CD274.cnv', cohort = 'all')

shinyServer (
    function(input, output, session) {
        updateSelectizeInput(session, 'condition',  choices = mygenesplus,
                             selected = c('StromalScore.estimate'), server = TRUE)
        updateSelectizeInput(session, 'x',  choices = mygenesplus,
                             selected = 'PIK3CA.mut', server = TRUE)
        updateSelectizeInput(session, 'y',  choices = mygenesplus,
                             selected = 'CD8A', server = TRUE)
        updateSelectizeInput(session, 'color',  choices = mygenesplus,
                             selected = 'CD274', server = TRUE)
        updateSelectizeInput(session, 'size',  choices = mygenesplus,
                             selected = "", server = TRUE)
        updateSelectizeInput(session, 'cohort',  choices = c('all', mycohorts ),
                             selected = "STAD", server = TRUE)
        updateSelectizeInput(session, 'facet',  choices = mygenesplus,
                             selected = 'subtype', server = TRUE)
        updateSelectizeInput(session, 'smooth',  choices = c("TRUE", "FALSE"),
                             selected = 'TRUE', server = TRUE)
        updateSelectizeInput(session, 'nonormal',  choices = c("TRUE", "FALSE"),
                             selected = 'TRUE', server = TRUE)
        updateSelectizeInput(session, 'fscales',  choices = c("free", "fixed", "free_x", "free_y"),
                             selected = 'fixed', server = TRUE)
        updateSelectizeInput(session, 'static.size',  choices = 1:20 / 20,
                             selected = "0.25", server = TRUE)
        updateSelectizeInput(session, 'static.strip',  choices = 1:20 / 20,
                             selected = "0.25", server = TRUE)
        updateSelectizeInput(session, 'static.labels',  choices = 1:20 / 20,
                             selected = "0.25", server = TRUE)
        updateSelectizeInput(session, 'static.titles',  choices = 1:20 / 20,
                             selected = "0.25", server = TRUE)
        updateSelectizeInput(session, 'alpha',  choices = 1:50 / 50,
                             selected = '0.5', server = TRUE)
        updateSelectizeInput(session, 'ncols',  choices = 1:50,
                             selected = 12, server = TRUE)
        output$main_plot = renderPlot( {
            if( input$x == "" | input$y == "" ) { return(NULL) }
            withProgress(message = 'Working...', value = 0, {
                incProgress(0.20, message = "Plotting")
                fun_plot1(input)
            }
                         )
        })
        output$datatypes = renderTable( {
            types
        })
        ## this needs fixing
        output$dlknitr = downloadHandler(
            ## this is the name of the file the user will see
            ## filename seems set at first render and I can't break the spell
            filename =  function() {
                ## this needs to be a function to evaluate at the right time!
                paste0( input$x, '.', input$y, '.', 'tcgareport.', Sys.Date(),  '.pptx' )
            },
            content = function(file) {
                ## file here is the name of the location
                ## where the output must end up
                ## no matter how simply or not you do it.
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
    })

