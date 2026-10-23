#' # tidy tcga database
#' ## Nathan Siemers

source('t2_util.R')              # %||%, t2_role(), t2_cache(), t2_as_rules(): sourced first
library(sqldf)
library(ggplot2); library(ggthemes)
library(viridis)
library(tidyverse)
source('gitr.R')                 # gitr(), T2_LIMITS, t2_sample_keep(); the file path is the oracle of the tests
source('t2_api_client.R')        # the data layer of the app: the t2api service
source('marker_ops.R')           # shared: combine_markers_median_z, residualize_on
source('survival_prototype.R')   # Kaplan-Meier survival mode (survival_km, tte_names)
source('plot_style.R')           # Appearance settings, themes, the ggplot tweak registry
source('figure_export.R')        # Publish tab: figure presets, validation, rendering
source('t2_search.R')            # ranked search in the variable menus
source('t2_descriptions.R')      # what the clinical columns mean
source('t2_contact.R')           # the contact form (About tab)
t2_api_require()                 # no T2_API_URL, no app: one clear message
################################################################
## Dataset bundle
##
## load_dataset_bundle(name) is the dataset as the t2api service declares it
## (t2_api_bundle in t2_api_client.R): the variable lists, the handles, the
## time-to-event variables, the type labels, the About prose, the cohort list,
## the presets and sources. The app calls it at startup and again on every
## dataset switch, then repopulates all selectize inputs from the bundle. It
## is the single point that "understands" which dataset is active -- and it
## understands only what /meta and /probes say (DATASET-CONTRACT.md): the app
## never opens a database and derives nothing.
################################################################

## Cached per process and per version of the dataset (the service's version
## string): every session and every dataset switch asks for the same lists
## (135,000 names for TCGA). A new version is read again.
.bundle_cache = t2_cache(8)
load_dataset_bundle = function(name) {
  key = paste(name, t2_api_version(name))
  hit = .bundle_cache$get(key)
  if (!is.null(hit)) return(hit)
  .bundle_cache$put(key, t2_api_bundle(name))
}

## A SOURCE bundle: the dataset bundle plus the chosen part of it. `key` is
## "<dataset>" (the whole collection) or "<dataset>|<source label>". The app's
## active bundle is one of these: $source is the /meta `sources` entry (rules,
## cohorts present, groups and exclusions offered, single-level columns), and
## $mycohorts holds only the cohorts present in the part.
load_source_bundle = function(key) {
  parts = strsplit(key, "|", fixed = TRUE)[[1]]
  b = load_dataset_bundle(parts[1])
  labels = vapply(b$sources, `[[`, "", "label")
  i = if (length(parts) > 1) match(parts[2], labels) else 1L
  if (is.na(i)) stop("dataset ", parts[1], " has no part called '", parts[2], "'")
  src = b$sources[[i]]
  b$key = if (i == 1) b$name else paste0(b$name, "|", src$label)
  b$source = src
  b$mycohorts = b$mycohorts[unname(b$mycohorts) %in% src$cohorts]
  if (i > 1) {
    b$label = paste0(b$label, ": ", src$label); b$title = paste0(b$title, " \u2014 ", src$label)
    b$part_label = src$label     # the plot title names the part ("GTEx (Toil)"), not the whole collection
  }
  b
}

## A dataset left out of the menu: `hidden` in /v1/datasets (dataset_meta key
## hidden = 1; absent = listed). Documented fallback while the served data lack the
## key (removed once they carry it): the name DEMO, or a title saying "not real data".
## The service always emits `hidden` (false when the key is absent), so the two are
## combined as in the iOS app: hidden when the field is true OR the fallback matches.
## The dataset stays served and usable by name (the test suites use DEMO).
t2_dataset_hidden = function(d) {
  if (isTRUE(as.logical(d$hidden)[1])) return(TRUE)
  identical(d$name, "DEMO") || grepl("not real data", d$title %||% "", ignore.case = TRUE)
}

## every data source of every dataset, for the "Data set" menu: a named
## vector, display name -> key (the whole collection first, then its parts).
## From /v1/datasets alone: no bundle is loaded until its dataset is opened.
## include_hidden = TRUE: every served source (what the app accepts by name, the menu excludes hidden ones).
list_sources = function(include_hidden = FALSE) {
  out = character(0)
  for (d in t2_api_datasets()) {
    if (!include_hidden && t2_dataset_hidden(d)) next
    srcs = t2_api_need(d, "sources", "/v1/datasets")
    for (i in seq_along(srcs)) {
      key = if (i == 1) d$name else paste0(d$name, "|", srcs[[i]]$label)
      out[if (i == 1) d$label else paste0(d$label, ": ", srcs[[i]]$label)] = key
    }
  }
  out
}

