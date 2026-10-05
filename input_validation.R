## input_validation.R
## ============================================================================
## Server-side whitelist for everything the browser sends.
##
## Shiny does not enforce selectize choices, and a client can set inputs that
## are not in the UI at all (e.g. Shiny.setInputValue('facet.formula', ...)).
## So the app never hands `input` to the plotter directly: sanitize_t2_input()
## keeps only the names below and checks every value against the active
## dataset's choice lists. Anything unknown is dropped or replaced by the
## UI default.
## ============================================================================

## plotter() arguments that may come from the browser (dbfile / roles /
## dataset_label are injected by the server afterwards).
T2_INPUT_ARGS = c('x', 'y', 'color', 'size', 'cohort', 'facet', 'condition',
                  'pcortype', 'multi_y', 'zscore_y', 'coordflip', 'waterfall',
                  'waterfall_flip', 'nonormal', 'noheme', 'allComplete',
                  'smooth', 'scales', 'show_legend', T2_STYLE_ARGS,
                  'km_groups', 'surv_max_days')

## character values that are in `allowed`, de-duplicated, at most max_n;
## NULL when nothing survives (matches an empty selectize)
.t2_pick = function(v, allowed, max_n) {
    v = as.character(unlist(v))
    v = unique(v[!is.na(v) & v %in% allowed])
    if (length(v) == 0) return(NULL)
    head(v, max_n)
}

## single value from `allowed`, else default
.t2_one = function(v, allowed, default) {
    v = as.character(unlist(v))[1]
    if (length(v) == 1 && !is.na(v) && v %in% allowed) v else default
}

## single logical, else default
.t2_flag = function(v, default = FALSE) {
    v = suppressWarnings(as.logical(unlist(v))[1])
    if (length(v) == 1 && !is.na(v)) v else default
}

## nearest value from a numeric choice list, else default
.t2_num = function(v, choices, default) {
    v = suppressWarnings(as.numeric(unlist(v))[1])
    if (length(v) != 1 || is.na(v)) return(default)
    choices[which.min(abs(choices - v))]
}

## input: shiny input (reactivevalues) or a plain list; b: dataset bundle
sanitize_t2_input = function(input, b) {
    ## read only the named inputs below: converting all of `input` to a list
    ## makes an output depend on every input (e.g. DT table state) and re-render forever
    vars = b$mygenesplus
    c(list(
        x         = .t2_pick(input$x, c(vars, names(T2_ENDPOINTS)), 20),
        y         = .t2_pick(input$y, vars, 20),
        color     = .t2_one(input$color, c('probe', vars), ""),
        size      = .t2_one(input$size, vars, ""),
        cohort    = .t2_pick(input$cohort, c('all', unname(b$mycohorts)), 200),
        facet     = .t2_pick(input$facet, vars, 3),
        condition = .t2_pick(input$condition, vars, 10),
        pcortype  = .t2_one(input$pcortype, c('none', 'x', 'y', 'both'), 'none'),
        multi_y        = .t2_flag(input$multi_y),
        zscore_y       = .t2_flag(input$zscore_y),
        coordflip      = .t2_flag(input$coordflip),
        waterfall      = .t2_flag(input$waterfall),
        waterfall_flip = .t2_flag(input$waterfall_flip),
        nonormal       = .t2_flag(input$nonormal),
        noheme         = .t2_flag(input$noheme),
        allComplete    = .t2_flag(input$allComplete, TRUE),
        smooth        = .t2_one(input$smooth, c("TRUE", "FALSE"), "TRUE"),
        scales        = .t2_one(input$scales, c("free", "fixed", "free_x", "free_y"), "fixed"),
        show_legend   = .t2_flag(input$show_legend, TRUE),
        km_groups     = .t2_num(input$km_groups, 2:6, 3),
        surv_max_days = .t2_num(input$surv_max_days, seq(30, 365 * 30, by = 30), 365 * 5)
    ),
    ## the Appearance menus (plot_style.R): each value snaps to its own menu.
    ## plot_height is returned for the page; it is not a plotter argument.
    lapply(stats::setNames(names(T2_STYLE), names(T2_STYLE)), function(id) {
        .t2_num(input[[id]], T2_STYLE[[id]]$choices, T2_STYLE[[id]]$default)
    }))
}

## The extra ggplot settings chosen in the Appearance tab's search box:
## id -> validated value. Only ids from the registry (T2_TWEAKS) are read, each
## from its own generated input, and every value passes t2_validate_tweak().
sanitize_t2_tweaks = function(input) {
    picked = .t2_pick(input$tweak_pick, names(T2_TWEAKS), 60)
    vals = lapply(stats::setNames(picked, picked),
                  function(id) input[[t2_tweak_input_id(id)]])
    t2_validate_tweaks(vals[!vapply(vals, is.null, NA)])
}
