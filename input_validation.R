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

## plotter() arguments that may come from the browser (the plot context --
## dataset, roles, label, Filter-tab samples, sample rules -- is injected by the
## server afterwards).
T2_INPUT_ARGS = c('x', 'y', 'color', 'size', 'cohort', 'facet', 'condition',
                  'pcortype', 'multi_y', 'zscore_y', 'coordflip', 'waterfall',
                  'waterfall_flip', 'allComplete',
                  'smooth', 'scales', 'show_legend', T2_STYLE_ARGS,
                  'km_groups', 'surv_max_days')

## The fixed menus of the Select / Appearance tabs, in ONE place: the UI (app.R)
## builds its widgets from these and the sanitizer below checks the browser's
## value against the same choices and default. id -> list(choices, default).
T2_CONTROLS = list(
    pcortype      = list(id = 'pcortype',      choices = c('none', 'x', 'y', 'both'),             default = 'none'),
    scales        = list(id = 'scales',        choices = c("fixed", "free", "free_x", "free_y"),  default = "fixed"),
    smooth        = list(id = 'smooth',        choices = c("TRUE", "FALSE"),                      default = "TRUE"),
    km_groups     = list(id = 'km_groups',     choices = 2:6,                                     default = 3),
    surv_max_days = list(id = 'surv_max_days', choices = seq(30, 365 * 30, by = 30),             default = 365 * 5),
    quant_k       = list(id = 'analysis_quant_k', choices = 2:4,                                  default = 3)
)

## character values that are in `allowed`, de-duplicated, at most max_n;
## NULL when nothing survives (matches an empty selectize)
.t2_pick = function(v, allowed, max_n) {
    v = as.character(unlist(v))
    v = unique(v[!is.na(v) & v %in% allowed])
    if (length(v) == 0) return(NULL)
    head(v, max_n)
}

## The cohort choice. Rule: "all" together with named cohorts means all (the
## dataset-wide choice contains every cohort; gitr() would otherwise draw only the
## named ones while the subtitle said "all"), so the pick is reduced to "all".
.t2_cohort_pick = function(v, cohorts, max_n) {
    v = .t2_pick(v, c('all', cohorts), Inf)
    if ('all' %in% v) 'all' else head(v, max_n)
}

## single value from `allowed`, else default
.t2_one = function(v, allowed, default) {
    v = as.character(unlist(v))[1]
    if (!is.na(v) && v %in% allowed) v else default
}

## single logical, else default
.t2_flag = function(v, default = FALSE) {
    v = suppressWarnings(as.logical(unlist(v))[1])
    if (!is.na(v)) v else default
}

## nearest value from a numeric choice list, else default
.t2_num = function(v, choices, default) {
    v = suppressWarnings(as.numeric(unlist(v))[1])
    if (is.na(v)) return(default)
    choices[which.min(abs(choices - v))]
}

## A quantized-variable token ("t2q::<k>::<name>", group_compare.R) is a plotter input
## for `color` and `facet`: valid when it parses strictly and <name> is a served
## variable of menu kind "num". The plotter resolves it into a derived column; the
## token itself never changes T2_INPUT_ARGS (the argument names stay as they were).
.t2_quant_ok = function(v, b) {
    v = as.character(unlist(v))[1]
    q = t2_quant_parse(v)
    !is.null(q) && q$name %in% b$mygenesplus && identical(.t2_menu_kind(b, q$name), "num")
}

