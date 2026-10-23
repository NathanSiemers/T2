## test_about_references.R -- citations on the About tab: the bundle's references, t2_reference_html,
## the methods list and the visible research-use statement.
suppressMessages({ source("global.R"); source("lib.R") })
source("t2_test_helpers.R")
cat("== bundle references ==\n")
for (d in t2_datasets()) {
  b <- load_dataset_bundle(d)
  r <- b$about$references
  ok(is.list(r), paste(d, "about$references is a list"))
  cat("  ", d, ":", length(r), "references\n")
  if (length(r)) ok(all(vapply(r, function(x) nzchar(x$title %||% "") && nzchar(x$authors %||% "") && nzchar(x$url %||% ""), NA)),
                    paste(d, "every reference has title, authors and url"))
  ok(all(c("reference_title", "reference_authors", "reference_journal", "reference_year", "reference_url") %in% names(b$types)) || nrow(b$types) == 0,
     paste(d, "types has the full-reference columns"))
}
cat("== t2_reference_html ==\n")
h <- t2_reference_html(list(title = "A <b>x</b> study", authors = "Doe J", journal = "Cell", year = 2018, url = "https://x.org/?a=1&b=2", note = "n"))
ok(grepl("<a href=", h, fixed = TRUE) && grepl('rel="noopener"', h, fixed = TRUE), "link when url set")
ok(!grepl("<b>x</b>", h, fixed = TRUE) && grepl("&lt;b&gt;", h, fixed = TRUE), "title is escaped")
ok(grepl("Cell 2018", h, fixed = TRUE), "journal and year shown")
ok(!grepl("<a ", t2_reference_html(list(title = "T", authors = "A", url = "")), fixed = TRUE), "no link without url")
ok(!grepl("<a ", t2_reference_html(list(title = "T", url = "javascript:alert(1)")), fixed = TRUE), "non-http url not linked")
ok(length(T2_METHOD_REFERENCES) >= 3 && all(vapply(T2_METHOD_REFERENCES, function(x) nzchar(x$title) && nzchar(x$url), NA)), "method references complete")
cat("== About tab statement ==\n")
appenv <- new.env(); suppressMessages(source("app.R", local = appenv))
ui_html <- as.character(appenv$ui)
ok(grepl("no medical advice", ui_html, fixed = TRUE), "About statement in the UI")
ok(grepl("not medical advice", ui_html, fixed = TRUE), "footer in the UI")
ok(grepl('uiOutput|about_references', ui_html) && grepl("about_references", ui_html, fixed = TRUE), "references output in About")
cat("== B12: hrefs are http(s) only ==\n")
ok(identical(appenv$t2_safe_href("https://x.org/a?b=1"), "https://x.org/a?b=1") && identical(appenv$t2_safe_href("javascript:alert(1)"), "") &&
   identical(appenv$t2_safe_href("data:text/html,x"), "") && identical(appenv$t2_safe_href(NA), ""), "t2_safe_href passes http(s) and nothing else")
finish("test_about_references")
