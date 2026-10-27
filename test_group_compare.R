## test_group_compare.R - the pure group-comparison layer (group_compare.R),
## contract T2Mobile/docs/ANALYSIS-SPEC.md. Every test is checked against the DIRECT R call.
##   Rscript test_group_compare.R        (from the app directory)
suppressMessages({ source("survival_prototype.R"); source("group_compare.R") })
grDevices::pdf(NULL)
nfail <- 0L
ok <- function(cond, msg) { cond <- isTRUE(cond); if (!cond) nfail <<- nfail + 1L; cat(if (cond) "  PASS " else "  FAIL ", msg, "\n") }
eq <- function(a, b, tol = 1e-12) isTRUE(all.equal(as.numeric(a), as.numeric(b), tolerance = tol))

cat("\n== tokens ==\n")
tk <- t2_quant_token("CD8A", 3)
ok(identical(tk, "t2q::3::CD8A"), "token format")
ok(identical(t2_quant_parse(tk), list(name = "CD8A", k = 3L)), "token round-trip")
ok(identical(t2_quant_parse(t2_quant_token("a::b", 4))$name, "a::b"), "name containing :: survives")
for (bad in c("t2q::99::X", "t2q::3::", "t2q::1::X", "t2q::5::X", "t2q::x::X", "CD8A", "", "t2q::3", "xt2q::3::X", "t2q::03x::X"))
  ok(is.null(t2_quant_parse(bad)), sprintf("rejects '%s'", bad))
ok(is.null(t2_quant_parse(NA_character_)) && is.null(t2_quant_parse(c("t2q::2::A", "t2q::2::B"))) && is.null(t2_quant_parse(NULL)), "rejects NA / vector / NULL")
ok(identical(t2_quant_label("X", 2), "X (halves)") && identical(t2_quant_label("X", 3), "X (tertiles)") && identical(t2_quant_label("X", 4), "X (quartiles)"), "labels")
ok(identical(t2_split_token("TP53"), "t2split::TP53") && identical(t2_split_token(), "t2split::*"), "split tokens")

cat("\n== t2_group_test vs the direct R call ==\n")
set.seed(1)
x2 <- c(round(rnorm(30, 0, 2)), round(rnorm(25, 1, 2))); g2 <- factor(rep(c("A", "B"), c(30, 25)))
r <- t2_group_test(x2, g2, "num")
w <- wilcox.test(x2 ~ g2, exact = FALSE, correct = TRUE)
ok(r$method == "Wilcoxon rank-sum" && eq(r$test$statistic, w$statistic) && eq(r$test$p, w$p.value) && is.na(r$test$df), "wilcoxon, heavy ties: W and p equal")
ok(is.na(r$test$p_bh) && identical(r$test$term, "group") && is.null(r$refused) && identical(names(r$test), c("term", "method", "statistic", "df", "p", "p_bh", "note")), "test block shape")
ok(identical(names(r$groups), c("group", "n", "median", "q1", "q3")) && eq(r$groups$median[1], median(x2[g2 == "A"])), "num groups block")
rr <- t2_group_test(x2, factor(g2, levels = c("B", "A")), "num")
ok(eq(rr$test$statistic, wilcox.test(x2 ~ factor(g2, levels = c("B", "A")), exact = FALSE)$statistic) && !eq(rr$test$statistic, r$test$statistic), "level order defines the sign of W")

x3 <- c(round(rnorm(20, 0, 1)), round(rnorm(18, .5, 1)), round(rnorm(22, 1, 2))); g3 <- factor(rep(c("L", "M", "H"), c(20, 18, 22)), levels = c("L", "M", "H"))
r <- t2_group_test(x3, g3, "num"); k <- kruskal.test(x3 ~ g3)
ok(r$method == "Kruskal-Wallis" && eq(r$test$statistic, k$statistic) && eq(r$test$df, 2) && eq(r$test$p, k$p.value), "kruskal 3 groups with ties")
r <- t2_group_test(x2, g2, "num", means = TRUE); t <- t.test(x2 ~ g2)
ok(r$method == "Welch t-test" && eq(r$test$statistic, t$statistic) && eq(r$test$df, t$parameter) && eq(r$test$p, t$p.value), "Welch t")
r <- t2_group_test(x3, g3, "num", means = TRUE); o <- oneway.test(x3 ~ g3, var.equal = FALSE)
ok(r$method == "Welch one-way ANOVA" && eq(r$test$statistic, o$statistic) && eq(r$test$df, o$parameter[1]) && eq(r$test$p, o$p.value) && grepl("denominator df", r$test$note), "Welch one-way ANOVA")
ok(t2_group_test(x2, g2, "num", means = TRUE)$method != t2_group_test(x2, g2, "num")$method, "means toggle switches family")

