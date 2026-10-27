## group_compare.R
## ============================================================================
## Pure R layer of the Analysis panel (group comparison + clinical screen).
## Contract: T2Mobile/docs/ANALYSIS-SPEC.md (sections 2-5). No shiny, no network,
## no app state: groupings, tests, the screen, plots and the CSV table are plain
## functions of vectors, so they can be tested alone and mirrored in Swift.
## R is its own reference: every test is a direct call of stats / survival.
##
## A grouping is list(grp = factor over ALL rows (NA = in no group), labels,
## n_universe, note) or list(refused = <message>).
## A test result is list(groups, test, method, n, refused); `test` is the tidy
## frame term/method/statistic/df/p/p_bh/note (model mode will append rows).
## ============================================================================

suppressMessages({ library(survival); library(ggplot2) })
if (!exists("fmtp") || !exists("t2_quantile_groups") || !exists("t2_km_palette")) source("survival_prototype.R")

`%||%` <- function(a, b) if (is.null(a)) b else a

## ---------------------------------------------------------------- tokens ----
t2_quant_token <- function(name, k) paste0("t2q::", as.integer(k), "::", name)

## strict: "t2q::<k>::<name>", k in 2..4, non-empty name -> list(name, k), else NULL
t2_quant_parse <- function(v) {
  if (!is.character(v) || length(v) != 1L || is.na(v)) return(NULL)
  m <- regmatches(v, regexec("^t2q::([0-9]+)::(.+)$", v))[[1]]
  if (length(m) != 3L) return(NULL)
  k <- suppressWarnings(as.integer(m[2]))
  if (is.na(k) || !k %in% 2:4 || !nzchar(m[3])) return(NULL)
  list(name = m[3], k = k)
}

t2_quant_label <- function(name, k) {
  sprintf("%s (%s)", name, switch(as.character(k), "2" = "halves", "3" = "tertiles", "4" = "quartiles", sprintf("%d groups", k)))
}

t2_split_token <- function(col = NULL) paste0("t2split::", if (is.null(col)) "*" else col)

## ------------------------------------------------------------- groupings ----
## streams = list(selected = <row ids>, excluded = <row ids>) (Thanos th$streams shape)
t2_group_from_streams <- function(streams, n, missing_note = NULL) {
  sel <- as.integer(streams$selected); exc <- as.integer(streams$excluded)
  if (length(intersect(sel, exc))) return(list(refused = "the Selected and Excluded samples overlap"))
  if (any(c(sel, exc) < 1L | c(sel, exc) > n, na.rm = TRUE)) return(list(refused = "a sample id is outside the sample list"))
  grp <- factor(rep(NA_character_, n), levels = c("Selected", "Excluded"))
  grp[sel] <- "Selected"; grp[exc] <- "Excluded"
  note <- sprintf("Selected %d, Excluded %d.", length(sel), length(exc))
  if (length(missing_note) && nzchar(missing_note[1])) note <- paste(note, paste(missing_note, collapse = " "))
  list(grp = grp, labels = levels(grp), n_universe = length(sel) + length(exc), note = note)
}

## x numeric (full length), universe logical mask (all current filters), k in 2:4
t2_group_quantized <- function(x, universe, k, min_n = 5L) {
  universe <- universe & TRUE; universe[is.na(universe)] <- FALSE
  xv <- suppressWarnings(as.numeric(as.character(x)))
  qg <- t2_quantile_groups(xv[universe], k, min_n = min_n)
  if (is.null(qg)) return(list(refused = "the variable has fewer than 2 distinct values among the selected samples, so it cannot be split into groups"))
  if (!is.null(qg$refused)) return(list(refused = qg$refused))
  grp <- factor(rep(NA_character_, length(xv)), levels = levels(qg$grp))
  grp[universe] <- as.character(qg$grp)
  note <- sprintf("Cut points from %d samples with a value (%d samples in the universe).", sum(!is.na(xv[universe])), sum(universe))
  if (qg$n < k) note <- paste(note, sprintf("Equal values merged cut points: %d groups made instead of %d.", qg$n, k))
  list(grp = grp, labels = levels(qg$grp), n_universe = sum(universe), note = note)
}

