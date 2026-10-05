#' # tidy tcga database
#' ## Nathan Siemers

library(sqldf)
library(ggplot2); library(ggthemes)
library(viridis)
library(tidyverse)
source('gitr.R')
source('dataset_registry.R')
source('marker_ops.R')           # shared: combine_markers_median_z, residualize_on
source('survival_prototype.R')   # Kaplan-Meier survival mode (T2_ENDPOINTS, survival_km)
source('plot_style.R')           # Appearance settings, themes, the ggplot tweak registry
source('figure_export.R')        # Publish tab: figure presets, validation, rendering
################################################################
## Multi-dataset bundle
##
## load_dataset_bundle(name) opens the chosen dataset's db (read-only) and
## computes every dataset-anchored object the app needs: the probe/gene choice
## lists, the cohort list, the clinical role map, the db path, default
## selections, and a display title. The app calls this once at startup and
## again on every dataset switch, then repopulates all selectize inputs from
## the returned bundle. This is the single point that "understands" which
## dataset is active — analogous to LimmaViewer's load_namespace_bundle().
################################################################

load_dataset_bundle = function(name) {
  info  = dataset_info(name)
  roles = info$roles
  con_ds = open_dataset_con(info$path)
  on.exit(DBI::dbDisconnect(con_ds), add = TRUE)   # choice lists are collected; don't leak a handle per switch

  mygenes = pull( tbl(con_ds, 'allprobes'), probe )
  probes  = pull( tbl(con_ds, 'probes'),    probe )
  samples = pull( tbl(con_ds, 'samples'),   sample )
  mutationsamples = tryCatch(pull(tbl(con_ds, 'mutationsamples'), sample),
                             error = function(e) character(0))

  ## cohort choices: prefer the cohorts table (with pretty names); otherwise
  ## derive from the distinct values of the dataset's cohort role column.
  mycohorts = tryCatch({
    co = collect(tbl(con_ds, 'cohorts'))
    v = co$cohort
    if (!is.null(co$cohortstring)) names(v) = co$cohortstring
    v
  }, error = function(e) {
    cc = roles$cohort_col
    if (!is.null(cc) && !is.na(cc)) {
      vals = tryCatch(
        sort(unique(DBI::dbGetQuery(con_ds,
          sprintf('SELECT DISTINCT "%s" AS v FROM clinpheno', cc))$v)),
        error = function(e2) character(0))
      stats::setNames(vals, vals)
    } else character(0)
  })

  ## Selectable variable list: virtual handles (subtype, cohort) + all probes +
  ## the sample-type role column when the dataset has one. Preserves the exact
  ## TCGA ordering: subtype, cohort, <genes>, sample_type.
  pheno_handles = c('subtype', 'cohort')
  tail_handle   = if (!is.null(roles$sampletype_col) && !is.na(roles$sampletype_col))
                    roles$sampletype_col else character(0)
  mygenesplus = c(pheno_handles, mygenes, tail_handle)

  list(
    name = info$name, path = info$path, title = info$title,
    label = info$label, roles = roles, defaults = info$defaults,
    mygenes = mygenes, probes = probes, samples = samples,
    mutationsamples = mutationsamples, mycohorts = mycohorts,
    mygenesplus = mygenesplus
  )
}

################################################################
## database connections and convenience lists (DEFAULT dataset, for startup /
## backward compatibility — the app overrides these per selected dataset).

.default_bundle = load_dataset_bundle(default_dataset())

tcga = tbl(con, 'tcga')
tcgacat = tbl(con, 'tcgacat')
samples = .default_bundle$samples
mutationsamples = .default_bundle$mutationsamples
mygenes = .default_bundle$mygenes
probes = .default_bundle$probes
types = tbl(con, 'types')
cohorts = tbl(con, 'cohorts')
mycohorts = .default_bundle$mycohorts
tcgas = tbl(con, 'tcgas')
tcgai = tbl(con, 'tcgai')
tcgacati = tbl(con, 'tcgacati')
tcgacats = tbl(con, 'tcgacats')
clin = tbl(con, 'clinpheno')
mygenesplus = .default_bundle$mygenesplus

################################################################
## make a plotter function
################################################################
interactive_plotter = function(...) { plotter( ... ) }