## chi-squared 3 x 4
set.seed(2)
gc <- factor(rep(c("a", "b", "c"), c(40, 35, 30)), levels = c("a", "b", "c"))
xc <- factor(sample(c("w", "x", "y", "z"), 105, TRUE, prob = c(.4, .3, .2, .1)), levels = c("w", "x", "y", "z"))
r <- t2_group_test(xc, gc, "cat"); cs <- suppressWarnings(chisq.test(table(gc, xc), correct = FALSE))
ok(r$method == "Pearson chi-squared" && eq(r$test$statistic, cs$statistic) && eq(r$test$df, 6) && eq(r$test$p, cs$p.value), "chi-squared 3x4")
ok(identical(names(r$groups), c("group", "level", "count", "prop")) && nrow(r$groups) == 12 && eq(sum(r$groups$prop), 3), "cat groups block long form")
ok(identical(unique(r$groups$level), c("w", "x", "y", "z")), "cat level order kept")
mk2 <- function(a, b, c, d) { g <- factor(rep(c("G1", "G2"), c(a + b, c + d))); x <- factor(c(rep("u", a), rep("v", b), rep("u", c), rep("v", d))); list(g = g, x = x) }
t1 <- mk2(5, 5, 5, 5); r <- t2_group_test(t1$x, t1$g, "cat")     # min expected exactly 5
ok(r$method == "Pearson chi-squared" && eq(r$test$p, chisq.test(table(t1$g, t1$x), correct = FALSE)$p.value), "2x2 with min expected exactly 5 -> chi-squared")
t1 <- mk2(4, 6, 5, 5); r <- t2_group_test(t1$x, t1$g, "cat")     # expected 4.5
ok(r$method == "Fisher exact" && eq(r$test$p, fisher.test(table(t1$g, t1$x))$p.value) && is.na(r$test$statistic) && is.na(r$test$df), "2x2 with min expected 4.5 -> Fisher")
t1 <- mk2(8, 2, 3, 7); r <- t2_group_test(t1$x, t1$g, "cat")
ok(r$method == "Fisher exact" && eq(r$test$p, fisher.test(table(t1$g, t1$x))$p.value), "Fisher, typical table")
t1 <- mk2(30, 10, 10, 30); ok(t2_group_test(t1$x, t1$g, "cat")$method == "Pearson chi-squared", "big 2x2 -> chi-squared")
xl <- factor(as.character(t1$x), levels = c("u", "v", "never")); r <- t2_group_test(xl, t1$g, "cat")
ok(r$method == "Pearson chi-squared" && !"never" %in% r$groups$level, "all-zero column dropped before the test")
r <- t2_group_test(factor(rep("u", 20)), factor(rep(c("a", "b"), 10)), "cat")
ok(!is.null(r$refused), "single-valued categorical refused")