## The plot context: the active data source and the samples chosen from it,
## ONE object for fun_plot1 / plotter / fun_table1 / survival_km / gitr_memo /
## backend_t2 instead of a growing list of arguments.
##   path/name  the dataset (its name, over the service)   version  its version
##   roles      cohort / subtype / sample-type columns, normal and heme values
##   label      the display name for captions
##   handles    data.frame(name, role): the virtual columns, from /meta `handles`
##   tte        the time-to-event variables, from /meta `tte_variables`
##   type_labels  the title word of each data type; menu  the typed variable list
##   keep       the Filter tab's surviving sample ids (NULL = no restriction)
##   rules      the sample choice (source, group, exclusions) as preset rules
##   fill       the not-detected values: "na" (missing), "zero" or "floor" (what the values answer offers)
t2_plot_ctx = function(bundle, keep = NULL, rules = list(), fill = "na") {
  ## label: the dataset word of the plot title -- the part's own label when a part of
  ## a collection is chosen (GTEx within TCGA-TARGET-GTEx), else the dataset's
  list(name = bundle$name, path = bundle$path, version = bundle$version,
       label = if (!is.null(bundle$part_label)) bundle$part_label else bundle$label,
       roles = bundle$roles, handles = bundle$handles, tte = bundle$tte,
       type_labels = bundle$type_labels, menu = bundle$menu, keep = keep, rules = rules, fill = fill)
}
## The one-line pointer to the survival analysis, from the bundle's tte list
## (/meta tte_variables): "Survival curves: choose OS, PFI, DSS or DFI as X
## (Kaplan-Meier by groups of Y)", the labels of the variables in a smaller line
## after it. NULL when the data set has no time-to-event variable. Shown on the
## About tab and under the X selector.
t2_survival_hint_text = function(tte) {
    nm = names(tte)
    paste0("Survival curves: choose ", if (length(nm) > 1) paste(paste(utils::head(nm, -1), collapse = ", "), "or", utils::tail(nm, 1))
                                       else nm, " as X (Kaplan-Meier by groups of Y)")
}
t2_survival_hint = function(b, class = "t2-survival-hint") {
    tte = b$tte
    if (!length(tte)) return(NULL)
    labs = vapply(tte, function(t) if (nzchar(t$label) && !identical(t$label, t$name)) paste0(t$name, ": ", t$label) else t$name, "")
    div(class = class, tags$b(t2_survival_hint_text(tte)), ".",
        if (any(grepl(":", labs, fixed = TRUE))) tags$small(" ", paste(labs, collapse = "; "), "."))
}

## The caption line "Filtered: ..." that says which samples a figure leaves out, so a
## filtered plot never passes for the whole dataset. Built from what is active:
##   samp     sanitize_t2_samples(): the part of a collection, the group and the exclusions
##            (preset labels); b: the active bundle (its cohorts); cohort: the chosen cohorts
##   rules    the Filter tab's active rules in words ("CD8A >= 2"); n_kept/n_base the surviving
##            and starting sample counts. Plain words for up to 3 short rules, else "N of M
##            samples kept"; nonormal/noheme: the classic switches.
## "" when nothing is filtered. A pure function (no app state), tested on its own.
t2_filter_caption = function(samp = list(), b = list(), cohort = "all", rules = character(0),
                             n_kept = NA, n_base = NA, nonormal = FALSE, noheme = FALSE) {
  parts = character(0)
  ## the preset(s) by label; the part of a collection (not the whole one) counts as a filter
  if (!is.null(b$part_label)) parts = c(parts, b$part_label)
  parts = c(parts, samp$group, samp$exclusions)
  if (isTRUE(nonormal)) parts = c(parts, "no normals")
  if (isTRUE(noheme))   parts = c(parts, "no heme")
  ## cohorts: all / N of M / the names when there are at most 3
  cohort = setdiff(as.character(cohort), c("all", ""))
  allco = unname(b$mycohorts)
  if (length(cohort) && !(length(allco) && setequal(cohort, allco)))
    parts = c(parts, if (length(cohort) <= 3) paste0("cohorts ", paste(cohort, collapse = ", "))
                     else sprintf("%d of %d cohorts", length(cohort), max(length(allco), length(cohort))))
  ## the Filter tab: the rules in words, or just the count when they are many or long
  if (length(rules)) {
    if (length(rules) <= 3 && sum(nchar(rules)) <= 90) parts = c(parts, paste(rules, collapse = " and "))
    else if (is.finite(n_kept) && is.finite(n_base))
      parts = c(parts, sprintf("%s of %s samples kept", format(n_kept, big.mark = ","), format(n_base, big.mark = ",")))
    else parts = c(parts, sprintf("%d Filter-tab rules", length(rules)))
  } else if (is.finite(n_kept) && is.finite(n_base) && n_kept < n_base) {
    parts = c(parts, sprintf("%s of %s samples kept", format(n_kept, big.mark = ","), format(n_base, big.mark = ",")))
  }
  parts = parts[!is.na(parts) & nzchar(parts)]
  if (length(parts)) paste0("Filtered: ", paste(parts, collapse = "; ")) else ""
}

