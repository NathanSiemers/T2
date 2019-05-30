#' # tidy tcga database 
#' ## Nathan Siemers

library(sqldf)
library(ggplot2); library(ggthemes)
library(viridis)
library(tidyverse)
source('gitr.R')
##source('plotter.R')

##mysql = FALSE
##con = RSQLite::dbConnect(RSQLite::SQLite(), dbname = db, flags = RSQLite::SQLITE_RW )
##db = 'tcga.db'



## con = RMySQL::dbConnect (
##     drv       = RMySQL::MySQL(),
##     dbname    = "pancan2018dev",
##     host      = "pancan2018dev.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
##     port      = 3306,
##     username  = "admin",
##     password  = "Adminuser19")

## mysql = TRUE
## con = RMySQL::dbConnect (
##     drv       = RMySQL::MySQL(),
##     dbname    = "pancan2018",
##     host      = "pancan2018.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
##     port      = 3306,
##     username  = "admin",
##     password  = "Adminuser19")

##install.packages('pool')
##library(pool)
## con <- dbPool(
##   drv = RSQLite::SQLite(),
##   dbname = db
## )
## onStop(function() {
##   poolClose(pool)
## })

################################################################
## database connections and convenience lists
##db = 'tcga.db'

tcga = tbl(con, 'tcga')
tcgacat = tbl(con, 'tcgacat')
samples = pull(tbl(con, 'samples'), sample)
mutationsamples = pull( tbl(con, 'mutationsamples'), sample )
mygenes = pull( tbl(con, 'allprobes') , probe )
probes = pull( tbl(con, 'probes') , probe )
types = tbl(con, 'types')
cohorts = tbl(con, 'cohorts')
mycohorts = pull( cohorts, cohort )
cohortstrings = cohorts %>% pull(cohortstring)
names(mycohorts) = cohortstrings
tcgas = tbl(con, 'tcgas')
tcgai = tbl(con, 'tcgai')
tcgacati = tbl(con, 'tcgacati')
tcgacats = tbl(con, 'tcgacats')
clin = tbl(con, 'clin')
mygenesplus = c( 'subtype', 'cohort', mygenes, 'sample_type')

################################################################
## make a plotter function
################################################################
interactive_plotter = function(...) { plotter( ..., static.strip = 0.5, static.size = 0.1, static.labels = 0.05, static.titles = 0.05) }