## survdiff
set.seed(3)
n <- 90; gt <- factor(rep(c("Low", "Mid", "High"), each = 30), levels = c("Low", "Mid", "High"))
tm <- round(rexp(n, 1 / (rep(c(900, 700, 500), each = 30))) + 1); ev <- rbinom(n, 1, .7)
r <- t2_group_test(NULL, gt, "tte", tte = list(time = tm, event = ev)); sd <- survdiff(Surv(tm, ev) ~ gt)
ok(r$method == "Log-rank" && eq(r$test$statistic, sd$chisq) && eq(r$test$df, 2) && eq(r$test$p, pchisq(sd$chisq, 2, lower.tail = FALSE)), "log-rank, no truncation")
ok(identical(names(r$groups), c("group", "n", "events", "median_survival")) && sum(r$groups$events) == sum(ev), "tte groups block")
mx <- 600; t2 <- tm; e2 <- ev; past <- t2 > mx; e2[past] <- 0; t2[past] <- mx
r <- t2_group_test(NULL, gt, "tte", tte = list(time = tm, event = ev), max_days = mx); sd <- survdiff(Surv(t2, e2) ~ gt)
ok(eq(r$test$statistic, sd$chisq) && eq(r$test$p, pchisq(sd$chisq, 2, lower.tail = FALSE)), "log-rank with max_days truncation == survival_km rule")
ok(!eq(r$test$p, t2_group_test(NULL, gt, "tte", tte = list(time = tm, event = ev))$test$p), "truncation changes the result")
r <- t2_group_test(NULL, gt, "tte", tte = list(time = rep(10, n), event = rep(0, n)))
ok(is.list(r), "all-censored does not crash")
gn <- factor(rep(c("a", "b"), each = 20)); r <- t2_group_test(NULL, gn, "tte", tte = list(time = rep(1:20, 2), event = rep(c(1, 1, rep(0, 18)), 2)))
ok(any(r$groups$median_survival == "NR"), "median 'NR' when not reached")

cat("\n== min-n and refusals in t2_group_test ==\n")
gm <- factor(c(rep("A", 20), rep("B", 20), rep("C", 3)))
r <- t2_group_test(c(rnorm(40), 1, 2, 3), gm, "num")
ok(is.null(r$refused) && identical(r$groups$group, c("A", "B")) && grepl("C \\(n=3\\)", r$test$note) && r$method == "Wilcoxon rank-sum", "small group dropped with a note, family follows g after the drop")
r <- t2_group_test(c(rnorm(20), 1, 2, 3), factor(c(rep("A", 20), rep("B", 3))), "num")
ok(!is.null(r$refused) && is.null(r$test), "< 2 groups remain -> refused")
xna <- x2; xna[g2 == "B"][1:22] <- NA
r <- t2_group_test(xna, g2, "num"); ok(!is.null(r$refused), "NA in x counts toward min-n (listwise complete cases)")
r <- t2_group_test(x2, replace(g2, 1:3, NA), "num"); ok(r$n == 52, "NA group excluded, n reported")

cat("\n== groupings ==\n")
s <- t2_group_from_streams(list(selected = c(1L, 3L, 5L), excluded = c(2L, 4L)), 8L, "Excluded includes 2 samples missing V.")
ok(identical(levels(s$grp), c("Selected", "Excluded")) && identical(as.character(s$grp), c("Selected", "Excluded", "Selected", "Excluded", "Selected", NA, NA, NA)), "streams partition, rest = no group")
ok(s$n_universe == 5L && grepl("missing V", s$note) && identical(s$labels, c("Selected", "Excluded")), "streams universe, labels, note")
ok(!is.null(t2_group_from_streams(list(selected = 1:3, excluded = 3:4), 8L)$refused), "overlapping streams refused")
ok(nzchar(t2_group_from_streams(list(selected = 1:3, excluded = 4:5), 8L)$note), "note without missing_note")

xq <- c(1:30, NA, NA, 100:104); un <- rep(TRUE, length(xq))
q <- t2_group_quantized(xq, un, 3)
ref <- t2_quantile_groups(xq, 3)
ok(identical(as.character(q$grp), as.character(ref$grp)) && identical(q$labels, c("Low", "Mid", "High")) && is.na(q$grp[31]), "quantized k=3 == t2_quantile_groups; NA -> no group")
xd <- c(rep(0, 20), rep(1, 10), 5:14)        # duplicate quantiles
q <- t2_group_quantized(xd, rep(TRUE, 40), 3)
ok(is.null(q$refused) && identical(q$labels, c("Low", "High")) && grepl("merged", q$note), "duplicate quantiles merged -> Low/High labels by groups made")
ok(!is.null(t2_group_quantized(c(rep(0, 38), 1, 2), rep(TRUE, 40), 3)$refused), "min_n refusal")
ok(!is.null(t2_group_quantized(rep(7, 40), rep(TRUE, 40), 2)$refused), "constant variable refused")
xu <- c(1:20, 1000:1019); un <- c(rep(TRUE, 20), rep(FALSE, 20))
q <- t2_group_quantized(xu, un, 2)
ok(all(is.na(q$grp[21:40])) && q$n_universe == 20L && sum(q$grp == "Low", na.rm = TRUE) == 10 && sum(q$grp == "High", na.rm = TRUE) == 10, "universe mask respected (cuts from U only)")
ok(identical(levels(t2_group_quantized(1:40, rep(TRUE, 40), 4)$grp), paste0("Q", 1:4)), "k=4 labels Q1..Q4")

