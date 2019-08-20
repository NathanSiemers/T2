library(shiny)
library(shinythemes)
library(shinycssloaders)
## convenience functions
nbsp = function(n) {
    paste( rep( '&nbsp;', n ), collapse = ' ')
}
inline = function (x) {  shiny::tags$div(style="display:inline-block;", x)  }

shinyUI(
    fluidPage(
        theme = shinytheme('flatly'),
        tags$head(tags$style("h6 {font-size: 75%; }")),
        h4(a.title),
        inline( selectizeInput('x', 'Gene (X)', choices = NULL, options = list(create=TRUE) ) ),
        inline( selectizeInput('y', 'Gene (Y)', choices = NULL, options = list(create=TRUE) ) ),
        inline( selectizeInput('color', 'color', choices = NULL) ),
        inline( selectizeInput('size', 'size', choices = NULL )),
        inline( selectizeInput('cohort', 'Cohort', choices = NULL, multiple = TRUE )),
        ##inline( selectizeInput('nonormal', 'Exclude Non-Tumor', choices = NULL  )),
        inline( selectizeInput('facet', 'Graph for each:', choices = NULL, multiple = TRUE  )),
        inline(HTML(nbsp(5))),
        inline(checkboxInput("coordflip", "Flip X and Y", value = FALSE)),
        inline(checkboxInput("nonormal", "Exclude Non-tumor", value = TRUE)),
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
                   withSpinner( plotOutput( "main_plot", height = '1200px', width = '85%' ),
                               proxy.height = "200px", color = viridis::plasma(1) )
                   ) ),
        h5( paste( 'PI:', a.PI ) ),
        h5( paste('Contributors:', a.credits) ),
        h5( Sys.Date() ),
        downloadButton('downloadData', 'Download Table'),
        ##downloadButton('dlknitr', 'Download Report'),
        h4('Fiddly Options'),
        inline( selectizeInput('fscales', 'Multigraph Scales', choices = NULL  ) ),
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
    )

