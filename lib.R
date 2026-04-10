#' # tidy tcga database
#' ## Nathan Siemers

library(sqldf)
library(ggplot2); library(ggthemes)
library(viridis)
library(tidyverse)
source('gitr.R')
################################################################
## database connections and convenience lists

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
clin = tbl(con, 'clinpheno')
mygenesplus = c( 'subtype', 'cohort', mygenes, 'sample_type')

################################################################
## make a plotter function
################################################################
interactive_plotter = function(...) { plotter( ..., static.strip = 0.5, static.size = 0.1, static.labels = 0.05, static.titles = 0.05) }


plotter = function( x, y = NULL, color = NULL, shape = NULL, size = NULL, facet = NULL, nonormal = TRUE,
    cohort = 'all', extra = NULL,  facet.formula = NULL, smooth = FALSE, allComplete = FALSE,
    alpha = 0.4, static.size = 0.25, scales = 'fixed', ncols = 12, halfmutants = FALSE,
    static.labels = 0.25, static.strip = 0.5, static.titles = 0.25, coordflip = FALSE, evaluate_vars = FALSE,
    condition = NULL, waterfall = FALSE, waterfall_flip = FALSE, noheme = FALSE, pcortype = 'none',
    multi_y = FALSE, zscore_y = FALSE, ...
                   ) {
    ################################################################
    ## THEMES and ggplot geom defaults
    theme_set(theme_gdocs() + theme(
        text = element_text(colour = "black"),
        legend.title = element_text(colour="black", size=14 ),
        legend.text = element_text(colour="black", size=14 ),
        panel.background = element_rect(fill = "white")
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
    if( x[1] == 'cohort' ) static.size = static.size / 4
    if( ! is.null(facet)[1] )  static.size = static.size / 4
    ## retrieve tcga data  HELP
    ##list.of.markers = sapply( c( x, y, color, shape, size, facet, c(extra) ), as.name)
    ## only include conditioning variables if actually being used
    active_condition = if (!is.null(condition) && pcortype != 'none') condition else NULL
    list.of.markers = c( x, y, color, shape, size, c(facet), c(extra), c(active_condition)  )
    ## save original parameter values before transformations
    orig_x = x; orig_y = y; orig_color = color; orig_shape = shape
    orig_size = size; orig_facet = facet; orig_condition = condition
    data = gitr(list.of.markers, db = db, cohort = cohort, nonormal = nonormal, noheme = noheme)

    ## build data summary before any transformations
    summary_lines = c()
    summary_lines = c(summary_lines, sprintf("Total samples after filters: %d", nrow(data)))
    ## per-variable completeness
    all_vars = unique(c(x, y, color, shape, size, facet, active_condition))
    all_vars = all_vars[!is.null(all_vars) & all_vars != "" & all_vars %in% colnames(data)]
    var_counts = sapply(all_vars, function(v) {
        if (v %in% colnames(data)) sum(!is.na(data[, v])) else NA
    })
    summary_lines = c(summary_lines, "", "Samples with data per variable:")
    for (i in seq_along(all_vars)) {
        vname = all_vars[i]
        n = var_counts[i]
        pct = if (!is.na(n)) sprintf("%.1f%%", 100 * n / nrow(data)) else "not found"
        summary_lines = c(summary_lines, sprintf("  %-35s %6s / %d  (%s)",
                                                  vname, ifelse(is.na(n), "?", n), nrow(data), pct))
    }
    ## intersection: samples with non-NA for all plotted variables (x + y at minimum)
    plot_vars = unique(c(x, y))
    plot_vars = plot_vars[plot_vars %in% colnames(data)]
    if (length(plot_vars) > 0) {
        complete_xy = complete.cases(data[, plot_vars, drop = FALSE])
        n_complete = sum(complete_xy)
        n_missing = nrow(data) - n_complete
        summary_lines = c(summary_lines, "",
            sprintf("Samples with data for both X and Y: %d / %d", n_complete, nrow(data)),
            sprintf("Samples missing X and/or Y:         %d", n_missing))
    }
    ## all aesthetic variables
    all_aes_vars = unique(c(x, y, color, size, facet))
    all_aes_vars = all_aes_vars[!is.null(all_aes_vars) & all_aes_vars != "" & all_aes_vars %in% colnames(data)]
    if (length(all_aes_vars) > length(plot_vars)) {
        complete_all = sum(complete.cases(data[, all_aes_vars, drop = FALSE]))
        summary_lines = c(summary_lines,
            sprintf("Samples with all graph variables:    %d / %d", complete_all, nrow(data)))
    }
    plot_summary = paste(summary_lines, collapse = "\n")

    ################################################################
    ## input validation — collect warnings, don't error
    warnings = c()

    ## helpers
    is_num = function(v) length(v) == 1 && v %in% colnames(data) && is.numeric(data[, v])
    var_type = function(v) {
        if (!(v %in% colnames(data))) return("not found")
        col = data[, v]
        if (is.numeric(col)) "numeric"
        else if (is.factor(col)) "factor"
        else if (is.character(col)) "character"
        else class(col)[1]
    }
    label_vars = function(vars) paste(sprintf("%s (%s)", vars, sapply(vars, var_type)), collapse = ", ")

    ## multiple X probes must all be numeric (they get scaled + medianed)
    if (length(x) > 1) {
        non_num_x = x[!sapply(x, is_num)]
        if (length(non_num_x) > 0) {
            warnings = c(warnings, paste("Multiple X requires all numeric. Dropping:", label_vars(non_num_x)))
            x = setdiff(x, non_num_x)
            if (length(x) == 0) x = orig_x[1]
        }
    }

    ## multiple Y probes (without multi_y) must all be numeric
    if (length(y) > 1 && !multi_y) {
        non_num_y = y[!sapply(y, is_num)]
        if (length(non_num_y) > 0) {
            warnings = c(warnings, paste("Multiple Y (combined) requires all numeric. Dropping:", label_vars(non_num_y)))
            y = setdiff(y, non_num_y)
            if (length(y) == 0) y = orig_y[1]
        }
    }

    ## multi_y with mixed types: warn but proceed (pivot handles it)
    if (length(y) > 1 && multi_y) {
        y_types = sapply(y, var_type)
        if (length(unique(y_types)) > 1) {
            warnings = c(warnings, paste("Multi-Y has mixed types:", label_vars(y),
                                         "- results may be unexpected"))
        }
    }

    ## facet variables must be categorical — numeric facets would create thousands of panels
    if (!is.null(facet[1])) {
        facet_in_data = facet[facet %in% colnames(data)]
        numeric_facets = facet_in_data[sapply(facet_in_data, is_num)]
        if (length(numeric_facets) > 0) {
            warnings = c(warnings, paste("Facet requires categorical variables. Removing:", label_vars(numeric_facets)))
            facet = setdiff(facet, numeric_facets)
            if (length(facet) == 0) facet = NULL
        }
    }

    ## conditioning validation
    conditioning_msg = NULL
    if (!is.null(condition) && pcortype != 'none') {
        cond_numeric = sapply(condition, is_num)
        non_numeric_cond = condition[!cond_numeric]
        problems = c()
        if (length(non_numeric_cond) > 0)
            problems = c(problems, paste("Conditioning variables not numeric:", label_vars(non_numeric_cond)))
        if ((pcortype == 'x' | pcortype == 'both') && !is_num(x))
            problems = c(problems, sprintf("Cannot condition on X: %s (%s)", x, var_type(x)))
        if ((pcortype == 'y' | pcortype == 'both') && !is_num(y))
            problems = c(problems, sprintf("Cannot condition on Y: %s (%s)", y, var_type(y)))
        if (length(problems) > 0) {
            conditioning_msg = paste("Conditioning skipped:", paste(problems, collapse = "; "))
            warnings = c(warnings, conditioning_msg)
        }
    }

    if ( length(unique( data [ , color ] ) ) < 2 ) { color = NULL }
    if ( length(unique( data [ , size ] ) ) < 2 ) { size = NULL }
    if(length(x) > 1) {
        newvar = paste(x, sep = '.', collapse = '.')
        data[ , newvar]  = data %>%
            select( x ) %>%
                scale %>%
                    apply( 1, median, na.rm = TRUE )
        x = newvar
        ##x = paste(x, sep = '.', collapse = '.')
    }
    ## z-score Y probes if requested (useful for putting different-magnitude probes on same scale)
    if (zscore_y) {
        y_numeric = y[sapply(y, function(v) is.numeric(data[, v]))]
        if (length(y_numeric) > 0) {
            data[, y_numeric] = scale(data[, y_numeric])
        }
    }
    if(length(y) > 1 && !multi_y) {
        newvar = paste(y, sep = '.', collapse = '.')
        data[ , newvar] = data %>%
            select( y ) %>%
                scale %>%
                    apply( 1, median, na.rm = TRUE )
        y = newvar
    }
    multi_y_fill = FALSE
    if(length(y) > 1 && multi_y) {
        ## pivot multiple Y probes to long format for individual plotting
        y_probes = y
        ## drop any existing 'probe' column to avoid name collision in pivot
        data$probe = NULL
        data = as.data.frame(tidyr::pivot_longer(data, cols = all_of(y_probes),
                                   names_to = "probe", values_to = "y_value"),
                             check.names = FALSE)
        data$probe = factor(data$probe, levels = y_probes)
        y = "y_value"
        if (!is.null(color) && color != "" && color != "probe") {
            ## user has a different color variable — facet by probe, fill boxes by probe
            multi_y_fill = TRUE
            facet = c("probe", facet)
            facet = facet[!is.null(facet) & facet != ""]
        } else {
            ## color by probe identity, no auto-faceting
            color = "probe"
        }
    }
    ## will we need to remove NAs from X and possibly Y? ggplot might take care of it
    if( allComplete ) {
        data = data[ complete.cases( data[ , c("sample","cohort", "sample_type",x,y,color,size, c(facet))] ), ]
    }
    data = droplevels(data)
    if ( nrow(data) == 0 | is.null(data[,x]) | is.null(data[, y]) ) {
        return( list(
            plot = ggplot() + ggtitle("Sorry, there seems to be no data associated with your query",
                subtitle = "Hint: some of the subtype classifications are only applied across some tumor samples, some mutations aren't present, etc" ),
            summary = plot_summary
        ))
    }
    ##if ( nrow(data) != 0 & is.factor( data[ , x] ) & length(levels( data[ , x] )) < 1 )  {
    ##    return( ggplot() + ggtitle("Sorry, your x variable seems to be categorical and there seems to be less than two categories to plot") )
    ##}
    ## I really need to deal with formulae generally
    if( evaluate_vars ) {
        list.of.markersxy = unlist(strsplit( c(x,y), split = " " ))
        list.of.markersxy = list.of.markersxy[! list.of.markersxy  %in% c('+', '-')]
    } else {
        list.of.markersxy = c(x,y)
    }

    ################################################################
    ## apply conditioning (only if validation passed)
    if (!is.null(condition) & pcortype != 'none' & is.null(conditioning_msg)) {
        data = data[ complete.cases( data[ , c(x,y,condition) ] ), ]
        if( pcortype == 'y' | pcortype == 'both') {
            smalldat = data[ , colnames(data) %in% c(y, condition) ]
            theformula = as.formula(paste(y, " ~ .  - ", y))
            resid = residuals( lm( theformula, data = smalldat ) )
            data[, y] = resid
        }
        if( pcortype == 'x' | pcortype == 'both') {
            smalldat = data[ , colnames(data) %in% c(x, condition) ]
            theformula = as.formula(paste(x, " ~ .  - ", x))
            resid = residuals( lm( theformula, data = smalldat ) )
            data[, x] = resid
        }
    }
    ## check for waterfall
    if(waterfall){
      data[,x] = forcats::fct_reorder(data[,x],data[,y], .desc = waterfall_flip)
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
        if( grepl( '\\.mut$', xx[1] ) ) {
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
    if(!is.null(facet[1])) {
        psub = paste0(psub, " Graphs: ", paste(facet, collapse = ' + '), '.' )
    }
    if(!is.null(facet.formula)) {
        psub = paste(psub, "Graphs:", as.character(facet.formula ) )
    }

    aesx = aes_q( x = as.name(x) )

    if( is.null(y[1]) ) {
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
    if( !is.null(cohort[1]) ) {
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
    if (! is.null(condition)  & pcortype != 'none' & is.null(conditioning_msg)) {
        pstring2 = paste(pstring2, '   \n', "Conditioning:",  paste(condition, collapse = ','), 'on', pcortype )
    }
    ## create full aesthetics
    aesfull = modifyList( aesx, c(aesy, aescolor, aesshape, aessize) )
    p = ggplot( mapping = aesfull, data = data)
    if( ! grepl('\\+|\\-', x[1] ) ) {
        if(   is.factor(data[, x])  ) {
            ## boxplot + jittered points for categorical x
            if (multi_y_fill) {
                ## multi_y with user color: fill boxplots by probe, color points by user's variable
                box_aes = aes(fill = probe)
                if(! is.null(size))  {
                    p = p + geom_boxplot(box_aes, outlier.shape = NA, alpha = 0.3) +
                        geom_point(position = position_jitterdodge(jitter.width = 0.2), alpha = alpha)
                } else {
                    p = p + geom_boxplot(box_aes, outlier.shape = NA, alpha = 0.3) +
                        geom_point(position = position_jitterdodge(jitter.width = 0.2), alpha = alpha, size = static.size)
                }
            } else if(! is.null(size))  {
                if(is.null(color)) {
                    p = p + geom_boxplot(outlier.shape = NA) + geom_point(position = position_jitter(width = 0.2), alpha = alpha)
                } else {
                    p = p + geom_boxplot(outlier.shape = NA) + geom_point(position = position_jitterdodge(jitter.width = 0.2), alpha = alpha)
                }
            } else {
                if(is.null(color)){
                    p = p + geom_boxplot( outlier.shape = NA) + geom_point(position = position_jitter(width = 0.2), alpha = alpha, size = static.size)
                } else {
                    p = p + geom_boxplot( outlier.shape = NA) + geom_point(position = position_jitterdodge(jitter.width = 0.2), alpha = alpha, size = static.size)
                }
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
    if(  !is.null(facet[1])  ) {
        my.formula = as.formula(paste( '~', paste(facet, collapse = ' + ' ) ))
        ## when x is categorical, upgrade to free_x so each panel drops empty levels
        facet_scales = scales
        if (is.factor(data[, x]) && facet_scales == 'fixed') facet_scales = 'free_x'
        if (is.factor(data[, x]) && facet_scales == 'free_y') facet_scales = 'free'
        p = p + facet_wrap(  my.formula, scales = facet_scales, ncol = ncols, drop = TRUE ) + theme(strip.text = element_text(size = round(60 * static.strip, digits = 0 ) ) )
        if (is.factor(data[, x])) p = p + scale_x_discrete(drop = TRUE)
        if (!is.null(y) && is.factor(data[, y])) p = p + scale_y_discrete(drop = TRUE)
    }
    if(  !is.null(facet.formula)  ) {
        my.formula = paste( '~', facet.formula)
        p = p + facet_wrap(  as.formula(my.formula), ncol = ncols, scales = scales, drop = TRUE  ) + theme(strip.text = element_text(size = 60 * static.strip) )
        if (is.factor(data[, x])) p = p + scale_x_discrete(drop = TRUE)
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
    } else {
        p = p + viridis::scale_color_viridis(end = 0.8, discrete = FALSE, option = 'plasma')
    }
    if (multi_y_fill) {
        p = p + viridis::scale_fill_viridis(end = 0.7, discrete = TRUE, option = 'viridis', alpha = 0.3)
    }
    if( coordflip ) {
        p = p + coord_flip()
    }
    p = p + labs(caption = "Nathan Siemers, Ph.D.") +
        theme(plot.caption = element_text(size = 12),
              axis.text.x = element_text(angle = 90, hjust = 1)
              )

    ## add graph parameters and final stats to summary (use original values)
    plot_summary = paste(plot_summary, sprintf("\nData points in plot: %d", nrow(data)), sep = "\n")
    plot_summary = paste0(plot_summary, sprintf("\n\nGraph parameters:"))
    plot_summary = paste0(plot_summary, sprintf("\n  X:     %s", paste(orig_x, collapse = ", ")))
    plot_summary = paste0(plot_summary, sprintf("\n  Y:     %s", paste(orig_y, collapse = ", ")))
    if (!is.null(orig_color) && any(orig_color != ""))
        plot_summary = paste0(plot_summary, sprintf("\n  Color: %s", paste(orig_color, collapse = ", ")))
    if (!is.null(orig_shape) && any(orig_shape != ""))
        plot_summary = paste0(plot_summary, sprintf("\n  Shape: %s", paste(orig_shape, collapse = ", ")))
    if (!is.null(orig_size) && any(orig_size != ""))
        plot_summary = paste0(plot_summary, sprintf("\n  Size:  %s", paste(orig_size, collapse = ", ")))
    if (!is.null(orig_facet[1]))
        plot_summary = paste0(plot_summary, sprintf("\n  Facet: %s", paste(orig_facet, collapse = " + ")))
    if (!is.null(orig_condition) && pcortype != 'none')
        plot_summary = paste0(plot_summary, sprintf("\n  Conditioning: %s on %s", paste(orig_condition, collapse = ", "), pcortype))
    if (multi_y) plot_summary = paste0(plot_summary, "\n  Multi-Y: individual probes plotted separately")
    if (zscore_y) plot_summary = paste0(plot_summary, "\n  Z-score Y: enabled")
    if (length(warnings) > 0)
        plot_summary = paste0(plot_summary, "\n\n  WARNINGS:\n  ",
                              paste(warnings, collapse = "\n  "))

    list(plot = p, summary = plot_summary,
         warning = if (length(warnings) > 0) paste(warnings, collapse = "\n") else NULL)
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
    ## remove empty input variables and names
    input = input[ ! sapply(input, is.null) ]
   input = input[ input != 'none']
    input = input[ input != '']
    input = input[ names(input) != '']
    numeric_vars = c('static.strip', 'static.size', 'static.titles',
        'static.labels', 'ncols', 'alpha')
    input[ which(names(input) %in% numeric_vars) ] = as.numeric( input[ names(input) %in% numeric_vars ] )
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