xcat <- factor(c(rep("zeta", 12), rep("alpha", 10), rep("mid", 3), rep("gone", 8), NA, NA), levels = c("zeta", "mid", "alpha", "gone", "unused"))
un <- c(rep(TRUE, 25), rep(FALSE, 8), TRUE, TRUE)
cg <- t2_group_categorical(xcat, un)
ok(identical(cg$labels, c("zeta", "alpha")) && grepl("mid \\(n=3\\)", cg$note), "served order kept, droplevels over universe, small level dropped with note")
ok(is.na(cg$grp[23]) && is.na(cg$grp[26]) && is.na(cg$grp[34]) && cg$n_universe == 27L, "dropped / outside-U / NA rows -> no group")
cg <- t2_group_categorical(c("b", "a", "b", "a", "b", "a", "b", "a", "b", "a"), rep(TRUE, 10), min_n = 5)
ok(identical(cg$labels, c("b", "a")), "character input: order of appearance")
cg <- t2_group_categorical(c("b", "a", "b", "a", "b", "a", "b", "a", "b", "a"), rep(TRUE, 10), levels = c("a", "b"))
ok(identical(cg$labels, c("a", "b")), "levels argument defines order")
ok(!is.null(t2_group_categorical(xcat, c(rep(TRUE, 12), rep(FALSE, 23)))$refused), "one group left -> refused")

cat("\n== BH and the screen ==\n")
set.seed(4)
gs <- factor(rep(c("A", "B"), each = 25))
cols <- list(strong = c(rnorm(25), rnorm(25, 3)), weak = rnorm(50), mid = c(rnorm(25), rnorm(25, .8)),
             cat1 = factor(c(rep("x", 22), rep("y", 3), rep("x", 5), rep("y", 20))), tiny = c(rep(NA, 46), 1, 2, 3, 4))
tt_time <- round(c(rexp(25, 1 / 900), rexp(25, 1 / 300))) + 1; tt_ev <- rbinom(50, 1, .8)
kinds <- c(strong = "num", weak = "num", mid = "num", cat1 = "cat", tiny = "num", surv = "tte")
sc <- t2_group_screen(names(kinds), function(v) cols[[v]], kinds, gs, tte_specs = list(surv = list(time = tt_time, event = tt_ev)))
direct <- c(strong = wilcox.test(cols$strong ~ gs, exact = FALSE)$p.value, weak = wilcox.test(cols$weak ~ gs, exact = FALSE)$p.value,
            mid = wilcox.test(cols$mid ~ gs, exact = FALSE)$p.value,
            cat1 = chisq.test(table(gs, cols$cat1), correct = FALSE)$p.value,
            surv = pchisq(survdiff(Surv(tt_time, tt_ev) ~ gs)$chisq, 1, lower.tail = FALSE))
ok(identical(names(sc), c("variable", "kind", "method", "n", "statistic", "df", "p", "p_bh", "note")), "screen columns")
ok(nrow(sc) == 6 && sc$variable[6] == "tiny" && is.na(sc$p[6]) && is.na(sc$p_bh[6]) && nzchar(sc$note[6]), "refused row sorted to the bottom, p/p_bh NA, note kept")
ok(!is.unsorted(sc$p[1:5]) && setequal(sc$variable[1:5], names(direct)), "ranked by p ascending")
ok(all(mapply(function(v, p) eq(sc$p[sc$variable == v], p), names(direct), direct)), "screen p == direct R call per variable")
ok(eq(sc$p_bh[1:5], p.adjust(sc$p[1:5], "BH")) && eq(sc$p_bh[1:5], p.adjust(direct, "BH")[sc$variable[1:5]]), "BH == p.adjust over valid p's only (m = 5)")
ok(sc$n[sc$variable == "cat1"] == 50, "n reported")
ok(sc$method[sc$variable == "surv"] == "Log-rank" && sc$kind[sc$variable == "surv"] == "tte", "tte row")
scm <- t2_group_screen(c("strong", "mid"), function(v) cols[[v]], kinds, gs, means = TRUE)
ok(all(scm$method == "Welch t-test") && eq(scm$p[scm$variable == "mid"], t.test(cols$mid ~ gs)$p.value), "means toggle honored in the screen")
ok(nrow(t2_group_screen(character(0), function(v) NULL, kinds, gs)) == 0, "empty screen")
sc2 <- t2_group_screen(c("a", "b", "c"), function(v) cols$weak, c(a = "num", b = "num", c = "num"), gs)
ok(eq(sc2$p_bh, rep(sc2$p[1], 3)), "equal p's -> equal BH")