## caption text of a plot: the "Filtered: ..." line and the source line, one under the
## other, each wrapped to the figure (a screen plot is wrapped at 110 characters)
t2_caption_text = function(filter_caption = "", source_line = "", fig_width = NULL, size = 9) {
  one = function(x) if (length(x) == 1 && !is.na(x) && nzchar(x)) x else NULL
  wrap = function(x) if (is.null(fig_width)) paste(strwrap(x, 110), collapse = "\n") else t2_wrap_text(x, fig_width, size)
  ## filter_caption: one string, or several lines (the Filtered line, the not-detected line)
  fcs = Filter(Negate(is.null), lapply(filter_caption, one))
  out = c(vapply(fcs, wrap, ""), one(source_line))
  if (length(out)) paste(out, collapse = "\n") else ""
}

## What the values answer said about not-detected values, from a data frame gitr() returned:
## list(options = the fills on offer (na first), fill = the one applied or NULL, filled, tested_n
## = named integer vectors of the probes with cells changed). The app shows its "Not-detected
## values" control iff `options` has more than "na", and offers exactly those.
t2_fill_of = function(df, rows = NULL) {
  info = list(options = attr(df, "fill_options") %||% "na", fill = attr(df, "fill", exact = TRUE),
              filled = attr(df, "filled"), tested_n = attr(df, "tested_n"), basis = "dataset")
  ## the counts of the PLOT: cells set among the rows of this frame (attr filled_rows), against the
  ## samples shown with a value for the probe; the dataset-wide answer counts stay as the fallback
  fr = attr(df, "filled_rows")
  if (!is.null(fr) && !is.null(info$fill)) {
    p = intersect(names(fr), colnames(df))
    ## rows: optional logical mask of the frame's rows actually plotted (complete cases of the plotted variables)
    if (is.null(rows)) { n = vapply(p, function(v) sum(fr[[v]]), 0L); shown = vapply(p, function(v) sum(!is.na(df[[v]])), 0L) }
    else { n = vapply(p, function(v) sum(fr[[v]][rows]), 0L); shown = vapply(p, function(v) sum(!is.na(df[[v]][rows])), 0L) }
    info$filled = n[n > 0]; info$tested_n = shown[n > 0]; info$basis = "shown"
  }
  info
}

## the fill info of a plot result (a plotter list, or a ggsurvplot / ggplot with attr t2fill); NULL if none
t2_result_fill = function(res) {
  if (is.null(res)) return(NULL)
  if (!is.null(attr(res, "t2fill"))) return(attr(res, "t2fill"))
  if (is.list(res) && !inherits(res, "ggsurvplot") && !is.null(res$fill)) res$fill else NULL
}

## the data type's word of a variable for the not-detected caption ("protein"), "" when none
t2_type_word = function(v, ctx) {
  i = match(v, ctx$menu$name); ty = if (is.na(i)) NA_character_ else ctx$menu$type[i]
  w = if (is.na(ty)) "" else unname(ctx$type_labels[ty]) %||% ""
  if (identical(w, ty)) "" else w
}

## The caption line for filled values: "Not-detected protein values set to 0 (1,357 of 1,549 tested
## samples)" / "... set to the detection floor, per cohort (...)". One probe: that sentence; two:
## the sentence with a clause per probe; more: the total of cells and the number of variables.
## "" when no cell was filled. The numbers are the answer's (filled / tested_n); the word is the
## data type's label (/meta type_labels).
t2_fill_caption = function(info, ctx) {
  if (is.null(info) || is.null(info$fill) || !length(info$filled)) return("")
  how = if (identical(info$fill, "zero")) "0" else "the detection floor, per cohort"
  n = function(x) format(x, big.mark = ",", trim = TRUE)
  p = names(info$filled)
  words = unique(Filter(nzchar, vapply(p, t2_type_word, "", ctx = ctx)))
  unit = if (identical(info$basis, "shown")) "samples shown" else "tested samples"
  noun = paste0("Not-detected ", if (length(words)) paste0(paste(words, collapse = "/"), " "), "values")
  if (length(p) == 1)
    return(sprintf("%s set to %s (%s of %s %s)", noun, how, n(info$filled[[1]]), n(info$tested_n[[p]]), unit))
  if (length(p) == 2)
    return(sprintf("%s set to %s: %s", noun, how, paste(sprintf("%s (%s of %s)", p, n(info$filled[p]), n(info$tested_n[p])), collapse = ", ")))
  sprintf("%s not-detected values set to %s (%d variables)", n(sum(info$filled)), how, length(p))
}

## one Data Summary line per filled probe
t2_fill_summary = function(info) {
  if (is.null(info) || is.null(info$fill) || !length(info$filled)) return(character(0))
  p = names(info$filled); n = function(x) format(x, big.mark = ",", trim = TRUE)
  how = if (identical(info$fill, "zero")) "0" else "the detection floor of the cohort"
  if (identical(info$basis, "shown"))
    sprintf("%s: %s not-detected values set to %s among %s samples shown", p, n(info$filled), how, n(info$tested_n[p]))
  else sprintf("%s: %s not-detected values set to %s (%s tested samples)", p, n(info$filled), how, n(info$tested_n[p]))
}

