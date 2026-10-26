## t2_search.R
## ============================================================================
## Ranked search for the variable menus (Gene (X), Gene (Y), color, ...).
##
## Shiny's own server-side selectize answers a query with the first N names
## that CONTAIN the typed text, in table order: typing "T" or "MET" buried
## the gene itself under hundreds of other names. The service ranks instead
## (handleProbes in T2Mobile/service/cmd/t2api/main.go); this is the same
## rule in R, plugged into selectize's server-side mode:
##   the exact name first, then names that start with the text, then names
##   that contain it; within a group the shorter name first, then alphabetical.
## update_selectize_ranked() is a drop-in for updateSelectizeInput(server = TRUE).
## ============================================================================

## the matching names of `names`, ranked; at most `limit`. `low` = tolower(names),
## computed once by the caller (259,000 names take 0.2 s to lowercase: not on every keystroke)
t2_rank_matches = function(q, names, limit = 50, low = tolower(names)) {
  q = tolower(trimws(q))
  if (!nzchar(q)) return(utils::head(names, limit))
  at = grepl(q, low, fixed = TRUE)
  hit = names[at]
  if (!length(hit)) return(character(0))
  lowhit = low[at]
  grp = ifelse(lowhit == q, 0L, ifelse(startsWith(lowhit, q), 1L, 2L))
  hit = hit[order(grp, nchar(hit), hit, method = "radix")]
  utils::head(hit, limit)
}

## what the browser's selectize asks the server for (the same request Shiny's
## own handler answers): ?query=...&maxop=N&field=["label"]&value=value
.t2_selectize_json = function(data, req) {
  query = shiny::parseQueryString(req$QUERY_STRING)
  q = if (is.null(query$query)) "" else query$query
  mop = suppressWarnings(as.integer(query$maxop)); if (is.na(mop) || mop < 1) mop = 50
  mop = min(mop, 500)                                   # a client cannot ask for the whole list
  sel = attr(data, "selected_value", exact = TRUE)
  vals = as.character(data$value)
  picked = t2_rank_matches(q, vals, mop, low = attr(data, "names_lower", exact = TRUE) %||% tolower(vals))
  if (length(sel)) picked = unique(c(sel[sel %in% vals], picked))     # the selected names must be present
  rows = data[match(picked, vals), , drop = FALSE]
  res = jsonlite::toJSON(rows, dataframe = "rows", auto_unbox = FALSE)
  shiny::httpResponse(200, "application/json", enc2utf8(as.character(res)))
}

## The data object behind a selectize: the choices and their lowercase names.
## Built ONCE per menu and shared by every selector that offers it (the seven
## selectors of the Select tab); `lower` = tolower(choices) when the caller has it
## already (the bundle keeps names_lower). `num`: TRUE for the numeric variables;
## the rows then carry num = 1 and a selector created with T2_QUANT_RENDER shows
## the quantize marker (a small down-triangle) on those options
## (ANALYSIS-SPEC.md 2c: a numeric can be split into quantile groups).
t2_menu = function(choices, lower = NULL, num = NULL) {
  keep = !is.na(as.character(unlist(choices)))
  choices = as.character(unlist(choices))[keep]
  lab = if (is.null(names(choices))) choices else ifelse(nzchar(names(choices)), names(choices), choices)
  data = data.frame(label = lab, value = unname(choices), stringsAsFactors = FALSE)
  if (!is.null(num) && length(num) == length(keep)) data$num = as.integer(num[keep] %in% TRUE)
  attr(data, "names_lower") = if (!is.null(lower) && length(lower) == length(choices)) lower else tolower(data$value)
  data
}

## the selectize render option for menus with the num column: the label, then the
## muted quantize triangle on numeric rows (display only; the group count is chosen
## with the control next to the selector, never inside the dropdown)
T2_QUANT_RENDER = shiny::HTML(
  "{ option: function(item, escape) {
       return '<div class=\"option\">' + escape(item.label) +
              (item.num ? ' <span class=\"t2-quant\">\u25BE</span>' : '') + '</div>';
     } }")

## updateSelectizeInput(server = TRUE) with ranked search. `choices`: a character
## vector (names = labels, optional) or a t2_menu() object; `selected`: values.
update_selectize_ranked = function(session, inputId, choices, selected = NULL, label = NULL) {
  data = if (inherits(choices, "data.frame")) choices else t2_menu(choices)
  value = unname(as.character(unlist(selected)))
  attr(data, "selected_value") = value        # (a copy of the attributes; the columns are shared)
  msg = list(label = label, value = value, url = session$registerDataObj(inputId, data, .t2_selectize_json))
  session$sendInputMessage(inputId, msg[!vapply(msg, is.null, NA)])
}