## x categorical (factor / character, full length); levels = served order
t2_group_categorical <- function(x, universe, levels = NULL, min_n = 5L) {
  universe <- universe & TRUE; universe[is.na(universe)] <- FALSE
  xc <- as.character(x)
  lv <- levels %||% (if (is.factor(x)) base::levels(x) else unique(xc[!is.na(xc)]))
  present <- unique(xc[universe & !is.na(xc)])
  lv <- lv[lv %in% present]
  note <- ""
  if (length(lv)) {
    cnt <- vapply(lv, function(l) sum(universe & !is.na(xc) & xc == l), numeric(1))
    small <- cnt < min_n
    if (any(small)) {
      note <- sprintf("Dropped (fewer than %d samples): %s.", min_n,
                      paste(sprintf("%s (n=%d)", lv[small], as.integer(cnt[small])), collapse = ", "))
      lv <- lv[!small]
    }
  }
  if (length(lv) < 2L) return(list(refused = paste0("fewer than 2 groups with at least ", min_n, " samples remain.",
                                                    if (nzchar(note)) paste0(" ", note) else "")))
  grp <- factor(ifelse(universe, xc, NA_character_), levels = lv)
  list(grp = grp, labels = lv, n_universe = sum(universe), note = note)
}

## ----------------------------------------------------------------- tests ----
.gc_refuse <- function(msg, n = NA_integer_) list(groups = NULL, test = NULL, method = NA_character_, n = n, refused = msg)

.gc_result <- function(groups, method, statistic, df, p, note, n) {
  list(groups = groups,
       test = data.frame(term = "group", method = method, statistic = as.numeric(statistic), df = as.numeric(df),
                         p = as.numeric(p), p_bh = NA_real_, note = note, stringsAsFactors = FALSE),
       method = method, n = n, refused = NULL)
}

## follow-up truncated exactly as survival_km: time > max -> time = max, event = 0
.gc_truncate <- function(time, event, max_days) {
  if (!is.null(max_days) && is.finite(max_days) && max_days > 0) {
    past <- !is.na(time) & time > max_days
    event[past] <- 0; time[past] <- max_days
  }
  list(time = time, event = event)
}

.gc_km_median <- function(time, event, grp) {
  fit <- survfit(Surv(time, event) ~ grp)
  tb <- summary(fit)$table
  med <- if (is.matrix(tb)) tb[, "median"] else tb["median"]
  unname(med)
}