## the context of the default dataset, for scripts and tests that plot without a bundle
t2_default_ctx = function() t2_plot_ctx(load_dataset_bundle(t2_default_dataset()))

## the names of the handles of one role (cohort | subcohort | sample_type)
t2_handle_names = function(ctx, roles) ctx$handles$name[ctx$handles$role %in% roles]

## the word of a variable's data type for a plot title: "TP53.mut" -> "TP53 mutation".
## The type is the variable's entry in the typed variable list; a type whose label
## is empty or equal to its name (a bare RNA name, a file without labels) adds nothing.
t2_title_name = function(v, ctx) {
  vapply(v, function(one) {
    i = match(one, ctx$menu$name)
    ty = if (is.na(i)) NA_character_ else ctx$menu$type[i]
    word = if (is.na(ty)) "" else unname(ctx$type_labels[ty]) %||% ""
    suffix = paste0(".", ty)
    if (!is.na(ty) && nzchar(word) && !identical(word, ty) && endsWith(one, suffix))
      paste0(substr(one, 1, nchar(one) - nchar(suffix)), " ", word) else one
  }, "", USE.NAMES = FALSE)
}

################################################################
## convenience lists of the DEFAULT dataset (for scripts and tests; the app
## takes everything from the active bundle)

.default_bundle = load_dataset_bundle(t2_default_dataset())
samples = .default_bundle$samples
mygenes = .default_bundle$mygenes
mycohorts = .default_bundle$mycohorts
mygenesplus = .default_bundle$mygenesplus

################################################################
## requests T2 does not draw (see T2_LIMITS in gitr.R)
################################################################

## What takes the place of a plot that was refused: the reason, drawn where the
## plot would be (and sent as the warning as well). Nothing else is drawn, so
## this costs milliseconds whatever was asked for.
t2_message_plot = function(msg, summary = "", hint = NULL, fig_width = NULL, title_size = 16) {
    wrap = function(s, size) {
        if (is.null(s)) return(NULL)
        if (is.null(fig_width)) paste(strwrap(s, 95), collapse = "\n") else t2_wrap_text(s, fig_width, size)
    }
    p = ggplot() + ggtitle(wrap(msg, title_size), subtitle = wrap(hint, title_size * 0.8)) +
        theme_void() +
        theme(plot.title = element_text(size = max(title_size, 4), hjust = 0, margin = margin(12, 12, 6, 12)),
              plot.subtitle = element_text(size = max(title_size * 0.8, 4), hjust = 0, margin = margin(6, 12, 6, 12)))
    list(plot = p,
         summary = paste0(summary, if (nzchar(summary)) "\n\n" else "", "NOT PLOTTED: ", msg),
         warning = msg, refused = TRUE)
}

## Would drawing `data` exceed a limit? Returns list(msg, hint) for the user,
## or NULL when the plot may be drawn. x / y / color / size / facet are the
## column names about to be mapped; n_probes is the number of Y probes behind
## a 'probe' facet (multi-Y), for the wording only.
t2_plot_refusal = function(data, x, y = NULL, color = NULL, size = NULL, facet = NULL,
                           n_probes = 0, limits = T2_LIMITS) {
    big = function(n) format(n, big.mark = ",", trim = TRUE)
    is_cat = function(v) length(v) == 1 && !is.na(v) && v %in% colnames(data) && !is.numeric(data[, v])
    n_val = function(v) length(unique(data[, v]))
    fewer = "Choose a variable with fewer categories, or narrow the samples with Cohort or the Filter tab."
    ## graphs: one per combination of the 'Graph for each' variables (and per Y
    ## probe, when probes are plotted individually next to a color variable)
    fv = facet[!is.na(facet) & facet %in% colnames(data)]
    if (length(fv) > 0) {
        n_pan = if (length(fv) == 1) n_val(fv) else sum(!duplicated(data[, fv, drop = FALSE]))
        if (n_pan > limits$panels) {
            what = vapply(fv, function(v) {
                if (v == "probe" && n_probes > 0) sprintf("%d Y probes", n_probes)
                else sprintf("'%s' (%s values)", v, big(n_val(v)))
            }, "")
            msg = if (length(fv) == 1 && !(fv == "probe" && n_probes > 0))
                      sprintf("'%s' has %s different values; 'Graph for each' is limited to %d graphs.",
                              fv, big(n_pan), limits$panels)
                  else sprintf("%s would be %s graphs; one plot is limited to %d graphs.",
                               paste(what, collapse = " x "), big(n_pan), limits$panels)
            return(list(msg = msg, hint = if ("probe" %in% fv && n_probes > 0)
                paste("Plotting Y probes individually next to a color variable draws one graph per probe",
                      "and 'Graph for each' value. Choose fewer Y probes or fewer graphs.") else fewer))
        }
    }
    check = function(v, what, lim) {
        if (!is_cat(v)) return(NULL)
        n = n_val(v)
        if (n <= lim) return(NULL)
        list(msg = sprintf("'%s' has %s different values; %s is limited to %d categories.", v, big(n), what, lim),
             hint = fewer)
    }
    for (r in list(check(x, "a categorical X", limits$x_levels),
                   check(y, "a categorical Y", limits$y_levels),
                   check(color, "color", limits$colour_levels),
                   check(size, "size", limits$size_levels))) {
        if (!is.null(r)) return(r)
    }
    NULL
}

