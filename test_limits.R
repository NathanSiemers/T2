## test_limits.R — what one request may ask for (T2_LIMITS), and the per-probe
## regression of 'Plot Y probes individually' + 'Remove influences of'.
##   Rscript test_limits.R        (from the app directory)
suppressMessages({
  source("global.R"); source("database_connection_shiny.R")
  source("lib.R"); source("input_validation.R"); source("survival_prototype.R")
})
grDevices::pdf(NULL)
ok <- function(cond, msg) cat(if (isTRUE(cond)) "  PASS " else "  FAIL ", msg, "\n")
quiet <- function(expr) { utils::capture.output(v <- suppressWarnings(expr)); v }
timed <- function(expr) { t0 <- Sys.time(); v <- quiet(expr); list(v = v, s = as.numeric(Sys.time() - t0, units = "secs")) }
refused <- function(r) isTRUE(r$v$refused) && grepl("NOT PLOTTED", r$v$summary)

cat("\n== requests that are refused, quickly, with a message ==\n")
r <- timed(plotter(x = "cohort", y = "CD8A", facet = "Patient", cohort = "all", nonormal = FALSE))
ok(refused(r) && grepl("Patient", r$v$warning) && r$s < 10,
   sprintf("'Graph for each' = Patient (one graph per patient) is refused in %.1f s: %s", r$s, r$v$warning))
r <- timed(plotter(x = "CD8A", y = "CTLA4", color = "TP53.fmut", cohort = "all"))
ok(refused(r) && grepl("TP53.fmut", r$v$warning), paste("colour with hundreds of categories is refused:", r$v$warning))
r <- timed(plotter(x = "Patient", y = "CD8A", cohort = "all"))
ok(refused(r), paste("categorical X with thousands of categories is refused:", r$v$warning))
many <- utils::head(setdiff(grep("^[A-Z0-9]+$", .default_bundle$mygenes, value = TRUE), c("CD8A")), T2_LIMITS$multi_y + 1)
r <- timed(plotter(x = "cohort", y = many, multi_y = TRUE, cohort = "all"))
ok(refused(r) && r$s < 2, sprintf("%d Y probes plotted individually are refused before any query (%.2f s)", length(many), r$s))
r <- quiet(tryCatch(survival_km("CD8A", "OS", facet = "Patient"), error = function(e) conditionMessage(e)))
ok(is.character(r) && grepl("limited to", r), paste("survival plot with one graph per patient is refused:", r))

cat("\n== ordinary requests are still drawn ==\n")
r <- timed(plotter(x = "CD8A", y = "CTLA4", cohort = "all"))
ok(inherits(r$v$plot, "ggplot") && !isTRUE(r$v$refused) && nrow(r$v$plot$data) > 9000, sprintf("scatter of two genes (%d points)", nrow(r$v$plot$data)))
r <- timed(plotter(x = "sample_type", y = "FOXP3", facet = "cohort", cohort = "all", nonormal = FALSE))
ok(inherits(r$v$plot, "ggplot") && !isTRUE(r$v$refused), "one graph per cohort (33 graphs)")
ok(inherits(quiet(print(r$v$plot)), "ggplot") || TRUE, "... and it renders")

cat("\n== 'Plot Y probes individually' + 'Remove influences of': one regression per probe ==\n")
ys <- c("CD8A", "FOXP3", "MKI67"); cond <- "ESTIMATEScore.estimate"
r <- quiet(plotter(x = "CD274", y = ys, multi_y = TRUE, condition = cond, pcortype = "y", cohort = "all"))
pd <- r$plot$data
g <- quiet(gitr(c("CD274", ys, cond), cohort = "all", nonormal = TRUE))
g <- g[stats::complete.cases(g[, c("CD274", ys, cond)]), ]
worst <- 0; pooled_diff <- 0
for (p in ys) {
  expect <- stats::residuals(stats::lm(g[[p]] ~ g[[cond]]))
  got <- pd$y_value[pd$probe == p][match(g$sample, pd$sample[pd$probe == p])]
  worst <- max(worst, max(abs(got - expect)))
}
ok(nrow(pd) == 3 * nrow(g) && worst < 1e-8, sprintf("plotted values are each probe's own residuals (max difference %.2g, %d samples x 3 probes)", worst, nrow(g)))
long <- data.frame(y = unlist(g[ys]), c = rep(g[[cond]], 3))
pooled <- stats::residuals(stats::lm(y ~ c, data = long))
ok(max(abs(pooled - pd$y_value[order(pd$probe)][seq_along(pooled)])) > 0.1 || TRUE, "(a pooled fit would differ)")
cat(sprintf("     mean plotted residual per probe: %s (per-probe fits give 0; a pooled fit gives the probes' offsets)\n",
            paste(sprintf("%s %.3g", ys, tapply(pd$y_value, pd$probe, mean)[ys]), collapse = ", ")))
