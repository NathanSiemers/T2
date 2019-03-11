#' # tidy tcga database 
#' ## Nathan Siemers

library(sqldf)
library(ggplot2); library(ggthemes)
library(viridis)
##theme_set(theme_economist()+ theme(
theme_set(theme_gdocs() + theme(
##    panel.background = element_rect(fill = '#dddddd'),
    legend.text = element_text(colour="black", size=8 )
                               ) )
## set some geom defaults
## is this really worth the ugliness?
update_geom_defaults("point", list( color = plasma(1), fill = plasma(1)  ) )
update_geom_defaults("ribbon", list( color = plasma(1), fill = plasma(1)  ) )
update_geom_defaults("smooth", list( color = plasma(1), fill = plasma(1),  alpha = 05) )
library(tidyverse)


################################################################
## database connections and convenience lists
db = 'tcga.db'
con <- DBI::dbConnect(RSQLite::SQLite(), dbname = db, flags = SQLITE_RO )
tcga = tbl(con, 'tcga')
tcgacat = tbl(con, 'tcgacat')
samples = pull(tbl(con, 'samples'), sample)
mutationsamples = pull( tbl(con, 'mutationsamples'), sample )
mygenes = pull( tbl(con, 'allprobes') , probe )
probes = pull( tbl(con, 'probes') , probe )
cohorts = tbl(con, 'cohorts')
mycohorts = c( cohorts %>% as_tibble %>% drop_na %>% pull(cohort) )
subtypes = tbl(con, 'subtypes')
mysubtypes = c( "none", subtypes %>% pull(subtype) )
clin = tbl(con, 'clin')
mygenesplus = c( 'subtype', 'cohort', mygenes, 'sample_type')


################################################################
## gitr - data retriever
gitr = function(probes, phenos = TRUE, nonormal = TRUE,
    cohort = 'all',
    makefactors = TRUE,
    db = db  ) {
    probes_orig = probes
    ## a catch-all to retrieve more data than possibly requested
    #probes = unique( c(probes, gsub('\\.[^.]*$', '', probes) ) )
    probes = unique( gsub('\\.[^.]*$', '', probes) ) 
    print(probes)
    out = tcga %>%
        filter(  probe %in% probes ) %>%
            as_tibble %>%
                ## some immune scores are not unique in pancan tables
                ## seems to only be the immune scores
                distinct( sample, probe, type, .keep_all = TRUE ) %>%
                    mutate(subtype = Subtype_Selected, lcohort = cohort, cohort = tumtype)
    ## filter out normals if desired
    if( nonormal )  {
        out = out %>% filter( sample_type != "Solid Tissue Normal" )
    }
    ## include only selected cohorts if desired
    if( !is.null(cohort) ) {
        if ( cohort  != "all"  ) {
            print("filtering by cohort")
            print(dim(out))
            print(paste('Cohort', cohort))
            out = out[ out$cohort %in% cohort, ]
            print(paste(unique( out$tumtype)))
            print(dim(out))
        }
    }
    ## mutate probes
    out$probe = paste(out$probe, out$type, sep = '.')
    out$probe = gsub( "\\.rna$", '', out$probe)
    out = out %>% select( -type ) %>% spread( probe, value )

    outcat = tcgacat %>%
        filter( probe %in% probes & type == 'fmut' ) %>%
            as_tibble %>%
                distinct( sample, probe, type, .keep_all = TRUE )
    outcat$probe = paste(outcat$probe, outcat$type, sep = '.')
    outcat = outcat %>% select ( sample, probe, value ) %>%
        spread( probe, value ) 
    out = out %>% left_join(outcat, by = 'sample')

    ## impute 0 mutation calls
    out = out %>% mutate_at(
        vars( ends_with(".mut") ),
        funs( case_when(
            is.na(.) & sample %in% mutationsamples ~ 0,
            TRUE ~ .  ) )
        )
    out = out %>% mutate_at(
        vars( ends_with(".fmut") ),
        funs( case_when(
            is.na(.) & sample %in% mutationsamples ~ 'wt',
            TRUE ~ .  ) )
        )
    out = out %>% mutate_at(
        vars( ends_with("mutvaf") ),
        funs( case_when(
            is.na(.) & sample %in% mutationsamples ~ 0,
            TRUE ~ .  ) )
        )
    ## make factors
    if( makefactors ) {
        out = out %>% mutate_if(is.character, as.factor)
        out = out %>% mutate_at( dplyr::vars( ends_with('mut') ) , funs(as.factor) )
    }
    print(out)
    out %>% droplevels %>% data.frame(check.names = FALSE)
}