t2_group_test <- function(x, grp, kind, means = FALSE, tte = NULL, max_days = Inf, min_n = 5L) {
  grp <- if (is.factor(grp)) grp else factor(grp)
  if (kind == "tte") {
    if (is.null(tte)) return(.gc_refuse("no time-to-event data"))
    tt <- .gc_truncate(suppressWarnings(as.numeric(tte$time)), suppressWarnings(as.numeric(tte$event)), max_days)
    ok <- !is.na(grp) & !is.na(tt$time) & !is.na(tt$event) & tt$time > 0
  } else {
    ok <- !is.na(grp) & !is.na(x)
  }
  n_cc <- sum(ok)
  g <- droplevels(grp[ok])
  ## min-n floor after complete cases
  cnt <- table(g)
  note <- ""
  small <- names(cnt)[cnt < min_n]
  if (length(small)) {
    note <- sprintf("Dropped (fewer than %d samples): %s.", min_n,
                    paste(sprintf("%s (n=%d)", small, as.integer(cnt[small])), collapse = ", "))
    keep <- !(as.character(g) %in% small)
    ok[which(ok)[!keep]] <- FALSE
    g <- droplevels(g[keep])
  }
  if (nlevels(g) < 2L) return(.gc_refuse(paste0("fewer than 2 groups with at least ", min_n, " samples.",
                                                if (nzchar(note)) paste0(" ", note) else ""), n_cc))
  n <- sum(ok)
  gl <- levels(g)
  join <- function(...) { s <- c(...); paste(s[nzchar(s)], collapse = " ") }

  if (kind == "num") {
    xv <- suppressWarnings(as.numeric(x[ok]))
    groups <- do.call(rbind, lapply(gl, function(l) {
      v <- xv[g == l]; q <- stats::quantile(v, c(0.25, 0.5, 0.75), names = FALSE)
      data.frame(group = l, n = length(v), median = q[2], q1 = q[1], q3 = q[3], stringsAsFactors = FALSE)
    }))
    r <- tryCatch(suppressWarnings(
      if (nlevels(g) == 2L && !means) {
        h <- stats::wilcox.test(xv ~ g, exact = FALSE, correct = TRUE)
        list("Wilcoxon rank-sum", unname(h$statistic), NA, h$p.value, "")
      } else if (!means) {
        h <- stats::kruskal.test(xv ~ g)
        list("Kruskal-Wallis", unname(h$statistic), unname(h$parameter), h$p.value, "")
      } else if (nlevels(g) == 2L) {
        h <- stats::t.test(xv ~ g)
        list("Welch t-test", unname(h$statistic), unname(h$parameter), h$p.value, "")
      } else {
        h <- stats::oneway.test(xv ~ g, var.equal = FALSE)
        list("Welch one-way ANOVA", unname(h$statistic), unname(h$parameter[1]), h$p.value,
             sprintf("denominator df = %.3g", unname(h$parameter[2])))
      }), error = function(e) conditionMessage(e))
    if (is.character(r)) return(.gc_refuse(paste0("the test could not be computed: ", r), n))
    return(.gc_result(groups, r[[1]], r[[2]], r[[3]], r[[4]], join(note, r[[5]]), n))
  }

  if (kind == "cat") {
    xf <- droplevels(factor(as.character(x[ok]), levels = intersect(
      if (is.factor(x)) levels(x) else unique(as.character(x[ok])), unique(as.character(x[ok])))))
    tab <- table(group = g, level = xf)
    tab <- tab[rowSums(tab) > 0, colSums(tab) > 0, drop = FALSE]
    if (nrow(tab) < 2L || ncol(tab) < 2L) return(.gc_refuse("the variable has a single value among the compared groups, so there is nothing to test", n))
    groups <- do.call(rbind, lapply(rownames(tab), function(l)
      data.frame(group = l, level = colnames(tab), count = as.integer(tab[l, ]),
                 prop = as.numeric(tab[l, ]) / sum(tab[l, ]), stringsAsFactors = FALSE)))
    rownames(groups) <- NULL
    cs <- suppressWarnings(stats::chisq.test(tab, correct = FALSE))
    if (all(dim(tab) == 2L) && any(cs$expected < 5)) {
      h <- stats::fisher.test(tab)
      return(.gc_result(groups, "Fisher exact", NA, NA, h$p.value, join(note, "Expected count below 5 in a 2x2 table."), n))
    }
    return(.gc_result(groups, "Pearson chi-squared", unname(cs$statistic), unname(cs$parameter), cs$p.value, note, n))
  }

  if (kind == "tte") {
    tm <- tt$time[ok]; ev <- tt$event[ok]
    med <- .gc_km_median(tm, ev, g)
    groups <- data.frame(group = gl, n = as.integer(table(g)),
                         events = vapply(gl, function(l) as.integer(sum(ev[g == l])), integer(1)),
                         median_survival = ifelse(is.na(med), "NR", as.character(round(med))),
                         stringsAsFactors = FALSE, row.names = NULL)
    r <- tryCatch({
      sd <- survival::survdiff(Surv(tm, ev) ~ g)
      dfv <- length(sd$n) - 1
      list(unname(sd$chisq), dfv, stats::pchisq(sd$chisq, dfv, lower.tail = FALSE))
    }, error = function(e) conditionMessage(e))
    if (is.character(r)) return(.gc_refuse(paste0("the test could not be computed: ", r), n))
    return(.gc_result(groups, "Log-rank", r[[1]], r[[2]], r[[3]], note, n))
  }
  .gc_refuse(paste0("unknown variable kind '", kind, "'"), n)
}