################################################################
## make a plotter function
################################################################

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
    ## filter_caption: the "Filtered: ..." line (t2_filter_caption), above the source line
    filter_caption = "",
    ## fill_caption: also say in the caption when not-detected values were set to 0 / the floor
    fill_caption = TRUE,
    coordflip = FALSE, evaluate_vars = FALSE,
    condition = NULL, waterfall = FALSE, waterfall_flip = FALSE, noheme = FALSE, pcortype = 'none',
    multi_y = FALSE, zscore_y = FALSE,
    ctx = t2_default_ctx(), ...
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
    ## retrieve tcga data  HELP
    ## only include conditioning variables if actually being used
    active_condition = if (!is.null(condition) && pcortype != 'none') condition else NULL
    list.of.markers = c( x, y, color, shape, size, c(facet), c(extra), c(active_condition)  )
    ## save original parameter values before transformations
    orig_x = x; orig_y = y; orig_color = color; orig_shape = shape
    orig_size = size; orig_facet = facet; orig_condition = condition
    ## how much one request may ask for (T2_LIMITS): refuse before fetching anything
    too_many = NULL
    for (lim in list(list(x, T2_LIMITS$x_vars, "X"),
                     list(y, if (isTRUE(multi_y)) T2_LIMITS$multi_y else T2_LIMITS$y_vars,
                          if (isTRUE(multi_y)) "Y (plotted individually)" else "Y"),
                     list(facet, T2_LIMITS$facet_vars, "'Graph for each'"),
                     list(active_condition, T2_LIMITS$condition_vars, "'Remove influences of'"),
                     list(cohort, T2_LIMITS$cohorts, "Cohort"))) {
        if (is.null(too_many) && length(lim[[1]]) > lim[[2]])
            too_many = sprintf("%d variables were chosen for %s; the limit is %d.", length(lim[[1]]), lim[[3]], lim[[2]])
    }
    if (!is.null(too_many)) return(t2_message_plot(too_many, fig_width = fig_width, title_size = title_size))
    ## ctx$keep: the Filter tab's surviving sample ids (NULL = no restriction); ctx$rules: the sample choice
    data = gitr_memo(list.of.markers, cohort = cohort, nonormal = nonormal, noheme = noheme, ctx = ctx)

    ## build data summary before any transformations
    summary_lines = c()
    summary_lines = c(summary_lines, sprintf("Total samples after filters: %d", nrow(data)))
    ## samples with a value for every plotted x and y: the rows the plot shows
    plot_vars = unique(c(x, y))
    plot_vars = plot_vars[plot_vars %in% colnames(data)]
    complete_xy = if (length(plot_vars) > 0) complete.cases(data[, plot_vars, drop = FALSE]) else NULL
    fill_info = t2_fill_of(data, rows = complete_xy)   # the values answer's word on not-detected values, among the rows shown
    summary_lines = c(summary_lines, t2_fill_summary(fill_info))
    ## per-variable completeness
    all_vars = unique(c(x, y, color, shape, size, facet, active_condition))
    all_vars = all_vars[all_vars != "" & all_vars %in% colnames(data)]
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
    if (length(plot_vars) > 0) {
        n_complete = sum(complete_xy)
        n_missing = nrow(data) - n_complete
        summary_lines = c(summary_lines, "",
            sprintf("Samples with data for both X and Y: %d / %d", n_complete, nrow(data)),
            sprintf("Samples missing X and/or Y:         %d", n_missing))
    }
    ## all aesthetic variables
    all_aes_vars = unique(c(x, y, color, size, facet))
    all_aes_vars = all_aes_vars[all_aes_vars != "" & all_aes_vars %in% colnames(data)]
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

    ## Y probes plotted individually are stacked into one column. A probe that is
    ## also X, color, size or a graph variable cannot be stacked away, and a
    ## column holds one type: drop what does not fit, with a note.
    if (length(y) > 1 && multi_y) {
        clash = intersect(y, c(if (length(x) == 1) x, color, size, facet))
        if (length(clash) > 0) {
            warnings = c(warnings, paste("Plotted individually, a Y variable cannot also be X, color, size or a graph variable. Dropping from Y:",
                                         label_vars(clash)))
            y = setdiff(y, clash)
        }
        if (length(y) > 1 && length(unique(sapply(y, is_num))) > 1) {
            non_num_y = y[!sapply(y, is_num)]
            warnings = c(warnings, paste("Individual Y plots need one type; keeping the numeric ones. Dropping:", label_vars(non_num_y)))
            y = setdiff(y, non_num_y)
        }
        if (length(y) == 0) y = orig_y[1]
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
    x_title = x; y_title = y     # the variables as the title names them (before they are combined)
    if(length(x) > 1) {
        newvar = paste(x, sep = '.', collapse = '.')
        ## the median over the X probes of their z-scores, per sample (NA-aware)
        data[ , newvar]  = t2_row_medians(scale(as.matrix(data[, x, drop = FALSE])))
        x = newvar
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
            facet = facet[facet != ""]
        } else {
            ## color by probe identity, no auto-faceting
            color = "probe"
        }
    }
    ## will we need to remove NAs from X and possibly Y? ggplot might take care of it
    if( allComplete ) {
        ## only require completeness on the cohort and sample-type handles the
        ## dataset has (/meta `handles`), and on columns that exist in the data
        complete_cols = intersect(c("sample", t2_handle_names(ctx, c("cohort", "sample_type")), x, y, color, size, c(facet)),
                                  colnames(data))
        data = data[ complete.cases( data[ , complete_cols, drop = FALSE] ), ]
    }
    ## the levels of the columns the plot uses (the rest of the frame is not drawn)
    data = t2_droplevels_cols(data, unique(c(x, y, color, shape, size, facet, condition, "probe")))
    if ( nrow(data) == 0 | is.null(data[,x]) | is.null(data[, y]) ) {
        return( list(
            plot = ggplot() + ggtitle("Sorry, there seems to be no data associated with your query",
                subtitle = "Hint: some of the subtype classifications are only applied across some tumor samples, some mutations aren't present, etc" ),
            summary = plot_summary
        ))
    }
    ## more graphs or categories than one request may draw (T2_LIMITS): say so
    ## in the plot area instead of drawing for minutes
    refusal = t2_plot_refusal(data, x = x, y = y, color = color, size = size, facet = facet,
                              n_probes = if (isTRUE(multi_y)) length(orig_y) else 0)
    if (!is.null(refusal)) return(t2_message_plot(refusal$msg, summary = plot_summary, hint = refusal$hint,
                                                  fig_width = fig_width, title_size = title_size))
    ## I really need to deal with formulae generally
    if( evaluate_vars ) {
        list.of.markersxy = unlist(strsplit( c(x,y), split = " " ))
        list.of.markersxy = list.of.markersxy[! list.of.markersxy  %in% c('+', '-')]
    } else {
        list.of.markersxy = c(x,y)
    }

    ################################################################
    ## apply conditioning — individually for each numeric x/y variable
    unadjusted = c()     # variables (or probes) whose conditioning fit was not possible
    if (!is.null(condition) & pcortype != 'none' & is.null(conditioning_msg)) {
        ## get numeric vars to condition (excluding skipped non-numerics)
        cond_x_vars = if (pcortype == 'x' | pcortype == 'both') setdiff(x, cond_skip_x) else c()
        cond_y_vars = if (pcortype == 'y' | pcortype == 'both') setdiff(y, cond_skip_y) else c()
        all_cond_vars = unique(c(cond_x_vars, cond_y_vars, condition))
        data = data[ complete.cases( data[ , all_cond_vars ] ), ]
        ## residualize each conditioned var on the covariates (shared helper)
        ## With 'Plot Y probes individually' the Y values of all probes are stacked
        ## in one column: each probe gets its OWN regression (one pooled fit would
        ## mostly remove the differences between probes, and what is plotted would
        ## not be any probe's residuals).
        stacked_y = length(orig_y) > 1 && isTRUE(multi_y) && "probe" %in% colnames(data)
        for (v in c(cond_y_vars, cond_x_vars)) {
            if (stacked_y && identical(v, "y_value")) {
                for (pr in unique(as.character(data$probe))) {
                    i = which(data$probe == pr)
                    r = residualize_on( data[i, v], data[ i, condition, drop = FALSE] )
                    if (identical(attr(r, "adjusted"), FALSE)) unadjusted = c(unadjusted, pr)
                    data[i, v] = as.numeric(r)
                }
            } else {
                r = residualize_on( data[, v], data[ , condition, drop = FALSE] )
                if (identical(attr(r, "adjusted"), FALSE)) unadjusted = c(unadjusted, v)
                data[, v] = as.numeric(r)
            }
        }
        if (length(unadjusted))
            warnings = c(warnings, paste("Not adjusted (the fit was not possible) in:", paste(unique(unadjusted), collapse = ", ")))
    }
    ## check for waterfall
    if(waterfall){
      ## ordering the categories of X by Y: only defined for a categorical X and a numeric Y
      if (!is.numeric(data[, x]) && is.numeric(data[, y])) {
        data[,x] = forcats::fct_reorder(as.factor(data[,x]),data[,y], .desc = waterfall_flip)
      } else {
        warnings = c(warnings, "Waterfall needs a categorical X and a numeric Y; it was ignored.")
      }
    }
    ################################################################
    ## convert mutations to factors
    ## A factor type with numeric levels (.mut 0/1) is plotted with its FULL level
    ## set, so an absent level still shows as an empty group (DATASET-CONTRACT.md
    ## s.3 rule 6). The full set of a type is not in /meta, so for now the rule is
    ## keyed on the naming convention of the one such type, mut (0/1); a general
    ## rule needs `datatypes.levels` in the contract (REVIEW-2026-10-19-generalization.md 5).

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
    psub = paste(psub, paste0(ctx$label, "."))
    ## the title words of the data types come from /meta `type_labels` (t2_title_name)
    pstring = paste( "Relationship of", paste(t2_title_name(x_title, ctx), collapse = "."), "and",
                     paste(t2_title_name(y_title, ctx), collapse = "."), "across", ctx$label )
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
    if( is.factor(data[, x]) ) {
        ## boxplot + jittered points for categorical x
        jw = G('jitter.width', 0.2)
        box_args = list(outlier.shape = NA, linewidth = G('boxplot.linewidth', 0.5),
                        notch = identical(G('boxplot.notch', 'FALSE'), 'TRUE'),
                        varwidth = identical(G('boxplot.varwidth', 'FALSE'), 'TRUE'))
        if (!is.null(gg[['boxplot.width']])) box_args$width = gg[['boxplot.width']]
        if (!is.null(y) && is.factor(data[, y])) {
            ## two categorical variables: a count table drawn as circles sized by
            ## the number of samples, the number written on each (a box plot of
            ## a category means nothing)
            p = p + geom_count(alpha = alpha, colour = if (is.null(color)) "#3B7DB4" else NULL) +
                geom_text(stat = "sum", aes(label = after_stat(n), size = NULL), vjust = -1.1, size = 3) +
                scale_size_area(max_size = 14, name = "samples")
        } else if (multi_y_fill) {
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
            ## loess is O(n^2): above T2_LIMITS$loess_points points the fit is a straight line
            ## (the fit is one line over all the points, not one per group)
            sm_method = G('smooth.method', 'lm')
            n_fit = sum(stats::complete.cases(data[, c(x, y), drop = FALSE]))
            if (identical(sm_method, 'loess') && n_fit > T2_LIMITS$loess_points) {
                sm_method = 'lm'
                warnings = c(warnings, sprintf("loess needs <= %d points; a linear fit is drawn (%d points).",
                                               T2_LIMITS$loess_points, n_fit))
            }
            sm_args = list(mapping = aes_q(x = as.name(x), y = as.name(y)), formula = y ~ x,
                           alpha = G('smooth.alpha', 0.25), fullrange = FALSE,
                           method = sm_method,
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
    cap = t2_caption_text(c(filter_caption, if (isTRUE(fill_caption)) t2_fill_caption(fill_info, ctx)), caption, fig_width, 0.75 * base_size)
    if (nzchar(cap)) p = p + labs(caption = cap)
    ## user-supplied titles / labels (drawn literally), then every other tweak
    user_labs = gg[grep('^labs\\.', names(gg), value = TRUE)]
    if (length(user_labs)) {
        names(user_labs) = sub('^labs\\.', '', names(user_labs))
        p = p + do.call(labs, user_labs)
    }
    p = p + t2_tweak_theme(gg)
    ## "Show legend" off beats any legend.position among the settings above
    if (!isTRUE(show_legend)) p = p + theme(legend.position = "none")

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
        plot_summary = paste0(plot_summary, sprintf("\n  Conditioning: %s on %s%s", paste(orig_condition, collapse = ", "), pcortype,
                                                    if (length(unadjusted)) " (NOT applied where the fit failed, see warnings)" else ""))
    if (multi_y) plot_summary = paste0(plot_summary, "\n  Multi-Y: individual probes plotted separately")
    if (zscore_y) plot_summary = paste0(plot_summary, "\n  Z-score Y: enabled")
    if (length(warnings) > 0)
        plot_summary = paste0(plot_summary, "\n\n  WARNINGS:\n  ",
                              paste(warnings, collapse = "\n  "))

    list(plot = p, summary = plot_summary, fill = fill_info,
         warning = if (length(warnings) > 0) paste(warnings, collapse = "\n") else NULL)
}


## Download table: the same samples the plot shows -- the Select tab's cohort /
## non-tumor / heme choices plus the Filter tab's survivors (ctx$keep).
fun_table1 = function ( input, ctx = t2_default_ctx() ) {
    ##    my.input = paste ('~', paste(input$x, input$y, input$color,
    ##        input$size, input$facet, input$sep, sep = ' + ' ) ) ) )
    my.input = c( input$x, input$y, input$color, input$size, input$facet )
    my.input = setdiff( my.input, 'probe' )   # multi-Y colour handle, not a column
    ## a Kaplan-Meier plot forces nonormal (fun_plot1); its table must hold the same samples
    km = length(input$x) > 0 && input$x[1] %in% tte_names(ctx)
    gitr( my.input,
          cohort = if (length(input$cohort)) input$cohort else 'all',
          nonormal = km || isTRUE(input$nonormal), noheme = isTRUE(input$noheme),
          dbfile = ctx$path, roles = ctx$roles, keep_samples = ctx$keep, rules = ctx$rules,
          fill = ctx$fill %||% "na" )
}


## The text a visitor may see for a caught error. Errors of the data service carry
## URLs and internal host names ("t2api: HTTP 503 for /v1/...", "Couldn't connect to
## server (http://t2api:8080/...)"): those become one generic line and the detail goes
## to the log. Plotting refusals (validation messages written for users) pass unchanged.
t2_user_message = function(msg) {
    msg = paste(as.character(msg), collapse = " ")
    if (grepl("https?://|t2api|HTTP [0-9]|Couldn't connect|Timeout was reached|Failed to connect|Could not resolve|Connection (refused|reset)",
              msg, ignore.case = TRUE)) {
        message("T2 data service error: ", substr(msg, 1, 500))
        return("The data service did not answer; please retry in a moment.")
    }
    msg
}

## input: the browser's choices, already validated (sanitize_t2_input); ctx: the
## plot context (t2_plot_ctx) -- the active data source and the samples chosen
fun_plot1 = function(input, reactive = TRUE, ctx = t2_default_ctx(), gg = list(),
                     base_size = 12, base_family = "sans", caption = NULL, fig_width = NULL,
                     filter_caption = "", fill_caption = TRUE) {
    if( reactive ) {
        input = shiny::reactiveValuesToList(input)
    }
    ## only whitelisted plotter arguments (see input_validation.R); anything a
    ## client invents (facet.formula, extra, evaluate_vars, ...) is dropped
    input = input[ names(input) %in% T2_INPUT_ARGS ]
    ## remove empty input variables and names
    input = input[ ! sapply(input, is.null) ]
   input = input[ input != 'none']
    input = input[ input != '']
    input = input[ names(input) != '']
    input[ which(names(input) %in% T2_STYLE_ARGS) ] = as.numeric( input[ names(input) %in% T2_STYLE_ARGS ] )
    ## drop the dataset selector itself (not a plotter argument) and inject the
    ## plot context (the active data source, its roles, the chosen samples) AFTER
    ## the scalar-cleaning filters above (ctx is a list and must not hit `input != ''`).
    ## It is server-side only: never a browser input, so not in T2_INPUT_ARGS.
    input[['dataset']] = NULL
    input['ctx'] = list(ctx)
    ## the classic flags are not browser inputs any more: the sample choice
    ## arrives as `rules` (the survival branch below still forces nonormal)
    input$nonormal = FALSE
    input$noheme = FALSE
    ## (the Filter tab's surviving sample ids are ctx$keep and the sample choice
    ## -- data source, group, exclusions -- is ctx$rules)
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
    if (length(filter_caption) == 1 && !is.na(filter_caption) && nzchar(filter_caption)) input$filter_caption = filter_caption
    input$fill_caption = isTRUE(fill_caption)

    ## Survival mode: if X is one of the dataset's time-to-event variables (/meta
    ## `tte_variables`), draw a Kaplan-Meier plot of the Y marker's tertiles
    ## instead of a scatter.
    if (length(input$x) && input$x[1] %in% tte_names(ctx)) {
        if (!length(input$y) || !nzchar(input$y[1]))
            return(list(warning = "Survival plot: pick a Y marker to stratify into groups."))
        ## Appearance settings laid over the survival plot: fonts, legend, theme
        km_style = input[intersect(names(input), names(formals(t2_font_theme)))]
        return(tryCatch({
            km = survival_km(y = input$y, endpoint = input$x[1],
                        cohort = if (length(input$cohort)) input$cohort else "all",
                        facet  = input$facet,
                        multi_y = isTRUE(as.logical(input$multi_y)[1]),
                        n_groups = if (length(input$km_groups)) as.integer(input$km_groups[1]) else 3,
                        max_time = if (length(input$surv_max_days)) suppressWarnings(as.numeric(input$surv_max_days[1])) else 365 * 5,
                        condition = input$condition,
                        pcortype  = if (!is.null(input$pcortype)) input$pcortype else "none",
                        ## survival is the patient's: a normal-tissue sample would enter
                        ## the patient a second time with the normal tissue's marker
                        ## value, so normals are excluded whatever the checkbox says
                        nonormal = TRUE,
                        noheme = if (!is.null(input$noheme)) as.logical(input$noheme)[1] else FALSE,
                        base_size = base_size, base_family = base_family,
                        ctx = ctx)
            ## not-detected values set to 0 / the floor: said in the caption and the summary, as for a scatter
            fi = attr(km, "t2fill")
            if (length(fi$filled)) attr(km, "t2summary") = paste(c(attr(km, "t2summary"), t2_fill_summary(fi)), collapse = "\n")
            t2_style_survival(km, style = km_style, gg = gg, fig_width = fig_width,
                caption = t2_caption_text(c(filter_caption, if (isTRUE(fill_caption)) t2_fill_caption(fi, ctx)), caption, fig_width, 0.75 * base_size))
            },
            error = function(e) list(warning = paste("Survival plot:", t2_user_message(conditionMessage(e))))))
    }

    do.call(plotter, input)
}