cat("\n== plots ==\n")
ok(inherits(t2_plot_group_box(x3, g3, "Marker", "Grouping"), "ggplot"), "box plot")
ok(inherits(t2_plot_group_counts(xc, gc, "Stage", "Grouping"), "ggplot"), "counts plot")
ok(inherits(t2_plot_group_km(tm, ev, gt, "OS", list(word = "years", short = "d"), max_days = 600), "ggplot"), "km plot (truncated)")
ok(inherits(t2_plot_group_km(tm, ev, gt, "OS", "days"), "ggplot"), "km plot (untruncated, character unit)")
ok(!inherits(try(ggplot_build(t2_plot_group_km(tm, ev, gt, "OS")), silent = TRUE), "try-error"), "km plot builds")
ok(!inherits(try(ggplot_build(t2_plot_group_box(x3, g3, "M", "G")), silent = TRUE), "try-error") && !inherits(try(ggplot_build(t2_plot_group_counts(xc, gc, "S", "G")), silent = TRUE), "try-error"), "box and counts build")

cat("\n== result table (CSV) ==\n")
res <- t2_group_test(x2, g2, "num")
tb <- t2_group_result_table(res, c("Grouping: X", "Universe n: 55", "Filters: none"))
ok(is.data.frame(tb) && tb[1, 1] == "Grouping: X" && tb[4, 1] == "group" && tb[4, 2] == "n", "header then groups block")
ok(any(tb[, 1] == "") && any(tb[, 1] == "term") && any(tb[, 1] == "group" & tb[, 2] == "Wilcoxon rank-sum"), "blank line then test block")
tmp <- tempfile(); utils::write.table(tb, tmp, sep = ",", row.names = FALSE, col.names = FALSE, quote = TRUE)
ok(length(readLines(tmp)) == nrow(tb), "writes as CSV")

cat("\n== fmtp pinned strings ==\n")
pv <- c(NA, 0, -1, 1e-320, 1e-300, 1e-10, 1.234e-4, 0.00099949, 0.001, 0.0123456, 0.05, 0.5, 0.9996, 1)
fp <- vapply(pv, fmtp, "")
cat("  FMTP:", paste(sprintf("\"%s\"", fp), collapse = ", "), "\n")
want <- c("NA", "< 1e-300", "< 1e-300", "1.0e-320", "1.0e-300", "1.0e-10", "1.2e-04", "1.0e-03", "0.001", "0.0123", "0.05", "0.5", "1", "1")
ok(identical(fp, want), "fmtp strings pinned")

cat("\n== PUBLISH-UNIFY: styled plots, caption, stats text ==\n")
## the styling helpers + t2_caption_text only (lib.R as a whole needs the service)
suppressMessages(source("plot_style.R"))
for (e in parse("lib.R")) if (is.call(e) && as.character(e[[1]]) %in% c("=", "<-") && identical(as.character(e[[2]]), "t2_caption_text")) eval(e)
## (a) default calls keep today's theme: theme_minimal(12) + t2_font_theme()
th0 <- theme_minimal(base_size = 12) + t2_font_theme()
def_plots <- list(box = t2_plot_group_box(x3, g3, "Marker", "Grouping"), counts = t2_plot_group_counts(xc, gc, "Stage", "Grouping"),
                  km = t2_plot_group_km(tm, ev, gt, "OS"))
