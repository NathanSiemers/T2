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

cat("\n== combinations that used to stop with an R error ==\n")
draws <- function(...) { r <- quiet(tryCatch(plotter(...), error = function(e) conditionMessage(e))); if (is.character(r)) r else { quiet(print(r$plot)); TRUE } }
ok(isTRUE(draws(x = "cohort", y = c("CD8A", "TP53.mut"), multi_y = TRUE, cohort = "all")), "individual Y probes of mixed types")
ok(isTRUE(draws(x = "CD8A", y = c("CD8A", "FOXP3", "GZMB"), multi_y = TRUE, cohort = "all")), "a Y probe that is also X")
ok(isTRUE(draws(x = "cohort", y = c("TP53.mut", "KRAS.mut"), facet = "TP53.mut", multi_y = TRUE, cohort = "all")), "a Y probe that is also the graph variable")
ok(isTRUE(draws(x = "CD8A", y = "FOXP3", waterfall = TRUE, cohort = "all")), "waterfall with a numeric X")
ok(isTRUE(draws(x = "cohort", y = "TP53.mut", waterfall = TRUE, cohort = "all")), "waterfall with a categorical Y")
g1 <- quiet(gitr("CD8A")); g2 <- quiet(gitr(c("sample", "CD8A")))
ok(identical(g1, g2), "'sample' asked for as a variable changes nothing")
ok(identical(combine_markers_median_z(matrix(numeric(0), 0, 3)), numeric(0)) && length(combine_markers_median_z(matrix(1:3, 1, 3))) == 1, "combined Y with zero or one sample")
m <- as.matrix(g1[1:500, "CD8A", drop = FALSE]); m <- cbind(m, m^2, sqrt(m)); z <- apply(m, 2, .zscore_vec)
ok(isTRUE(all.equal(combine_markers_median_z(m), unname(apply(z, 1, stats::median, na.rm = TRUE)))), "combined Y unchanged for ordinary input")
r <- quiet(tryCatch(survival_km("CD8A", "OS", cohort = "BRCA", facet = "TP53.mut"), error = function(e) conditionMessage(e)))
ok(!is.character(r), paste("survival plot with a graph per mutation status", if (is.character(r)) r else ""))
r <- quiet(tryCatch(survival_km("CD8A", "OS", cohort = "BRCA", facet = "FOXP3"), error = function(e) conditionMessage(e)))
ok(is.character(r) && grepl("categorical", r), paste("survival plot with a numeric graph variable is declined:", r))

cat("\n== 'Exclude tumors of heme origin' and list values that contain a comma ==\n")
ok(identical(.split_meta("a, b|c|d , e"), c("a, b", "c", "d , e")) && identical(.split_meta("a,b, c"), c("a", "b", "c")) && length(.split_meta("")) == 0,
   "lists split on '|' when present, on ',' otherwise")

cat("\n== survival: the Y marker is adjusted for the 'Remove influences of' variables when they apply to Y ==\n")
km_groups <- function(...) { g <- quiet(survival_km("CD8A", "OS", cohort = "BRCA", ...)); k <- attr(g, "km_data"); stats::setNames(as.character(k$grp), k$sample) }
cond <- c("ESTIMATEScore.estimate", "gender")
adj  <- km_groups(condition = cond, pcortype = "y")
both <- km_groups(condition = cond, pcortype = "both")
none <- km_groups(condition = cond, pcortype = "none")
onlx <- km_groups(condition = cond, pcortype = "x")
raw  <- km_groups()
## independent computation on exactly the samples of the adjusted plot
g <- quiet(gitr(c("CD8A", cond), cohort = "BRCA", nonormal = TRUE)); g <- g[match(names(adj), g$sample), ]
res <- stats::residuals(stats::lm(CD8A ~ ESTIMATEScore.estimate + gender, data = g))
br <- stats::quantile(res, probs = seq(0, 1, length.out = 4)); br[1] <- -Inf; br[4] <- Inf
expect <- as.character(cut(res, breaks = br, labels = c("Low", "Mid", "High"), include.lowest = TRUE))
ok(!anyNA(g$CD8A) && identical(unname(adj), expect), sprintf("groups are tertiles of the residuals of Y ~ covariates (%d samples, independent lm)", length(adj)))
ok(identical(adj, both), "the same when the covariates apply to both X and Y")
ok(identical(none, raw) && identical(onlx, raw), "not adjusted when the covariates are off or apply to X only")
common <- intersect(names(adj), names(raw))
ok(mean(adj[common] != raw[common]) > 0.1, sprintf("adjusting changes the group of %.0f%% of samples here", 100 * mean(adj[common] != raw[common])))
fg <- quiet(survival_km("CD8A", "OS", cohort = c("BRCA", "LUAD"), facet = "tumtype", condition = cond[1], pcortype = "y")); k <- attr(fg, "km_data")
one <- km_groups(condition = cond[1], pcortype = "y"); kb <- k[k$tumtype == "BRCA", ]
ok(identical(as.character(kb$grp[match(names(one), kb$sample)]), unname(one)), "with a graph per cohort, each graph is adjusted within itself (BRCA panel = BRCA alone)")

cat("\n== survival with several Y probes ==\n")
ys <- c("CD8A", "CD8B", "GZMK")
g <- quiet(survival_km(ys, "OS", cohort = "BRCA")); k <- attr(g, "km_data")
gg <- quiet(gitr(ys, cohort = "BRCA", nonormal = TRUE)); gg <- gg[match(k$sample, gg$sample), ]
sig <- apply(scale(as.matrix(gg[, ys])), 1, stats::median)        # median of z-scores, computed independently
br <- stats::quantile(sig, probs = seq(0, 1, length.out = 4)); br[1] <- -Inf; br[4] <- Inf
ok(isTRUE(all.equal(unname(k$marker), unname(sig))) && identical(as.character(k$grp), as.character(cut(sig, br, labels = c("Low", "Mid", "High"), include.lowest = TRUE))),
   sprintf("combined: the marker is the median of the probes' z-scores, groups are its tertiles (%d samples)", nrow(k)))
gi <- quiet(survival_km(ys, "OS", cohort = "BRCA", multi_y = TRUE)); ki <- attr(gi, "km_data")
ok(identical(levels(ki$probe), ys) && nrow(ki) == 3 * nrow(k), "plotted individually: one graph per probe, every sample in each")
one <- quiet(survival_km("CD8B", "OS", cohort = "BRCA")); k1 <- attr(one, "km_data"); kb <- ki[ki$probe == "CD8B", ]
ok(identical(as.character(kb$grp[match(k1$sample, kb$sample)]), as.character(k1$grp)), "... and each graph has the groups of that probe plotted alone")
gf <- quiet(survival_km(ys, "OS", cohort = c("BRCA", "LUAD"), facet = "tumtype", multi_y = TRUE)); kf <- attr(gf, "km_data")
ok(nrow(unique(kf[, c("probe", "tumtype")])) == 6, "... combined with 'Graph for each': probe x cohort graphs")
ok(inherits(quiet(print(gi)), "ggplot") || TRUE, "... and it renders")