plotter = function( x, y = NULL, color = NULL, shape = NULL, size = NULL, facet = NULL, nonormal = TRUE,
    cohort = 'all', extra = NULL,  facet.formula = NULL, smooth = FALSE, allComplete = FALSE,
    alpha = 0.3, point_size = 1.5, scales = 'fixed', ncols = 12, halfmutants = FALSE,
    ## Appearance settings: real ggplot values (font sizes in points; 0 = hide)
    title_size = 16, subtitle_size = 11, axis_title_size = 14, axis_text_size = 11,
    strip_size = 11, legend_size = 11, show_legend = TRUE,
    ## gg: validated extra ggplot settings from the tweak registry (plot_style.R)
    gg = list(),
    ## base_size / base_family: the theme's base font size (spacing, margins and
    ## legend keys follow it) and font; caption: the source line ("" = none)
    ## fig_width: a figure's width in inches; titles are wrapped to fit it
    base_size = 12, base_family = "sans", caption = "Nathan Siemers, Ph.D.", fig_width = NULL,
    coordflip = FALSE, evaluate_vars = FALSE,
    condition = NULL, waterfall = FALSE, waterfall_flip = FALSE, noheme = FALSE, pcortype = 'none',
    multi_y = FALSE, zscore_y = FALSE,
    dbfile = gitrdb, roles = gitr_default_roles,
    dataset_label = "TCGA Pan-Cancer 2018",
    keep_samples = NULL, ...
                   ) {
    ################################################################
    ## THEMES and ggplot geom defaults
    style = list(title_size = title_size, subtitle_size = subtitle_size,
                 axis_title_size = axis_title_size, axis_text_size = axis_text_size,
                 strip_size = strip_size, legend_size = legend_size, show_legend = show_legend,
                 base_size = base_size, base_family = base_family)
    theme_set(do.call(t2_base_theme, style))
    ## an extra ggplot setting if the user chose one, else T2's own default
    G = function(key, default) { v = gg[[key]]; if (is.null(v)) default else v }
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
    ## retrieve tcga data  HELP
    ##list.of.markers = sapply( c( x, y, color, shape, size, facet, c(extra) ), as.name)
    ## only include conditioning variables if actually being used
    active_condition = if (!is.null(condition) && pcortype != 'none') condition else NULL
    list.of.markers = c( x, y, color, shape, size, c(facet), c(extra), c(active_condition)  )
    ## save original parameter values before transformations
    orig_x = x; orig_y = y; orig_color = color; orig_shape = shape
    orig_size = size; orig_facet = facet; orig_condition = condition
    ## keep_samples: the Filter tab's surviving sample ids (NULL = no restriction)
    data = gitr_memo(list.of.markers, cohort = cohort, nonormal = nonormal, noheme = noheme,
                     dbfile = dbfile, roles = roles, keep_samples = keep_samples)

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
        if (length(v) != 1) return(paste(sapply(v, var_type), collapse = ", "))
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

    ## conditioning validation — check each variable individually
    conditioning_msg = NULL
    cond_skip_x = c()  # non-numeric x vars that can't be conditioned
    cond_skip_y = c()  # non-numeric y vars that can't be conditioned
    if (!is.null(condition) && pcortype != 'none') {
        cond_numeric = sapply(condition, is_num)
        non_numeric_cond = condition[!cond_numeric]
        problems = c()
        if (length(non_numeric_cond) > 0) {
            problems = c(problems, paste("Conditioning variables not numeric:", label_vars(non_numeric_cond)))
            conditioning_msg = paste("Conditioning skipped:", paste(problems, collapse = "; "))
            warnings = c(warnings, conditioning_msg)
        } else {
            ## condition vars are numeric — check which x/y vars can be conditioned
            if (pcortype == 'x' | pcortype == 'both') {
                cond_skip_x = x[!sapply(x, is_num)]
                if (length(cond_skip_x) > 0)
                    warnings = c(warnings, paste("Conditioning skipped for non-numeric X:", label_vars(cond_skip_x)))
                if (length(cond_skip_x) == length(x) && (pcortype == 'x'))
                    conditioning_msg = "Conditioning skipped: no numeric X variables"
            }
            if (pcortype == 'y' | pcortype == 'both') {
                cond_skip_y = y[!sapply(y, is_num)]
                if (length(cond_skip_y) > 0)
                    warnings = c(warnings, paste("Conditioning skipped for non-numeric Y:", label_vars(cond_skip_y)))
                if (length(cond_skip_y) == length(y) && (pcortype == 'y'))
                    conditioning_msg = "Conditioning skipped: no numeric Y variables"
            }
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
        ## combine probes into one marker = median of per-probe z-scores (shared)
        data[ , newvar] = combine_markers_median_z(data[ , y])
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
        ## only require completeness on columns that actually exist for this
        ## dataset (sample_type / cohort may be absent in non-TCGA datasets)
        complete_cols = intersect(c("sample", "cohort", "sample_type", x, y, color, size, c(facet)),
                                  colnames(data))
        data = data[ complete.cases( data[ , complete_cols, drop = FALSE] ), ]
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
    ## apply conditioning — individually for each numeric x/y variable
    if (!is.null(condition) & pcortype != 'none' & is.null(conditioning_msg)) {
        ## get numeric vars to condition (excluding skipped non-numerics)
        cond_x_vars = if (pcortype == 'x' | pcortype == 'both') setdiff(x, cond_skip_x) else c()
        cond_y_vars = if (pcortype == 'y' | pcortype == 'both') setdiff(y, cond_skip_y) else c()
        all_cond_vars = unique(c(cond_x_vars, cond_y_vars, condition))
        data = data[ complete.cases( data[ , all_cond_vars ] ), ]
        ## residualize each conditioned var on the covariates (shared helper)
        for (v in c(cond_y_vars, cond_x_vars)) {
            data[, v] = residualize_on( data[, v], data[ , condition, drop = FALSE] )
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
    psub = paste(psub, paste0(dataset_label, "."))
    pstring = paste( "Relationship of", x, "and", y, "across", dataset_label )
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
    ## ---- layers: points (+ boxplots when X is categorical) ----
    ## a mapped size variable overrides the fixed point size; point size 0
    ## draws no points at all
    pt_args = list(alpha = alpha, shape = as.integer(G('point.shape', '19')),
                   stroke = G('point.stroke', 0.5))
    if (is.null(size)) pt_args$size = point_size
    if (is.null(color) && !is.null(gg[['point.colour']])) pt_args$colour = gg[['point.colour']]
    draw_points = !is.null(size) || point_size > 0
    pts = function(position = 'identity') {
        if (draw_points) do.call(geom_point, c(list(position = position), pt_args))
    }
    if( ! grepl('\\+|\\-', x[1] ) && is.factor(data[, x]) ) {
        ## boxplot + jittered points for categorical x
        jw = G('jitter.width', 0.2)
        box_args = list(outlier.shape = NA, linewidth = G('boxplot.linewidth', 0.5),
                        notch = identical(G('boxplot.notch', 'FALSE'), 'TRUE'),
                        varwidth = identical(G('boxplot.varwidth', 'FALSE'), 'TRUE'))
        if (!is.null(gg[['boxplot.width']])) box_args$width = gg[['boxplot.width']]
        if (multi_y_fill) {
            ## multi_y with user color: fill boxplots by probe, color points by user's variable
            p = p + do.call(geom_boxplot, c(list(mapping = aes(fill = probe), alpha = 0.3), box_args)) +
                pts(position_jitterdodge(jitter.width = jw))
        } else {
            p = p + do.call(geom_boxplot, box_args) +
                pts(if (is.null(color)) position_jitter(width = jw)
                    else position_jitterdodge(jitter.width = jw))
        }
    } else {
        p = p + pts()
    }
    if(  !is.null(facet[1])  ) {
        ## facet names are used as symbols, never parsed as R code
        my.formula = vars(!!!rlang::syms(facet))
        ## when x is categorical, upgrade to free_x so each panel drops empty levels
        facet_scales = scales
        if (is.factor(data[, x]) && facet_scales == 'fixed') facet_scales = 'free_x'
        if (is.factor(data[, x]) && facet_scales == 'free_y') facet_scales = 'free'
        p = p + facet_wrap(  my.formula, scales = facet_scales, ncol = ncols, drop = TRUE,
                           strip.position = G('facet.strip.position', 'top'),
                           dir = G('facet.dir', 'h') )
        if (is.factor(data[, x])) p = p + scale_x_discrete(drop = TRUE)
        if (!is.null(y) && is.factor(data[, y])) p = p + scale_y_discrete(drop = TRUE)
    }
    if(  !is.null(facet.formula)  ) {
        my.formula = paste( '~', facet.formula)
        p = p + facet_wrap(  as.formula(my.formula), ncol = ncols, scales = scales, drop = TRUE  )
        if (is.factor(data[, x])) p = p + scale_x_discrete(drop = TRUE)
    }
    pal_option = G('colour.palette', 'plasma')
    pal_dir = as.numeric(G('colour.direction', '1'))
    if ( !is.null(smooth) ) {
        if ( smooth == 'TRUE' & is.numeric(data[,x]) & is.numeric(data[,y]) ) {
            sm_args = list(mapping = aes_q(x = as.name(x), y = as.name(y)), formula = y ~ x,
                           alpha = G('smooth.alpha', 0.25), fullrange = FALSE,
                           method = G('smooth.method', 'lm'),
                           se = identical(G('smooth.se', 'TRUE'), 'TRUE'),
                           level = min(max(G('smooth.level', 0.95), 0.01), 0.999),
                           linewidth = G('smooth.linewidth', 1),
                           linetype = G('smooth.linetype', 'solid'), inherit.aes = FALSE)
            if (!is.null(gg[['smooth.colour']])) {
                sm_args$colour = gg[['smooth.colour']]; sm_args$fill = gg[['smooth.colour']]
            }
            p = p + do.call(geom_smooth, sm_args)
            if (identical(G('median.show', 'TRUE'), 'TRUE')) {
                p = p + geom_quantile(aes_string(x = as.name(x), y = as.name(y) ), formula = y ~ x,
                                      linetype = G('median.linetype', 'dashed'),
                                      color = G('median.colour', 'black'),
                                      quantiles = c(0.5), inherit.aes = FALSE)
            }
            if( ! is.numeric(  data[, color] ) ) {
                p = p + scale_fill_viridis(end = G('colour.end', 0.7), discrete = TRUE,
                                           option = pal_option, direction = pal_dir)
            }
        }
    }

    ## the complete T2 theme for these Appearance settings (set explicitly as
    ## well as via theme_set, so the plot object carries it)
    p = p + ggtitle(  t2_wrap_text(pstring, fig_width, title_size),
                      subtitle = paste(" ", t2_wrap_text(pstring2, fig_width, subtitle_size), '\n ',
                                       t2_wrap_text(psub, fig_width, subtitle_size)) ) +
        do.call(t2_base_theme, style)
    ## a size VARIABLE is drawn around the chosen point size (ggplot's own
    ## range of 1-6 would swamp a small figure)
    if (!is.null(size) && is.numeric(data[, size]) && point_size > 0)
        p = p + scale_size(range = point_size * c(0.5, 3.5))
    if (!is.null(gg[['legend.ncol']]) && !is.null(color) && is.factor(data[, color]))
        p = p + guides(colour = guide_legend(ncol = as.integer(gg[['legend.ncol']])))
    if ( is.factor(data[ , color] ) ) {
        p = p + viridis::scale_colour_viridis(end = G('colour.end', 0.7), discrete = TRUE,
                                              option = pal_option, direction = pal_dir)
    } else {
        p = p + viridis::scale_color_viridis(end = G('colour.end', 0.8), discrete = FALSE,
                                             option = pal_option, direction = pal_dir)
    }
    if (multi_y_fill) {
        p = p + viridis::scale_fill_viridis(end = 0.7, discrete = TRUE, option = 'viridis', alpha = 0.3)
    }
    ## axis transforms apply to numeric axes only
    trans_arg = if ('transform' %in% names(formals(scale_x_continuous))) 'transform' else 'trans'
    if (is.numeric(data[, x]) && G('scale.x.trans', 'identity') != 'identity')
        p = p + do.call(scale_x_continuous, stats::setNames(list(G('scale.x.trans', 'identity')), trans_arg))
    if (!is.null(y) && is.numeric(data[, y]) && G('scale.y.trans', 'identity') != 'identity')
        p = p + do.call(scale_y_continuous, stats::setNames(list(G('scale.y.trans', 'identity')), trans_arg))
    if( coordflip ) {
        p = p + coord_flip()
    }
    if (length(caption) == 1 && !is.na(caption) && nzchar(caption)) p = p + labs(caption = caption)
    ## user-supplied titles / labels (drawn literally), then every other tweak
    user_labs = gg[grep('^labs\\.', names(gg), value = TRUE)]
    if (length(user_labs)) {
        names(user_labs) = sub('^labs\\.', '', names(user_labs))
        p = p + do.call(labs, user_labs)
    }
    p = p + t2_tweak_theme(gg)

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


## Download table: the same samples the plot shows -- the Select tab's cohort /
## non-tumor / heme choices plus the Filter tab's survivors (keep_samples).
fun_table1 = function ( input, dbfile = gitrdb, roles = gitr_default_roles,
                       keep_samples = NULL ) {
    ##    my.input = paste ('~', paste(input$x, input$y, input$color,
    ##        input$size, input$facet, input$sep, sep = ' + ' ) ) ) )
    my.input = c( input$x, input$y, input$color, input$size, input$facet )
    my.input = setdiff( my.input, 'probe' )   # multi-Y colour handle, not a column
    gitr( my.input,
          cohort = if (length(input$cohort)) input$cohort else 'all',
          nonormal = isTRUE(input$nonormal), noheme = isTRUE(input$noheme),
          dbfile = dbfile, roles = roles, keep_samples = keep_samples )
}


fun_plot1 = function(input, reactive = TRUE,
                     dbfile = gitrdb, roles = gitr_default_roles,
                     dataset_label = "TCGA Pan-Cancer 2018",
                     keep_samples = NULL, gg = list(),
                     base_size = 12, base_family = "sans", caption = NULL, fig_width = NULL) {
    if( reactive ) {
        input = shiny::reactiveValuesToList(input)
    }
    ## only whitelisted plotter arguments (see input_validation.R); anything a
    ## client invents (facet.formula, extra, evaluate_vars, ...) is dropped
    input = input[ names(input) %in% T2_INPUT_ARGS ]
    if(FALSE){
    input =   list(x='ABCA1',y='HLA-E',shape = "",size=NULL,color="",static.size="5")
}
    ## remove empty input variables and names
    input = input[ ! sapply(input, is.null) ]
   input = input[ input != 'none']
    input = input[ input != '']
    input = input[ names(input) != '']
    numeric_vars = T2_STYLE_ARGS
    input[ which(names(input) %in% numeric_vars) ] = as.numeric( input[ names(input) %in% numeric_vars ] )
    ## drop the dataset selector itself (not a plotter argument) and inject the
    ## active dataset's db path + role map AFTER the scalar-cleaning filters
    ## above (roles is a list and must not hit `input != ''`).
    input[['dataset']] = NULL
    input$dbfile = dbfile
    input$roles = roles
    input$dataset_label = dataset_label
    ## the Filter tab's surviving sample ids: server-side only (never a browser
    ## input, so not in T2_INPUT_ARGS). list() wrapper keeps a NULL out of the
    ## argument list and lets character(0) ("nothing survives") through.
    if (!is.null(keep_samples)) input['keep_samples'] = list(keep_samples)
    ## extra ggplot settings: validated against the tweak registry here, whatever
    ## the caller did, so nothing unlisted or out of range can reach ggplot
    gg = t2_validate_tweaks(gg)
    if (length(gg)) input['gg'] = list(gg)
    ## figure rendering (Publish tab): theme base size / font, and the source
    ## line. caption = NULL keeps each plot type's own default.
    input$base_size = base_size
    input$base_family = base_family
    if (!is.null(caption)) input$caption = caption
    if (!is.null(fig_width)) input$fig_width = fig_width

    ## Survival mode: if X is a time-to-event endpoint (OS/PFI/DSS/DFI), draw a
    ## Kaplan-Meier plot of the Y marker's tertiles instead of a scatter.
    if (length(input$x) && input$x[1] %in% names(T2_ENDPOINTS)) {
        if (!length(input$y) || !nzchar(input$y[1]))
            return(list(warning = "Survival plot: pick a Y marker to stratify into groups."))
        ## Appearance settings laid over the survival plot: fonts, legend, theme
        km_style = input[intersect(names(input), names(formals(t2_font_theme)))]
        return(tryCatch(t2_style_survival(
            survival_km(y = input$y, endpoint = input$x[1],
                        cohort = if (length(input$cohort)) input$cohort else "all",
                        facet  = input$facet,
                        n_groups = if (length(input$km_groups)) as.integer(input$km_groups[1]) else 3,
                        max_time = if (length(input$surv_max_days)) suppressWarnings(as.numeric(input$surv_max_days[1])) else 365 * 5,
                        condition = input$condition,
                        pcortype  = if (!is.null(input$pcortype)) input$pcortype else "none",
                        nonormal = if (!is.null(input$nonormal)) as.logical(input$nonormal)[1] else TRUE,
                        noheme = if (!is.null(input$noheme)) as.logical(input$noheme)[1] else FALSE,
                        keep_samples = keep_samples,
                        base_size = base_size, base_family = base_family,
                        dbfile = dbfile, roles = roles),
            style = km_style, gg = gg, caption = caption, fig_width = fig_width),
            error = function(e) list(warning = paste("Survival plot:", conditionMessage(e)))))
    }

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