plotter = function( x, y = NULL, color = NULL, shape = NULL, size = NULL, facet = NULL, nonormal = TRUE,
    cohort = 'all', extra = NULL,  facet.formula = NULL, smooth = FALSE, allComplete = FALSE,
    alpha = 0.4, static.size = 0.25, scales = 'fixed', ncols = 12, halfmutants = FALSE,
    static.labels = 0.25, static.strip = 0.5, static.titles = 0.25, coordflip = FALSE, evaluate_vars = FALSE,
    condition = NULL, pcortype = 'none', ...
                   ) {
    ################################################################
    ## THEMES and ggplot geom defaults
    theme_set(theme_gdocs() + theme(
        legend.text = element_text(colour="black", size=8 ),
        panel.background = element_rect(fill = "grey97")
        ) )
    update_geom_defaults("point", list( color = plasma(1), fill = plasma(1)  ) )
    update_geom_defaults("ribbon", list( color = plasma(1), fill = plasma(1)  ) )
    update_geom_defaults("smooth", list( color = plasma(1), fill = plasma(1),  alpha = 0.5) )
    ## 
    ##myargs = as.list(match.call())
    ##cat(file = stderr(), paste(names(myargs), myargs, collapse =','), '\n')
    ## SET VARIABLES - INTERACTIVE TESTING ONLY
    if(FALSE){ # for testing
        x = 'CD8A';  y = 'FOXP3'; color = 'blue'; shape = NULL; size = 'FOXP3'; facet = 'KRAS.mut'; cohort = NULL; db = tcga; extra = NULL; facet.formula = NULL; smooth = FALSE; alpha = 0.5; static.size = 9; static.strip = 10; static.labels = 10; static.titles = 10
    }
    ## scaling factors depending on faceting
    static.size = static.size * 30
    if( x == 'cohort' ) static.size = static.size / 4
    if( ! is.null(facet) )  static.size = static.size / 4
    ## retrieve tcga data  HELP
    ##list.of.markers = sapply( c( x, y, color, shape, size, facet, c(extra) ), as.name)
    list.of.markers = c( x, y, color, shape, size, c(facet), c(extra), c(condition)  )
    print(list.of.markers)
    data = gitr(list.of.markers, db = db, cohort = cohort, nonormal = TRUE)
    if ( length(unique( data [ , color ] ) ) < 2 ) { color = NULL }
    if ( length(unique( data [ , size ] ) ) < 2 ) { size = NULL }
    cat(file = stderr(), "gitr finished")
    cat(file = stderr(), paste(colnames(data), collapse = ';')) ; cat('\n')
    ## will we need to remove NAs from X and possibly Y? ggplot might take care of it
    if( allComplete ) {
        data = data[ complete.cases( data[ , c("sample","cohort", "sample_type",x,y,color,size, c(facet))] ), ] 
    }
    data = droplevels(data)
    ## catch plots that would fail
    cat(file = stderr(), 'entereng error checking\n')
    if ( nrow(data) == 0 | is.null(data[,x]) | is.null(data[, y]) ) {
        return( ggplot() + ggtitle("Sorry, there seems to be no data associated with your query", subtitle = "Hint: some of the subtype classifications are only applied across some tumor sample, some mutations aren't present, etc" ) )
    }
    if ( nrow(data) != 0 & is.factor( data[ , x] ) & length(levels( data[ , x] )) < 2 )  {
        return( ggplot() + ggtitle("Sorry, your x variable seems to be categorical and there seems to be less than two categories to plot") )
    }
    cat(file = stderr(), 'end of error checking\n')
    ## I really need to deal with formulae generally
    if( evaluate_vars ) {
        list.of.markersxy = unlist(strsplit( c(x,y), split = " " ))
        print(list.of.markersxy)
        list.of.markersxy = list.of.markersxy[! list.of.markersxy  %in% c('+', '-')]
        print(list.of.markersxy)
    } else {
        list.of.markersxy = c(x,y)
    }

    ################################################################
    ## subtract conditioning variable(s) from x
    ## ## later, will add y as a possibility too.
    if (! is.null(condition)  & pcortype != 'none') {
        ## force complete cases
        data = data[ complete.cases( data[ , c(x,y,condition) ] ), ]
        if( pcortype == 'y' | pcortype == 'both') {
            smalldat = data[ , colnames(data) %in% c(y, condition) ]
            theformula = as.formula(paste(
                y, " ~ .  - ", y
                ))
            resid = residuals( lm( theformula, data = smalldat ) )
            data[, y] = resid
        }
        if( pcortype == 'x' | pcortype == 'both') {
            smalldat = data[ , colnames(data) %in% c(x, condition) ]
            theformula = as.formula(paste(
                x, " ~ .  - ", x
                ))
            resid = residuals( lm( theformula, data = smalldat ) )
            data[, x] = resid
        }
    }
    ################################################################
    ## convert mutations to factors
    ## if( halfmutants ) {
    ##     mutantlevels = c( 0, 0.5, 1 )
    ## } else {
    ## SETTING FACTORS ALSO NEEDS TO BE DEALT WITH GENERALLY
    ## below is just for .mut
    
    mutantlevels = c( 0, 1 )
    lapply(list.of.markersxy, function(xx) {
        if( grepl( '\\.mut$', xx ) ) {
            data[ , xx ] <<-  factor( data[ , xx ], levels = mutantlevels )
        }
    })
    psub = ""
    if(!is.null(color) ) {
        if( color != "") {
            psub = paste(psub, "Color:", color)
            aescolor = aes_q(color = as.name(color) )
            ## there's a weird problem with setting names in color?
            ## below does not fix
            ## aescolor = aes_q(color = color)
        }
    } else {
        aescolor = aes(color = NULL)
    }
    if( !is.null(shape) ) {
        if( shape != "") {
            psub = paste(psub, "shape:", shape)
            aesshape = aes_q(shape = as.name(shape) )
        }
    } else {
        aesshape = aes(shape = NULL)
    }
    if(!is.null(size)) {
        if( size != "") {
            psub = paste(psub, "Size:", size)
            aessize = aes_q(size = as.name(size) )
        }
    } else {
        aessize = aes(size = NULL)
    }
    if(!is.null(facet)) {
        psub = paste0(psub, " Graphs: ", paste(facet, collapse = ' + '), '.' )
    }
    if(!is.null(facet.formula)) {
        psub = paste(psub, "Graphs:", as.character(facet.formula ) )
    }

    aesx = aes_q( x = as.name(x) )

    if( is.null(y) ) {
        aesy = aes( y = NULL )
    } else {
        aesy = aes_q( y = as.name(y) )
    }

    aesxy = modifyList( aesx,aesy )
    psub = paste0(psub, " Data points: ", nrow(data), '.' )
    psub = paste(psub, "TCGA Pan-Cancer 2018.")
    pstring = paste( "Relationship of", x, "and", y, "across TCGA" )
    pstring = gsub( '\\.mut', ' mutation', pstring )
    pstring = gsub( '\\.fmut', ' mutation', pstring )
    pstring = gsub( '\\.cnv', ' CNA', pstring )
    print(paste( 'cohort length:', length(cohort) ))
    print(paste( 'cohort:', cohort))
    if( !is.null(cohort) ) {
        if( length(cohort) < 6) {
            pstring2 = paste( "Cohorts:",
                paste( gsub('_', ' ', cohort), sep = ',', collapse = ', ')
                             )
        } else {
            pstring2 = paste(
                paste( gsub('_', ' ', cohort[1:5] ), sep = ',', collapse = ', ' ),
                '...' )
        }
    } else {
        pstring2 = 'All'
    }
################################################################
    ## add conditioning text
    if (! is.null(condition)  & pcortype != 'none') {
        pstring2 = paste(pstring2, '   \n', "Conditioning:",  paste(condition, collapse = ','), 'on', pcortype )
    }
    ## create full aesthetics
    aesfull = modifyList( aesx, c(aesy, aescolor, aesshape, aessize) )
    print('aesfull')
    print(aesfull)
    p = ggplot( mapping = aesfull, data = data)
    if( ! grepl('\\+|\\-', x ) ) {
        ##        if(   is.factor(data[, x]) | is.factor(data[, y])   ) {
        if(   is.factor(data[, x])   ) {
            ##data[,x] = factor(  data[,x], levels = c(0,1) )
            if(! is.null(size))  {
                p = p + geom_boxplot(mapping = aesxy, inherit.aes = FALSE, outlier.shape = NA) + geom_jitter(width = 0.2, alpha = alpha)
            } else {
                p = p + geom_boxplot(mapping = aesxy, inherit.aes = FALSE, outlier.shape = NA) + geom_jitter(width = 0.2, alpha = alpha, size = static.size)
            }
        } else {
            if(! is.null(size))  {
                p = p + geom_point(alpha = alpha)
            } else {
                p = p + geom_point(alpha = alpha, size = static.size)
            }
        }
    } else {
        if(! is.null(size))  {
            p = p + geom_point(alpha = alpha)
        } else {
            p = p + geom_point(alpha = alpha, size = static.size)
        }
    }
    if(  !is.null(facet)  ) {
        my.formula = as.formula(paste( '~', paste(facet, collapse = ' + ' ) ))
        p = p + facet_wrap(  my.formula, scales = scales, ncol = ncols ) + theme(strip.text = element_text(size = round(60 * static.strip, digits = 0 ) ) )
        print("FACET FORMULA:")
        print(my.formula)
    }
    if(  !is.null(facet.formula)  ) {
        my.formula = paste( '~', facet.formula)
        print(my.formula)
        p = p + facet_wrap(  as.formula(my.formula), ncol = ncols, scales = scales  ) + theme(strip.text = element_text(size = 60 * static.strip) )
    }
    if ( !is.null(smooth) ) {
        if ( smooth == 'TRUE' & is.numeric(data[,x]) & is.numeric(data[,y]) ) {
            p = p +
                ##                geom_smooth(aes_q(x = as.name(x), y = as.name(y), color = as.name(color), fill = color), formula = y ~ x, alpha = 0.25, fullrange = FALSE, method = 'lm', inherit.aes = FALSE) +
                geom_smooth(
                    aes_q(x = as.name(x), y = as.name(y)  ),
                    formula = y ~ x, alpha = 0.25, fullrange = FALSE, method = 'lm', inherit.aes = FALSE) +
                    geom_quantile(aes_string(x = as.name(x), y = as.name(y) ), formula = y ~ x, linetype = 2, color = 'black', quantiles = c(0.5), inherit.aes = FALSE)
            if( ! is.numeric(  data[, color] ) ) {
                ##p = p + scale_fill_gdocs(na.value = 'grey')
                p = p + scale_fill_viridis(end = 0.7, discrete = TRUE, option = 'plasma')
            }
        }
    }
    
    p = p + ggtitle(  pstring, subtitle = paste(" ", pstring2, '\n ', psub) ) +
        theme(axis.text = element_text(size = 14 * 4  * static.labels ),
              axis.title = element_text(size = 14 * 4 * static.labels ),
              plot.title = element_text(size = 22 * 4  * static.titles),
              plot.subtitle = element_text(size = 18 * 4 * static.titles)
              )
    if ( is.factor(data[ , color] ) ) {
        p = p + viridis::scale_colour_viridis(end = 0.7, discrete = TRUE, option = 'plasma')
        ##p = p + scale_colour_gdocs(na.value = 'grey')
    } else {
        p = p + viridis::scale_color_viridis(end = 0.8, discrete = FALSE, option = 'plasma')
    }
    if( coordflip ) {
        p = p + coord_flip()
    }
    p = p + labs(caption = "Nathan Siemers, Translational Medicine") +
        theme(plot.caption = element_text(size = 12) )
    p
}    


