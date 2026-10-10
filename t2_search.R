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

## the matching names of `names`, ranked; at most `limit`
t2_rank_matches = function(q, names, limit = 50) {
  q = tolower(trimws(q))
  if (!nzchar(q)) return(utils::head(names, limit))
  low = tolower(names)
  hit = names[grepl(q, low, fixed = TRUE)]
  if (!length(hit)) return(character(0))
  lowhit = tolower(hit)
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
  picked = t2_rank_matches(q, vals, mop)
  if (length(sel)) picked = unique(c(sel[sel %in% vals], picked))     # the selected names must be present
  rows = data[match(picked, vals), , drop = FALSE]
  res = jsonlite::toJSON(rows, dataframe = "rows", auto_unbox = FALSE)
  shiny::httpResponse(200, "application/json", enc2utf8(as.character(res)))
}

## updateSelectizeInput(server = TRUE) with ranked search. `choices`: a
## character vector (names = labels, optional); `selected`: values.
update_selectize_ranked = function(session, inputId, choices, selected = NULL, label = NULL) {
  choices = as.character(unlist(choices)); choices = choices[!is.na(choices)]
  lab = if (is.null(names(choices))) choices else ifelse(nzchar(names(choices)), names(choices), choices)
  data = data.frame(label = lab, value = unname(choices), stringsAsFactors = FALSE)
  value = unname(as.character(unlist(selected)))
  attr(data, "selected_value") = value
  msg = list(label = label, value = value, url = session$registerDataObj(inputId, data, .t2_selectize_json))
  session$sendInputMessage(inputId, msg[!vapply(msg, is.null, NA)])
}