for (nm in names(def_plots)) {
  pt <- def_plots[[nm]]$theme
  ok(identical(calc_element("plot.title", pt)$size, calc_element("plot.title", th0)$size) &&
       identical(calc_element("plot.title", pt)$size, 16) && identical(calc_element("axis.text", pt)$size, 11) &&
       identical(calc_element("axis.title", pt)$size, 14) && identical(calc_element("legend.text", pt)$size, 11) &&
       identical(calc_element("text", pt)$family, calc_element("text", th0)$family), sprintf("%s: default theme = theme_minimal(12) + t2_font_theme()", nm))
  ok(is.null(def_plots[[nm]]$labels$caption), sprintf("%s: no caption by default", nm))
}
ok(identical(calc_element("legend.position", def_plots$km$theme), "bottom") && !identical(calc_element("legend.position", def_plots$counts$theme), "bottom"), "default legend positions (km bottom)")
ok(identical(.gc_theme(), th0), ".gc_theme() with defaults is exactly today's theme")
pdef <- ggplot_build(def_plots$box)$data
ok(any(vapply(def_plots$box$layers, function(l) isTRUE(l$aes_params$size == 1.2 && l$aes_params$alpha == 0.6), NA)), "box: default jitter size 1.2, alpha 0.6")
## (b) styled calls build, caption lands, geometry scales
sty <- list(point_size = 0.9, alpha = 0.5, title_size = 8, legend_size = 6)
styled <- list(
  box = t2_plot_group_box(x3, g3, "Marker", "Grouping", style = sty, gg = list("theme|plot.caption|size" = 5), caption = "x", base_size = 7, fig_width = 3.5),
  counts = t2_plot_group_counts(xc, gc, "Stage", "Grouping", style = sty, gg = list("theme|plot.caption|size" = 5), caption = "x", base_size = 7, fig_width = 3.5),
  km = t2_plot_group_km(tm, ev, gt, "OS", style = sty, gg = list("theme|plot.caption|size" = 5), caption = "x", base_size = 7, fig_width = 3.5))
for (nm in names(styled)) {
  ok(!inherits(try(ggplot_build(styled[[nm]]), silent = TRUE), "try-error"), sprintf("%s: styled call builds", nm))
  ok(identical(styled[[nm]]$labels$caption, "x"), sprintf("%s: caption lands in labels$caption", nm))
  ok(identical(calc_element("plot.title", styled[[nm]]$theme)$size, 8) && identical(calc_element("plot.caption", styled[[nm]]$theme)$size, 5),
     sprintf("%s: style title size and the caption tweak apply", nm))
}
ok(any(vapply(styled$box$layers, function(l) isTRUE(l$aes_params$size == 0.9 && l$aes_params$alpha == 0.5), NA)), "box: style point_size / alpha override the jitter")
ok(identical(styled$km$layers[[1]]$aes_params$linewidth, 1 * 7 / 12) && identical(def_plots$km$layers[[1]]$aes_params$linewidth, 1), "km: step linewidth scales by base_size / 12")
ok(identical(calc_element("text", styled$box$theme)$size, 7), "base_size reaches theme_minimal")
ok(identical(calc_element("legend.position", t2_plot_group_km(tm, ev, gt, "OS", style = list(show_legend = FALSE))$theme), "none"), "show_legend = FALSE beats the km bottom legend")
lt <- t2_plot_group_box(rep(x3, 1), g3, paste(rep("a very long variable label", 4), collapse = " "), "Grouping", fig_width = 3.5)
ok(grepl("\n", lt$labels$title), "a long title is wrapped when fig_width is given")

## (c) the caption, pinned to ANALYSIS-SPEC.md 9a
xa <- c(3,1,4,1,5,5,2,6,5,3,5,8,9,7,9,3,2,3,8,4); ga <- factor(rep(c("Selected", "Excluded"), c(9, 11)), levels = c("Selected", "Excluded"))
mksnap <- function(res, n_universe, label, note = "", filters = "Maintained filters: none beyond the Select tab.", dataset = "TCGA")
  list(label = label, g = list(n_universe = n_universe, note = note), res = res, filters = filters, dataset = dataset)