## ---------------------------------------------------------------- screen ----
t2_group_screen <- function(vars, get_col, kinds, grp, means = FALSE, tte_specs = list(), max_days = Inf) {
  rows <- lapply(vars, function(v) {
    kd <- unname(kinds[v])
    r <- tryCatch(
      if (kd == "tte") t2_group_test(NULL, grp, "tte", tte = tte_specs[[v]], max_days = max_days)
      else t2_group_test(get_col(v), grp, kd, means = means),
      error = function(e) .gc_refuse(conditionMessage(e)))
    if (is.null(r$refused)) {
      t <- r$test
      data.frame(variable = v, kind = kd, method = t$method, n = r$n, statistic = t$statistic, df = t$df,
                 p = t$p, p_bh = NA_real_, note = t$note, stringsAsFactors = FALSE)
    } else {
      data.frame(variable = v, kind = kd, method = NA_character_, n = as.integer(r$n), statistic = NA_real_, df = NA_real_,
                 p = NA_real_, p_bh = NA_real_, note = r$refused, stringsAsFactors = FALSE)
    }
  })
  out <- if (length(rows)) do.call(rbind, rows) else
    data.frame(variable = character(), kind = character(), method = character(), n = integer(), statistic = numeric(),
               df = numeric(), p = numeric(), p_bh = numeric(), note = character(), stringsAsFactors = FALSE)
  ok <- !is.na(out$p)
  out$p_bh[ok] <- stats::p.adjust(out$p[ok], method = "BH")
  out <- out[order(is.na(out$p), out$p, seq_len(nrow(out))), , drop = FALSE]
  rownames(out) <- NULL
  out
}

## ----------------------------------------------------------------- plots ----
## Defaults reproduce the on-screen look exactly; a styled call (Publish) passes the shared
## Appearance style, a base size (k = base_size / 12 scales the geometry) and a figure width.
.gc_theme <- function(style = NULL, base_size = 12, base_family = "sans") {
  if (is.null(style) && identical(base_size, 12) && identical(base_family, "sans")) {
    th <- theme_minimal(base_size = 12)
    if (exists("t2_font_theme")) th <- th + t2_font_theme()
    return(th)
  }
  th <- theme_minimal(base_size = base_size, base_family = base_family)
  if (exists("t2_font_theme"))
    th <- th + do.call(t2_font_theme, as.list(style)[intersect(names(style), names(formals(t2_font_theme)))])
  th
}

## title wrapped to the figure (as t2_style_survival does); NULL fig_width = unchanged
.gc_title <- function(txt, style, fig_width) {
  if (is.null(fig_width)) return(txt)
  t2_wrap_text(txt, fig_width, if (is.null(style$title_size)) 12 else style$title_size)
}

## the last touches of a styled plot: the legend switch (beats legend.position), legend columns,
## the caption, and the validated theme tweaks LAST (they win over everything)
.gc_finish <- function(p, style, gg, caption) {
  if (identical(style$show_legend, FALSE)) p <- p + theme(legend.position = "none")
  if (!is.null(gg[["legend.ncol"]])) {
    n <- as.integer(gg[["legend.ncol"]])
    p <- p + guides(colour = guide_legend(ncol = n), fill = guide_legend(ncol = n))
  }
  if (length(caption) == 1 && !is.na(caption) && nzchar(caption)) p <- p + labs(caption = caption)
  if (length(gg)) p <- p + t2_tweak_theme(gg)
  p
}

.gc_labels_n <- function(g) {
  n <- table(g)
  factor(g, levels = levels(g), labels = sprintf("%s\n(n=%d)", levels(g), as.integer(n[levels(g)])))
}

t2_plot_group_box <- function(x, grp, var_label, group_label, style = NULL, gg = list(), caption = NULL,
                              base_size = 12, base_family = "sans", fig_width = NULL) {
  k <- base_size / 12
  ok <- !is.na(grp) & !is.na(x)
  g <- droplevels(grp[ok]); d <- data.frame(x = as.numeric(x[ok]), g = .gc_labels_n(g))
  pal <- t2_km_palette(nlevels(g))
  pt <- if (is.null(style$point_size)) 1.2 * k else style$point_size
  al <- if (is.null(style$alpha)) 0.6 else style$alpha
  p <- ggplot(d, aes(g, x, colour = g, fill = g)) +
    geom_boxplot(alpha = 0.15, outlier.shape = NA, width = 0.55) +
    geom_jitter(width = 0.15, height = 0, size = pt, alpha = al) +
    scale_colour_manual(values = pal, guide = "none") + scale_fill_manual(values = pal, guide = "none") +
    labs(x = group_label, y = var_label, title = .gc_title(sprintf("%s by %s", var_label, group_label), style, fig_width)) +
    .gc_theme(style, base_size, base_family)
  .gc_finish(p, style, gg, caption)
}