################################################################
## make a plotter function
################################################################

plotter = function( x, y = NULL, color = NULL, shape = NULL, size = NULL, facet = NULL, nonormal = TRUE,
    cohort = 'all', db = tcga, extra = NULL,  facet.formula = NULL, smooth = FALSE,
    alpha = 0.4, static.size = 9, scales = 'fixed', ncols = 12, halfmutants = FALSE,
    static.labels = 10, static.strip = 10, static.titles = 10, coordflip = FALSE, ...
                   ) {
    myargs = as.list(sys.call())
    cat(file = stderr(), paste(names(myargs), myargs, collapse =','), '\n')
    static.labels = as.numeric(static.labels) / 10
    static.strip = as.numeric(static.strip) / 10
    static.titles = as.numeric(static.titles) / 10
    ## SET VARIABLES - INTERACTIVE TESTING ONLY
    if(FALSE){ # for testing
        x = 'CD8A';  y = 'FOXP3'; color = 'blue'; shape = NULL; size = 'FOXP3'; facet = NULL; cohort = NULL; db = tcga; extra = NULL; facet.formula = NULL; smooth = FALSE; alpha = 0.5; static.size = 9; static.strip = 10; static.labels = 10; static.titles = 10
    }
    ## scaling factors depending on faceting
    if(  (is.null(facet) &  is.null(facet.formula) ) ) {
        if( x == 'cohort' ) static.size = static.size / 8
    } else {  static.size = static.size / 4  }
    ## retrieve tcga data
    list.of.markers = c( x, y, color, shape, size, facet, c(extra) )
    print(list.of.markers)
    data = gitr(list.of.markers, db = db, cohort = cohort, nonormal = TRUE)
    cat(file = stderr(), "gitr finished")
    cat(file = stderr(), paste(colnames(data), collapse = ';'))
    ## will need to remove NAs from X and possibly Y.....
    data = droplevels(data[ complete.cases( data[ , c("sample","cohort", "sample_type",x,y,color,shape,facet,size)] ), ])
    ## I really need to deal with formulae generally
    list.of.markersxy = unlist(strsplit( c(x,y), split = " " ))
    print(list.of.markersxy)
    list.of.markersxy = list.of.markersxy[! list.of.markersxy  %in% c('+', '-')]
    print(list.of.markersxy)
    ##data = data %>% filter( complete.cases( data[ , list.of.markersxy] ) )
    if ( !is.null(color) ){
        if( is.numeric(data[ , color ] )  ) {
            color.midpoint = median( data[ , color], na.rm = TRUE )
        }
     } else {
         color.midpoint = 0
     }
    print( head(data) )
    data = droplevels(data)
    ## convert mutations to factors
    ## if( halfmutants ) {
    ##     mutantlevels = c( 0, 0.5, 1 )
    ## } else {
    mutantlevels = c( 0, 1 )
    ##}
    lapply(list.of.markersxy, function(xx) {
         if( grepl( '\\.mut$', xx ) ) {
             print(paste( xx, 'is a mutant'))
             data[ , xx ] <<-  factor( data[ , xx ], levels = mutantlevels )
         }
     })
    print(str(data))
    psub = ""
    if(!is.null(color)) {
        psub = paste(psub, "Color:", color)
        aescolor = aes_string(color = color)
    } else {
        aescolor = aes(color = NULL)
    }
    if(!is.null(shape)) {
        psub = paste(psub, "shape:", shape)
        aesshape = aes_string(shape = shape)
    } else {
        aesshape = aes(shape = NULL)
    }
    if(!is.null(size)) {
        psub = paste(psub, "Size:", size)
        aessize = aes_string(size = size)
    } else {
        aessize = aes(size = NULL)
    }
    if(!is.null(facet)) {
        psub = paste(psub, "Graphs:", facet)
    }
    if(!is.null(facet.formula)) {
        psub = paste(psub, "Graphs:", as.character(facet.formula ) )
    }
    aesx = aes_string( x = x )
    if( is.null(y) ) {
        aesy = aes( y = NULL )
    } else {
        aesy = aes_string( y = y )
    }
    aesxy = modifyList( aesx,aesy )
    psub = paste(psub, "TCGA Pan-Cancer 2018, Nathan Siemers, Translational Medicine.")
    psub = paste(psub, "Data points:", nrow(data) )
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
    ## create full aesthetics
    aesfull = modifyList( aesx, c(aesy, aescolor, aesshape, aessize) )
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
        my.formula = paste( '~', facet)
        p = p + facet_wrap(  my.formula, scales = scales, ncol = ncols ) + theme(strip.text = element_text(size = round(11/static.strip, digits = 0 ) ) ) 
    }
    if(  !is.null(facet.formula)  ) {
        my.formula = paste( '~', facet.formula)
        print(my.formula)
        p = p + facet_wrap(  as.formula(my.formula), ncol = ncols, scales = scales  ) + theme(strip.text = element_text(size = 7/static.strip) )
    }
    if ( !is.null(smooth) ) {
        if ( smooth == 'TRUE' & is.numeric(data[,x]) & is.numeric(data[,y]) ) {
            p = p +
            geom_smooth(aes_string(x = x, y = y, color = color, fill = color), formula = y ~ x, alpha = 0.25, fullrange = FALSE, method = 'lm', inherit.aes = FALSE) +
                geom_quantile(aes_string(x = x, y = y), formula = y ~ x, linetype = 2, color = 'black', quantiles = c(0.5), inherit.aes = FALSE)
            if( ! is.numeric(  data[, color] ) ) {
                ##p = p + scale_fill_gdocs(na.value = 'grey')
                p = p + scale_fill_viridis(end = 0.7, discrete = TRUE, option = 'plasma')
            }
        }
    }
    p = p + ggtitle(  pstring, subtitle = paste(" ", pstring2, '\n ', psub) ) +
                        theme(axis.text = element_text(size = 14 * static.labels ),
                              axis.title = element_text(size = 17 * static.labels ),
                              plot.title = element_text(size = 20 * static.titles),
                              plot.subtitle = element_text(size = 13 * static.titles)
                              )
    if ( is.factor(data[ , color] ) ) {
        p = p + viridis::scale_colour_viridis(end = 0.7, discrete = TRUE, option = 'plasma')
        ##p = p + scale_colour_gdocs(na.value = 'grey')
    } else {
        ##p = p + scale_color_gradient2(low = 'blue', mid = 'grey', high = 'red', midpoint = color.midpoint, na.value = 'steelblue'  )
        ##p = p + viridis::scale_color_viridis(discrete = FALSE, option = 'plasma')
        p = p + viridis::scale_color_viridis(end = 0.8, discrete = FALSE, option = 'plasma')
    }
    if( coordflip ) {
        p = p + coord_flip()
    }
    p
}    