s_w <- mksnap(t2_group_test(xa, ga, "num"), 20L, "Split: cohort")
s_t <- mksnap(t2_group_test(xa, ga, "num", means = TRUE), 20L, "Split: cohort")
cap_w <- .gc_caption_sentences(s_w); cap_t <- .gc_caption_sentences(s_t)
ok(identical(cap_w[1], "Groups (Split: cohort): Selected n=9, Excluded n=11; universe n=20."), "caption 1: groups sentence (pinned)")
ok(identical(cap_w[2], "Wilcoxon rank-sum: W = 30, p = 0.145."), "caption 2: Wilcoxon (pinned)")
ok(identical(cap_t[2], "Welch t-test: t = -1.939, df = 17.6, p = 0.0687."), "caption 2: Welch t (pinned)")
tab <- rbind(c(12, 30, 18), c(25, 9, 6)); gl <- rep(c("Low", "High"), c(60, 40))
xl <- factor(c(rep(c("a", "b", "c"), c(12, 30, 18)), rep(c("a", "b", "c"), c(25, 9, 6))), levels = c("a", "b", "c"))
s_c <- mksnap(t2_group_test(xl, factor(gl, levels = c("Low", "High")), "cat"), 100L, "Split: x")
cap_c <- .gc_caption_sentences(s_c)
ok(identical(cap_c[2], "Pearson chi-squared: chi-squared = 18.62, df = 2, p = 9.1e-05."), "caption 2: Pearson chi-squared (pinned)")
ok(identical(cap_c[1], "Groups (Split: x): Low n=60, High n=40; universe n=100."), "caption 1: categorical n = sum of the group's level counts")
g6 <- factor(rep(c("treatment", "control"), c(21, 21)), levels = c("treatment", "control"))
t6 <- c(6,6,6,6,7,9,10,10,11,13,16,17,19,20,22,23,25,32,32,34,35, 1,1,2,2,3,4,4,5,5,8,8,8,8,11,11,12,12,15,17,22,23)
e6 <- c(1,1,1,0,1,0,1,0,0,1,1,0,0,0,1,1,0,0,0,0,0, rep(1, 21))
s_k <- mksnap(t2_group_test(NULL, g6, "tte", tte = list(time = t6, event = e6)), 42L, "Arm")
ok(identical(.gc_caption_sentences(s_k)[2], "Log-rank: chi-squared = 16.79, df = 1, p = 4.2e-05."), "caption 2: Log-rank (pinned)")
f2 <- mk2(4, 6, 5, 5); s_f <- mksnap(t2_group_test(f2$x, f2$g, "cat"), 20L, "Arm")
ok(grepl("^Fisher exact: p = [0-9.e-]+\\.$", .gc_caption_sentences(s_f)[2]) && grepl("^Expected count below 5", .gc_caption_sentences(s_f)[3]), "Fisher: no statistic clause; the test note is its own sentence")
ok(identical(cap_w[3:4], c("Maintained filters: none beyond the Select tab.", "Data: TCGA.")), "caption 4-5: filters and data")
ok(identical(t2_analysis_caption(s_w, source_line = "SRC"), paste(c(cap_w, "SRC"), collapse = "\n")), "t2_analysis_caption: unwrapped sentences + source line")
wr <- t2_analysis_caption(s_w, fig_width = 3.5, size = 9)
ok(grepl("\n", wr) && identical(gsub("\n", " ", wr), paste(cap_w, collapse = " ")), "t2_analysis_caption: wrapped to the figure width")

## (d) the stats text
tx <- t2_analysis_text(s_w)
ok(grepl("^# T2 analysis: TCGA, [0-9]{4}-[0-9]{2}-[0-9]{2}\\.$", tx[1]) && tx[2] == "" && identical(tx[3:6], cap_w), "text: header, blank, caption sentences")
ok(tx[7] == "" && grepl("^group +n +median +q1 +q3$", tx[8]), "text: blank then the aligned groups block")
bl <- which(tx == ""); th_i <- bl[3] + 1L
ok(length(bl) == 3 && grepl("^term +method +statistic +df +p +p_bh +note +p_text$", tx[th_i]) && grepl("Wilcoxon rank-sum", tx[th_i + 1L]) && grepl(paste0(fmtp(s_w$res$test$p), "$"), tx[th_i + 1L]),
   "text: aligned test block with the p_text column")
ok(length(tx) == 13, "text: line count (header, caption, two blocks)")

cat(sprintf("\n%d failure(s)\n", nfail))
if (nfail > 0) quit(status = 1)