t2_plot_group_counts <- function(x, grp, var_label, group_label, style = NULL, gg = list(), caption = NULL,
                                 base_size = 12, base_family = "sans", fig_width = NULL) {
  k <- base_size / 12
  ok <- !is.na(grp) & !is.na(x)
  g <- droplevels(grp[ok]); lv <- if (is.factor(x)) levels(droplevels(x[ok])) else unique(as.character(x[ok]))
  d <- as.data.frame(table(g = .gc_labels_n(g), level = factor(as.character(x[ok]), levels = lv)), responseName = "count")
  p <- ggplot(d, aes(g, count, fill = level)) +
    geom_col(position = "fill", width = 0.7) +
    geom_text(aes(label = ifelse(count > 0, count, "")), position = position_fill(vjust = 0.5), size = 3.2 * k) +
    scale_y_continuous(labels = function(v) paste0(round(100 * v), "%")) +
    labs(x = group_label, y = "Proportion", fill = var_label,
         title = .gc_title(sprintf("%s by %s", var_label, group_label), style, fig_width)) +
    .gc_theme(style, base_size, base_family)
  .gc_finish(p, style, gg, caption)
}

t2_plot_group_km <- function(time, event, grp, endpoint_label, unit = list(word = "days", short = "d"), max_days = Inf,
                             style = NULL, gg = list(), caption = NULL, base_size = 12, base_family = "sans",
                             fig_width = NULL) {
  k <- base_size / 12
  if (is.character(unit)) unit <- list(word = unit, short = "")
  tt <- .gc_truncate(as.numeric(time), as.numeric(event), max_days)
  ok <- !is.na(grp) & !is.na(tt$time) & !is.na(tt$event) & tt$time > 0
  g <- droplevels(grp[ok]); tm <- tt$time[ok]; ev <- tt$event[ok]
  fit <- survfit(Surv(tm, ev) ~ g)
  med <- .gc_km_median(tm, ev, g)
  leg <- sprintf("%s  (med %s)", levels(g), ifelse(is.na(med), "NR", paste0(round(med), unit$short)))
  sf <- summary(fit, censored = FALSE)
  st <- sub("^g=", "", as.character(sf$strata))
  d <- rbind(data.frame(g = levels(g), time = 0, surv = 1),
             data.frame(g = st, time = sf$time, surv = sf$surv))
  d$g <- factor(d$g, levels = levels(g), labels = leg)
  xmax <- if (is.finite(max_days) && max_days > 0) max_days else max(tm)
  p <- ggplot(d, aes(time, surv, colour = g)) + geom_step(linewidth = 1 * k) +
    scale_colour_manual(values = t2_km_palette(nlevels(g))) +
    coord_cartesian(xlim = c(0, xmax), ylim = c(0, 1)) +
    labs(x = sprintf("Time (%s)", unit$word), y = sprintf("%s probability", endpoint_label), colour = NULL,
         title = .gc_title(sprintf("%s by group", endpoint_label), style, fig_width)) +
    .gc_theme(style, base_size, base_family) + theme(legend.position = "bottom")
  .gc_finish(p, style, gg, caption)
}

## ------------------------------------------------------------------- CSV ----
## header = character lines (grouping name, universe n, maintained filters); then the
## groups block, a blank line, the test block. One data.frame of strings, written
## with write.table(col.names = FALSE) by the caller (rows are ragged by design).
t2_group_result_table <- function(res, header) {
  blocks <- c(list(res$groups), list(NULL), list(res$test))
  hdr <- as.character(header)
  w <- max(ncol(res$groups), ncol(res$test), 1L)
  pad <- function(v) { v <- as.character(v); length(v) <- w; v[is.na(v)] <- ""; v }
  rowsof <- function(df) c(list(pad(names(df))), lapply(seq_len(nrow(df)), function(i) pad(unlist(lapply(df[i, ], function(z) if (is.numeric(z)) format(z, digits = 6) else as.character(z))))))
  lines <- c(lapply(hdr, pad), rowsof(res$groups), list(pad("")), rowsof(res$test))
  out <- as.data.frame(do.call(rbind, lines), stringsAsFactors = FALSE)
  names(out) <- paste0("V", seq_len(w))
  out
}