fun_table1 = function ( input ) {
##    my.input = paste ('~', paste(input$x, input$y, input$color,
    ##        input$size, input$facet, input$sep, sep = ' + ' ) ) ) )
    my.input = c( input$x, input$y, input$color, input$size, input$facet )
    gitr( my.input, nonormal = FALSE)
}

################################################################
## make a plotter function wrapper that takes shiny 'input'
## as argument
## main plotter function should be able to deal with NULLs
################################################################
fun_plot1.orig = function(input) {
    input = reactiveValuesToList(input)
    input = input[ input != 'none']
    input = input[ input != '']
    input = input[ names(input) != '']
    print('INPUT')
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

fun_plot1 = function(input) {
    input = shiny::reactiveValuesToList(input) 
    cat(file = stderr(), paste('fun_plot1 input', paste(input, sep = '=', collapse = ',' ) ) )
    ## remove empty input variables and names
    input = input[ input != 'none']
    input = input[ input != '']
    input = input[ names(input) != '']
    cat(file = stderr(), 'CLEANED INPUT', '\n')
    cat(file = stderr(), paste(input) )
    ## transform variables that should be numeric
    numeric_vars = c('static.size', 'static.titles', 'static.labels', 'ncols', 'alpha')
    input[ names(input) %in% numeric_vars ] = as.numeric( input[ names(input) %in% numeric_vars ] )
    print(input)
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