## input: shiny input (reactivevalues) or a plain list; b: dataset bundle
sanitize_t2_input = function(input, b) {   # b: the active bundle (its variable list, cohorts and tte names)
    ## read only the named inputs below: converting all of `input` to a list
    ## makes an output depend on every input (e.g. DT table state) and re-render forever
    vars = b$mygenesplus
    c(list(
        x         = .t2_pick(input$x, c(vars, tte_names(b), Filter(function(t) .t2_quant_ok(t, b), as.character(unlist(input$x)))), T2_LIMITS$x_vars),
        y         = .t2_pick(input$y, c(vars, Filter(function(t) .t2_quant_ok(t, b), as.character(unlist(input$y)))), T2_LIMITS$y_vars),
        color     = if (.t2_quant_ok(input$color, b)) as.character(input$color)[1] else .t2_one(input$color, c('probe', vars), ""),
        size      = if (.t2_quant_ok(input$size, b)) as.character(input$size)[1] else .t2_one(input$size, vars, ""),
        cohort    = .t2_cohort_pick(input$cohort, unname(b$mycohorts), T2_LIMITS$cohorts),
        facet     = .t2_pick(input$facet, c(vars, Filter(function(t) .t2_quant_ok(t, b), as.character(unlist(input$facet)))),
                             T2_LIMITS$facet_vars),
        condition = .t2_pick(input$condition, c(vars, Filter(function(t) .t2_quant_ok(t, b), as.character(unlist(input$condition)))), T2_LIMITS$condition_vars),
        pcortype  = .t2_one(input$pcortype, T2_CONTROLS$pcortype$choices, T2_CONTROLS$pcortype$default),
        multi_y        = .t2_flag(input$multi_y),
        zscore_y       = .t2_flag(input$zscore_y),
        coordflip      = .t2_flag(input$coordflip),
        waterfall      = .t2_flag(input$waterfall),
        waterfall_flip = .t2_flag(input$waterfall_flip),
        allComplete    = .t2_flag(input$allComplete, TRUE),
        smooth        = .t2_one(input$smooth, T2_CONTROLS$smooth$choices, T2_CONTROLS$smooth$default),
        scales        = .t2_one(input$scales, T2_CONTROLS$scales$choices, T2_CONTROLS$scales$default),
        show_legend   = .t2_flag(input$show_legend, TRUE),
        km_groups     = .t2_num(input$km_groups, T2_CONTROLS$km_groups$choices, T2_CONTROLS$km_groups$default),
        surv_max_days = .t2_num(input$surv_max_days, T2_CONTROLS$surv_max_days$choices, T2_CONTROLS$surv_max_days$default)
    ),
    ## the Appearance menus (plot_style.R): each value snaps to its own menu.
    ## plot_height is returned for the page; it is not a plotter argument.
    sanitize_t2_style(input)[names(T2_STYLE)])
}

## The sample choice of the Select tab: the data source (part of the bundle),
## the chosen group and the chosen exclusions, checked against what
## t2_filter_choices() offers for this source and group (t2_presets.R, from the rules in /meta). Returns
## list(group, exclusions, rules, label): `rules` is what reaches gitr() --
## built here, never taken from the browser.
sanitize_t2_samples = function(input, b) {
    src = b$source
    group = .t2_one(input$preset_group, src$groups, "")
    ch = t2_filter_choices(src, b$presets, b$clin, if (nzchar(group)) group else NULL)
    excl = .t2_pick(input$preset_excl, ch$exclusions, 20)
    by_label = stats::setNames(b$presets, vapply(b$presets, `[[`, "", "label"))
    rules = src$rules
    for (p in c(if (nzchar(group)) group, excl)) rules = c(rules, by_label[[p]]$rules)
    list(group = if (nzchar(group)) group else NULL, exclusions = excl, rules = rules,
         label = paste(c(src$label, if (nzchar(group)) group, excl), collapse = "; "))
}

## The fixed style menus + the legend switch, read from the Appearance tab
## (prefix "") or the Publish tab's own copy (prefix "pub_"). `defaults`
## replaces the menu defaults (a figure preset has its own).
sanitize_t2_style = function(input, prefix = "", defaults = list()) {
    ids = names(T2_STYLE)
    out = lapply(stats::setNames(ids, ids), function(id) {
        d = if (!is.null(defaults[[id]])) defaults[[id]] else T2_STYLE[[id]]$default
        .t2_num(input[[paste0(prefix, id)]], T2_STYLE[[id]]$choices, d)
    })
    out$show_legend = .t2_flag(input[[paste0(prefix, "show_legend")]], TRUE)
    out
}