## ----------------------------------------------------- caption + stats text ----
## Contract: ANALYSIS-SPEC.md section 9a (R is the reference; Swift pins literals).
## `snap` = the analysis_result snapshot (label, g, res, a, filters, dataset); needs
## lib.R's t2_caption_text and fmtp (survival_prototype.R).
.gc_stat_names <- c("Wilcoxon rank-sum" = "W", "Kruskal-Wallis" = "chi-squared", "Welch t-test" = "t",
                    "Welch ANOVA" = "F", "Welch one-way ANOVA" = "F", "Pearson chi-squared" = "chi-squared",
                    "Log-rank" = "chi-squared")

.gc_sentence <- function(s) {
  s <- trimws(as.character(s))
  if (!nzchar(s)) return(NULL)
  if (grepl("[.!?]$", s)) s else paste0(s, ".")
}

## sentences 1-5 of the caption (no citation), as a character vector
.gc_caption_sentences <- function(snap) {
  res <- snap$res; gr <- res$groups; tt <- res$test[1, , drop = FALSE]
  lv <- unique(as.character(gr$group))
  n_of <- vapply(lv, function(l) {
    rows <- as.character(gr$group) == l
    if ("count" %in% names(gr)) sum(gr$count[rows]) else gr$n[rows][1]
  }, numeric(1))
  s1 <- sprintf("Groups (%s): %s; universe n=%d.", snap$label,
                paste(sprintf("%s n=%d", lv, as.integer(n_of)), collapse = ", "), as.integer(snap$g$n_universe))
  m <- as.character(tt$method)
  fisher <- identical(m, "Fisher exact")
  sn <- unname(.gc_stat_names[m])
  stat <- if (!fisher && !is.na(sn) && !is.na(tt$statistic)) sprintf("%s = %s, ", sn, sprintf("%.4g", tt$statistic)) else ""
  dfc <- if (!fisher && !is.na(tt$df)) {
    sprintf("df = %s, ", if (grepl("^Welch", m)) sprintf("%.3g", tt$df) else sprintf("%d", as.integer(round(tt$df))))
  } else ""
  s2 <- sprintf("%s: %s%sp = %s.", m, stat, dfc, fmtp(tt$p))
  flt <- as.character(snap$filters)
  if (!grepl("^Maintained filters:", flt)) flt <- paste0("Maintained filters: ", if (nzchar(flt)) flt else "none")
  c(s1, s2, .gc_sentence(snap$g$note), .gc_sentence(tt$note), .gc_sentence(flt), .gc_sentence(paste0("Data: ", snap$dataset)))
}

t2_analysis_caption <- function(snap, fig_width = NULL, size = 9, source_line = "") {
  t2_caption_text(.gc_caption_sentences(snap), source_line, fig_width, size)
}

## the stats .txt export: header, caption sentences, then the CSV rows space-aligned (+ p_text)
t2_analysis_text <- function(snap) {
  res <- snap$res
  tb <- as.matrix(t2_group_result_table(res, character(0)))
  ng <- nrow(res$groups) + 1L
  gb <- tb[seq_len(ng), seq_len(ncol(res$groups)), drop = FALSE]
  tb_t <- tb[(ng + 2L):nrow(tb), seq_len(ncol(res$test)), drop = FALSE]
  tb_t <- cbind(tb_t, c("p_text", vapply(res$test$p, fmtp, "")))
  align <- function(m) vapply(seq_len(nrow(m)), function(i) {
    sub("\\s+$", "", paste(vapply(seq_len(ncol(m)), function(j) format(m[, j], justify = "left")[i], ""), collapse = " "))
  }, "")
  c(sprintf("# T2 analysis: %s, %s.", snap$dataset, format(Sys.Date(), "%Y-%m-%d")), "",
    .gc_caption_sentences(snap), "", align(gb), "", align(tb_t))
}