fun_table1 = function ( input ) {
    ##    my.input = paste ('~', paste(input$x, input$y, input$color,
    ##        input$size, input$facet, input$sep, sep = ' + ' ) ) ) )
    my.input = c( input$x, input$y, input$color, input$size, input$facet )
    gitr( my.input, nonormal = FALSE)
}


fun_plot1 = function(input, reactive = TRUE) {
    if( reactive ) {
        input = shiny::reactiveValuesToList(input)
    }
    if(FALSE){
    input =   list(x='ABCA1',y='HLA-E',shape = "",size=NULL,color="",static.size="5")
}
    print(str(input))
    ##cat(file = stderr(), paste('fun_plot1 input', paste(names(input), input, sep = '=', collapse = ',' ) ) )
    ## remove empty input variables and names
    input = input[ ! sapply(input, is.null) ]
   input = input[ input != 'none']
    input = input[ input != '']
    input = input[ names(input) != '']
     print(str(input))
    numeric_vars = c('static.strip', 'static.size', 'static.titles',
        'static.labels', 'ncols', 'alpha')
    input[ which(names(input) %in% numeric_vars) ] = as.numeric( input[ names(input) %in% numeric_vars ] )
    print(str(input))
    do.call(plotter, input)
}

if(FALSE) {
    test_plot1 = function(input) {
        input = input[ input != 'none']
        input = input[ input != '']
        print(input)
        ##if( input$cohort[[1]] == 'all' ) input$cohort = mycohorts
        plotter(
            x = input$x,
            y = input$y,
            coordflip = input$coordflip,
            color = input$color,
            shape = input$shape,
            size = input$size,
            static.size = as.numeric(input$static.size),
            static.labels = as.numeric(input$static.labels),
            static.titles = as.numeric(input$static.titles),
            ncols = as.numeric(input$ncols),
            alpha = as.numeric(input$alpha),
            facet = input$facet,
            cohort = input$cohort,
            extra = input$extra,
            facet.formula = input$facet.formula,
            smooth = input$smooth,
            scales = input$fscales, 
            nonormal = input$nonormal   )
    }



    ftest = function(...){
        arglist = as.list(  sys.call()  )
        print(arglist)
        arglist = arglist[names(arglist) != ""]
        arglist = arglist[arglist != ""]
        print(arglist)
    }

    input = list(x = 'CDKN2A', y = 'CD8A')
    do.call(ftest, input)


    input = shiny::isolate(shiny::reactiveValues(x = 'CDKN2B.mut', y = 'CD8A', cohort = "", ncols = "2"))

    input = shiny::isolate(shiny::reactiveValues(
        coordflip = FALSE,
        facet =  'subtype',
        cohort =  NULL,
        static.titles = 13,
        alpha = 0.65,
        static.labels = 14,
        color = 'CD274',
        smooth = TRUE,
        fscales = 'fixed',
        x = 'PIK3CA.mut',
        y = 'CD8A',
        static.strip = 10,
        static.size = 12,
        ncols = 12 ) )
    fun_plot1(input)


}