## The extra ggplot settings chosen in the Appearance tab's search box:
## id -> validated value. Only ids from the registry (T2_TWEAKS) are read, each
## from its own generated input, and every value passes t2_validate_tweak().
sanitize_t2_tweaks = function(input, prefix = "") {
    picked = .t2_pick(input[[paste0(prefix, "tweak_pick")]], names(T2_TWEAKS), 60)
    vals = lapply(stats::setNames(picked, picked),
                  function(id) input[[t2_tweak_input_id(id, prefix)]])
    t2_validate_tweaks(vals[!vapply(vals, is.null, NA)])
}

## ----------------------------------------------------------------------------
## The Analysis tab (group_compare.R; contract: T2Mobile/docs/ANALYSIS-SPEC.md).
## These inputs never reach plotter(), so nothing here enters T2_INPUT_ARGS.

## the menu kind ("num" | "cat") of a served variable, NA when unknown
.t2_menu_kind = function(b, name) {
    i = match(name, b$menu$name)
    if (is.na(i)) NA_character_ else b$menu$kind[i]
}

## The Analysis tab's choices, checked against what is CURRENTLY offered:
##   analysis_group  a grouping: "t2split::<col>" (col an active filter column),
##                   "t2split::*" (only when >= 2 filters are active), a t2q::
##                   token, or a served variable name (cat as-is; num quantized
##                   with analysis_quant_k)
##   analysis_var    the test variable: a served name or a tte endpoint
##   analysis_means  the means-based toggle (Welch t / ANOVA)
## active_cols: the columns with an active Thanos filter (from h$th$filters()).
## Returns list(grouping = list(kind, name|col, k, token), var, var_kind, means,
## method = "auto") -- or NULL when the grouping or variable is not acceptable;
## `method` is the model-mode seam (ANALYSIS-SPEC.md section 6).
sanitize_t2_analysis = function(input, b, active_cols = character(0)) {
    g = as.character(unlist(input$analysis_group))[1]
    if (is.na(g) || !nzchar(g)) return(NULL)
    k = .t2_num(input$analysis_quant_k, T2_CONTROLS$quant_k$choices, T2_CONTROLS$quant_k$default)
    grouping = NULL
    if (identical(g, t2_split_token())) {                        # "t2split::*"
        if (length(active_cols) >= 2) grouping = list(kind = "split_whole", token = g)
    } else if (startsWith(g, "t2split::")) {
        col = sub("^t2split::", "", g)
        if (col %in% active_cols) grouping = list(kind = "split_loo", col = col, token = g)
    } else if (!is.null(q <- t2_quant_parse(g))) {               # "t2q::<k>::<name>"
        if (identical(.t2_menu_kind(b, q$name), "num"))
            grouping = list(kind = "quant", name = q$name, k = q$k, token = g)
    } else if (g %in% b$mygenesplus) {
        kind = .t2_menu_kind(b, g)
        if (identical(kind, "cat")) grouping = list(kind = "cat", name = g, token = g)
        if (identical(kind, "num")) grouping = list(kind = "quant", name = g, k = k,
                                                    token = t2_quant_token(g, k))
    }
    if (is.null(grouping)) return(NULL)
    v = .t2_one(input$analysis_var, c(b$mygenesplus, tte_names(b)), "")
    if (!nzchar(v)) return(NULL)
    var_kind = if (v %in% tte_names(b)) "tte" else .t2_menu_kind(b, v)
    if (is.na(var_kind)) return(NULL)
    list(grouping = grouping, var = v, var_kind = var_kind,
         means = .t2_flag(input$analysis_means), method = "auto")
}
