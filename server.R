library(shiny)
library(shinythemes)
library(rmarkdown)
##library(sqldf)
##library(DT)
##library(plyr)
##library(knitr)
##library(rmarkdown)
source("lib.R")
##library(dplyr)
##library(ggplot2)
##library(ggthemes)

## for testing only
l.input = list(gene1 = 'CDKN2A.cnv', gene2 = 'CD274.cnv', cohort = 'all')

shinyServer (
    function(input, output, session) {
        ##progress <- shiny::Progress$new()
                                        #prog2 <- shiny::Progress$new()
        ##progress$set(message = "Loading all of TCGA", value = 0.5)
        ##on.exit(progress$close())
        updateSelectizeInput(session, 'x',  choices = mygenesplus,
                             selected = 'PIK3CA.mut', server = TRUE)
        updateSelectizeInput(session, 'y',  choices = mygenesplus,
                             selected = 'CD8A', server = TRUE)
        updateSelectizeInput(session, 'color',  choices = mygenesplus,
                             selected = 'CD274', server = TRUE)
        updateSelectizeInput(session, 'size',  choices = mygenesplus,
                             selected = "", server = TRUE)
##        updateSelectizeInput(session, 'shape',  choices = c( 'cohort', 'subtype', mygenesplus ),
##                             selected = NULL, server = TRUE)
        updateSelectizeInput(session, 'cohort',  choices = c('all', mycohorts ),
                             selected = "STAD", server = TRUE)
        ## we don't need mygenesplus for a facet below???
        updateSelectizeInput(session, 'facet',  choices = mygenesplus,
                             selected = 'subtype', server = TRUE)
        updateSelectizeInput(session, 'smooth',  choices = c("TRUE", "FALSE"),
                             selected = 'TRUE', server = TRUE)
        updateSelectizeInput(session, 'nonormal',  choices = c("TRUE", "FALSE"),
                             selected = 'TRUE', server = TRUE)
        updateSelectizeInput(session, 'fscales',  choices = c("free", "fixed", "free_x", "free_y"),
                             selected = 'fixed', server = TRUE)
        updateSelectizeInput(session, 'static.size',  choices = 1:50,
                             selected = 12, server = TRUE)
        updateSelectizeInput(session, 'static.strip',  choices = 1:30,
                             selected = 10, server = TRUE)
        updateSelectizeInput(session, 'static.labels',  choices = 1:30,
                             selected = 14, server = TRUE)
        updateSelectizeInput(session, 'static.titles',  choices = 1:30,
                             selected = 13, server = TRUE)
        updateSelectizeInput(session, 'alpha',  choices = 1:20 / 20,
                             selected = '0.65', server = TRUE)
        updateSelectizeInput(session, 'ncols',  choices = 1:50,
                             selected = 12, server = TRUE)
        output$main_plot = renderPlot( {
            if( input$x == "" | input$y == "" ) { return(NULL) }
            withProgress(message = 'Working...', value = 0, {
                ##use a progress bar to let people know we arent' dead...
                incProgress(0.20, message = "Plotting")
                fun_plot1(input)
            }
                         )
        })
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
                ## not hard to do more complicated things, i.e subset of a table
                write.csv(fun_table1(input), file)
            })
        output$print1 = renderPrint({
            print( str( reactiveValuesToList(input) ) )
        })
    })

