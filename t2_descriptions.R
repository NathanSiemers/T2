## t2_descriptions.R
## ============================================================================
## What the clinical columns mean, in words -- one file, shared with the
## service (T2Mobile/service/cmd/t2api/clinical_descriptions.tsv, served in
## /meta as clinical_descriptions). The app reads that file when it works
## from the database files, and the service's answer when it works over the
## API (t2_api_bundle), so the words are written once.
##   t2_descriptions(dataset, columns)  named character: column -> description
##   t2_describe_vars(vars, descriptions)  HTML for the Select tab: one line
##                                         per chosen clinical variable
## ============================================================================
T2_DESCRIPTIONS_TSV = "T2Mobile/service/cmd/t2api/clinical_descriptions.tsv"

t2_descriptions = function(dataset, columns) {
  if (!file.exists(T2_DESCRIPTIONS_TSV)) return(character(0))
  d = utils::read.delim(T2_DESCRIPTIONS_TSV, stringsAsFactors = FALSE, quote = "", comment.char = "", encoding = "UTF-8")
  out = character(0)
  for (i in seq_len(nrow(d))) {
    ds = trimws(strsplit(d$datasets[i], ",")[[1]])
    if (!("*" %in% ds || tolower(dataset) %in% tolower(ds))) next
    ## a dataset-specific line wins over a "*" line for the same column
    if (!is.null(out[d$column[i]]) && !is.na(out[d$column[i]]) && "*" %in% ds) next
    out[d$column[i]] = d$description[i]
  }
  out[intersect(columns, names(out))]
}

## the chosen variables that have a description, as a short help block
t2_describe_vars = function(vars, descriptions) {
  vars = unique(vars[!is.na(vars) & nzchar(vars) & vars %in% names(descriptions)])
  if (!length(vars)) return(NULL)
  shiny::tags$div(class = "t2-var-help",
    lapply(vars, function(v) shiny::tags$div(shiny::tags$b(v), ": ", descriptions[[v]])))
}
