library(shiny)
library(shinythemes)
library('shinycssloaders')
##source('global.R')
shinyUI(
    fluidPage(
        theme = shinytheme('flatly'),
        tags$head(tags$style("h6 {font-size: 75%; }")),
        ## put a.title in global.R
        h4(a.title),
        ## put your outputs here
        div(style="display:inline-block;", selectizeInput('x', 'Gene (X)', choices = NULL, options = list(create=TRUE) ) ),
        div(style="display:inline-block;", selectizeInput('y', 'Gene (Y)', choices = NULL, options = list(create=TRUE) ) ),
        div(style="display:inline-block;", selectizeInput('color', 'color', choices = NULL) ),
        ##div(style="display:inline-block;", selectizeInput('shape', 'shape', choices = NULL )),
        div(style="display:inline-block;", selectizeInput('size', 'size', choices = NULL )),
        div(style="display:inline-block;", selectizeInput('cohort', 'Cohort', choices = NULL, multiple = TRUE )),
        div(style="display:inline-block;", selectizeInput('smooth', 'Fit Line', choices = NULL  )),
        ##div(style="display:inline-block;", selectizeInput('nonormal', 'Exclude Non-Tumor', choices = NULL  )),
        div(style="display:inline-block;", selectizeInput('facet', 'Graph for each:', choices = NULL  )),
        tags$br(),
        div(style="display:inline-block;", checkboxInput("coordflip", "Flip X and Y", value = FALSE)),
        submitButton(text = "Plot", icon = NULL, width = NULL),
        tags$br(),
        withSpinner( plotOutput( "main_plot", height = '900px', width = '100%' ),
                    proxy.height = "200px", color = viridis::plasma(1)
                    ),
        ##put a.PI and a.credits in global.R
        h5(  paste( 'PI:', a.PI )  ),
        h5(  paste('Contributors:', a.credits)  ),
        h5( Sys.Date() ),
        tags$br(),
        h4('Fiddly Options'),
        div(style="display:inline-block;", selectizeInput('fscales', 'Multigraph Scales', choices = NULL  )),
        div(style="display:inline-block;", selectizeInput('alpha', 'Transparency', choices = NULL  )),
        div(style="display:inline-block;", selectizeInput('static.size', 'Point Size multipier', choices = NULL  )),
        div(style="display:inline-block;", selectizeInput('static.strip', 'Multi-Graph Title Size multipier', choices = NULL  )),
        div(style="display:inline-block;", selectizeInput('static.titles', 'Top  Title Size multipier', choices = NULL  )),
        div(style="display:inline-block;", selectizeInput('static.labels', 'Axis Label Multiplier', choices = NULL  )),
        div(style="display:inline-block;", selectizeInput('ncols', 'Multi-graph Columns', choices = NULL  )),
        submitButton(text = "Plot", icon = NULL, width = NULL),
        tags$br(),
        h4("Types of TCGA Data available"),
        tableOutput('datatypes'),
        tags$br(),
        downloadButton('dlknitr', 'Download Report'),
        downloadButton('downloadData', 'Download Table'),
        ## downloadButton('downloadData', 'Download Table'),
        tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),
        tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),
        tags$br(),tags$br(),tags$br(),tags$br(),tags$br(),
        h5('Below is an area for my notes, you can ignore...'),
        ## standard stuff, including a debug window
        verbatimTextOutput('print1')
        )
    )

