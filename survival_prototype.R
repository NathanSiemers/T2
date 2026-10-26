## survival_prototype.R
## ============================================================================
## Kaplan-Meier survival view for T2.
##
## When the user picks a time-to-event variable for X (the dataset's
## `tte_variables`: OS, PFI, ... as /meta declares them) we stratify the chosen y-marker into tertiles and draw a KM curve per tertile
## with SHADED confidence bands, an ordered palette, the MEDIAN survival per
## tertile, and the log-rank p + Cox HR (per 1 SD) embedded in the plot. If a
## `facet` variable is given, draw a faceted grid of KM plots instead.
##
## A time-to-event variable is a pair of clinical columns the dataset declares
## (DATASET-CONTRACT.md): `event_col` (1 = event, 0 = censored), `time_col`
## (> 0) in `time_unit`, with a `label`. survival_km() reads all four from the
## entry of the plot context (ctx$tte) named by `endpoint`; nothing about OS,
## PFI, DSS or DFI is known here.
##
##   ctx <- t2_default_ctx()                    # lib.R: the plot context of a dataset
##   g <- survival_km('MKI67', endpoint = 'OS', ctx = ctx)
##   print(g)                                   # curve + risk table
##   g2 <- survival_km('CD8A', 'OS', cohort = c('BRCA','LUAD'), facet = 'cohort', ctx = ctx)
## ============================================================================

suppressMessages({ library(survival); library(survminer); library(ggplot2) })
if (!exists("t2_cache")) source("t2_util.R")
if (!exists("gitr")) source("gitr.R")
if (!exists("combine_markers_median_z")) source("marker_ops.R")

## the names of the time-to-event variables of a plot context (the X choices that mean survival)
tte_names <- function(ctx) names(ctx$tte)

## the unit of a time-to-event variable: the short form for medians ("1203d"), the
## length of a year in that unit (the x axis ticks once a year); v1 of the contract has days only
t2_tte_unit <- function(unit) {
  short <- c(days = "d", months = "mo", years = "y")[unit]
  per_year <- c(days = 365, months = 12, years = 1)[unit]
  list(word = unit, short = if (is.na(short)) unit else unname(short),
       per_year = if (is.na(per_year)) NULL else unname(per_year))
}

## Ordered cool->warm palette (Low -> High). Chosen so the translucent CI bands
## read as a low/high gradient and stay distinguishable where they overlap.
## Ordered cool->warm colours for any number of groups. Hand-tuned pairs/triples
## for the common small cases; for larger n an interpolated blue->teal->amber->red
## ramp keeps the low/high gradient readable and the translucent CI fills clean.
t2_km_palette <- function(n) {
  if (n <= 1) return("#3B7DB4")
  if (n == 2) return(c("#3B7DB4", "#C0392B"))
  if (n == 3) return(c("#3B7DB4", "#E3A93A", "#C0392B"))
  grDevices::colorRampPalette(c("#2C6FAD", "#2E9E88", "#E3A93A", "#C0392B"))(n)
}

## remove the outline from CI ribbons (keep only the translucent fill) so the
## plot isn't cluttered with extra step-lines around every band.
.km_strip_ci_border <- function(p) {
  for (i in seq_along(p$layers)) {
    gm <- p$layers[[i]]$geom
    if (inherits(gm, "GeomRibbon") || grepl("ribbon|confint", tolower(class(gm)[1]))) {
      p$layers[[i]]$aes_params$colour <- NA
      p$layers[[i]]$aes_params$linewidth <- 0
      if (!is.null(p$layers[[i]]$mapping)) p$layers[[i]]$mapping[["colour"]] <- NULL
    }
  }
  p
}

fmtp <- function(p) {
  if (is.na(p)) return("NA")
  if (p <= 0)   return("< 1e-300")      # underflowed to 0
  if (p < 1e-3) return(sprintf("%.1e", p))
  sprintf("%.3g", p)
}

## Equal-count groups of a marker. Equal values can merge cut points, so fewer groups
## than asked may survive; they are named by position among the surviving cuts:
## 2 -> Low/High, 3 -> Low/Mid/High, more -> Q1..Qn (the iOS app's Stats.groupLabels
## keys on the groups actually made too, so a 3-group ask that made 2 gives Low/High
## on both platforms). A grouping that leaves any group under min_n samples
## is refused. Returns NULL (fewer than 2 distinct values), list(refused = text), or
## list(grp = factor, n = number of groups).
t2_quantile_groups <- function(m, n_groups, min_n = 5L) {
  br <- unique(stats::quantile(m, probs = seq(0, 1, length.out = n_groups + 1), na.rm = TRUE))
  made <- length(br) - 1L
  if (made < 2) return(NULL)
  labs <- if (made == 2) c("Low", "High") else if (made == 3) c("Low", "Mid", "High") else paste0("Q", seq_len(made))
  br[1] <- -Inf; br[length(br)] <- Inf
  grp <- cut(m, breaks = br, labels = labs, include.lowest = TRUE)
  small <- table(grp[!is.na(grp)])
  if (any(small < min_n))
    return(list(refused = sprintf("the groups would hold only %s samples (at least %d are needed in each; many samples share one marker value). Try fewer groups.",
                                  paste(small, collapse = "/"), min_n)))
  list(grp = grp, n = made)
}

survival_km <- function(y, endpoint = "OS", cohort = "all", n_groups = 3,
                        nonormal = TRUE,
                        facet = NULL, ci = TRUE, title = NULL,
                        max_time = 365 * 5, condition = NULL, pcortype = "none",
                        noheme = FALSE,
                        base_size = 12, base_family = "sans", multi_y = FALSE,
                        ctx = t2_default_ctx()) {
  ## every text / line size below follows base_size (12 = the on-screen look)
  k <- base_size / 12
  n_groups <- max(2L, as.integer(n_groups))
  tt <- ctx$tte[[endpoint]]
  if (is.null(tt)) stop("'", endpoint, "' is not a time-to-event variable of ", ctx$label %||% ctx$name,
                        if (length(ctx$tte)) paste0(" (it has ", paste(tte_names(ctx), collapse = ", "), ")") else " (it has none)")
  ev <- tt$event_col; tm <- tt$time_col
  unit <- t2_tte_unit(tt$time_unit)
  elabel <- tt$label %||% endpoint
  y <- unique(y[!is.na(y) & nzchar(y)])
  if (!length(y)) stop("no Y marker selected")
  facet <- head(setdiff(facet[!is.na(facet) & nzchar(facet)], c(y, ev, tm)), 2)
  ## "Remove influences of" adjusts the Y marker when pcortype includes y/both
  condition <- unique(condition[!is.na(condition) & nzchar(condition)])
  do_cond <- length(condition) > 0 && pcortype %in% c("y", "both")

  ## pull marker probe(s) + covariates + clinical (gitr joins clinpheno)
  d <- suppressWarnings(gitr_memo(unique(c(y, facet, if (do_cond) condition)),
                             cohort = cohort, nonormal = nonormal, noheme = noheme, ctx = ctx))
  miss <- setdiff(c(y, ev, tm, facet, if (do_cond) condition), names(d))
  if (length(miss)) stop("column(s) not found: ", paste(miss, collapse = ", "))
  ## a graph for each value needs a categorical variable (as in plotter())
  num_facet <- facet[vapply(facet, function(fv) is.numeric(d[[fv]]), logical(1))]
  if (length(num_facet)) stop("'Graph for each' needs a categorical variable; ", paste(num_facet, collapse = ", "), " is numeric")
  num <- function(x) suppressWarnings(as.numeric(as.character(x)))

  ## Keep the RAW probe columns (+ covariates) so the median-z signature AND the
  ## group cut-points can be computed WITHIN each facet group. If we z-scored /
  ## binned over the whole pull and then faceted, a panel would show that cohort's
  ## samples binned against the PAN-CANCER distribution — so "cohort=HNSC" and
  ## "cohort=all, facet=cohort -> HNSC panel" would disagree.
  ylab <- if (length(y) > 1) sprintf("median-z(%s)", paste(y, collapse = ", ")) else y
  df <- data.frame(sample = as.character(d[["sample"]]),
                   time = num(d[[tm]]), event = num(d[[ev]]), check.names = FALSE)
  for (p in y)      df[[p]]  <- num(d[[p]])
  for (fv in facet) df[[fv]] <- as.character(d[[fv]])
  cond_cols <- character(0)
  if (do_cond) for (cv in condition) {
    cn <- num(d[[cv]])
    df[[cv]] <- if (mean(is.na(cn)) > 0.5) as.factor(as.character(d[[cv]])) else cn
    cond_cols <- c(cond_cols, cv)
  }
  core <- c("time", "event", y, cond_cols)
  df <- df[stats::complete.cases(df[, core, drop = FALSE]) & df$time > 0, , drop = FALSE]
  if (nrow(df) < 20) stop("too few complete cases (", nrow(df), ") for ", ylab, " / ", endpoint)

  ## restrict follow-up: administratively censor at max_time (trim long/unreliable
  ## late TTE by capping every subject's follow-up rather than dropping subjects)
  capped <- !is.null(max_time) && is.finite(max_time) && max_time > 0   # max_time is in the unit of the variable (days)
  if (capped) { past <- df$time > max_time; df$event[past] <- 0; df$time[past] <- max_time }
  xmax <- if (capped) max_time else max(df$time)
  cond_note <- if (do_cond && length(cond_cols)) sprintf("  •  adj: %s", paste(cond_cols, collapse = ", ")) else ""

  refused <- NULL          # why add_marker_grp gave up on the last subset
  unadj <- character(0)    # subsets (panels) where the covariate adjustment was not possible

  ## Build the marker (median-z of the Y probes, optionally covariate-adjusted)
  ## and equal-count groups on a SUBSET of samples — used over the whole cohort
  ## for a single panel, or within each facet group so a panel matches selecting
  ## that group as the cohort.
  ## Several Y probes: by default they are ONE marker, the median of their
  ## z-scores (the same signature the scatter plot draws). With multi_y ('Plot Y
  ## probes individually') each probe is its own marker instead: the samples are
  ## stacked once per probe and `probe` becomes a graph variable, so every probe
  ## gets its own Kaplan-Meier graph with its own groups.
  ymark <- y
  stacked <- isTRUE(multi_y) && length(y) > 1
  if (stacked) {
    df <- do.call(rbind, lapply(y, function(p) { s <- df; s$.probe_value <- s[[p]]; s$probe <- p; s }))
    df$probe <- factor(df$probe, levels = y)
    ymark <- ".probe_value"
    facet <- c("probe", utils::head(facet, 1))     # ggsurvplot_facet takes at most two
    ylab <- "Y probe"
  }
  add_marker_grp <- function(sub, label = "all samples") {
    refused <<- NULL
    m <- combine_markers_median_z(sub[, ymark, drop = FALSE])
    if (do_cond && length(cond_cols)) {
      m <- residualize_on(m, sub[, cond_cols, drop = FALSE])
      if (identical(attr(m, "adjusted"), FALSE)) unadj <<- c(unadj, label)
      m <- as.numeric(m)
    }
    ## a marker with no more distinct values than groups (a 0/1 mutation call, a
    ## copy-number class): the values ARE the groups; quantile cuts would collapse
    vals <- sort(unique(m[!is.na(m)]))
    if (length(vals) >= 2 && length(vals) <= n_groups) {
      sub$marker <- m
      sub$grp <- factor(m, levels = vals, labels = paste0("= ", format(vals)))
      return(sub)
    }
    qg <- t2_quantile_groups(m, n_groups)
    if (is.null(qg)) return(NULL)
    if (!is.null(qg$refused)) { refused <<- paste0(label, ": ", qg$refused); return(NULL) }
    sub$marker <- m
    sub$grp <- qg$grp
    sub
  }

  ## ---------------- faceted grid: signature + groups WITHIN each panel --------
  if (length(facet)) {
    parts <- split(df, df[facet], drop = TRUE, sep = " | ")
    if (exists("T2_LIMITS") && length(parts) > T2_LIMITS$km_panels)
      stop(sprintf("'%s' has %s different values; a survival plot is limited to %d graphs",
                   paste(facet, collapse = " x "), format(length(parts), big.mark = ","), T2_LIMITS$km_panels))
    keep_part <- vapply(parts, function(s) nrow(s) >= 2L * n_groups, logical(1))
    dropped <- sum(!keep_part)
    parts <- parts[keep_part]
    parts <- Map(function(s, nm) add_marker_grp(s, nm), parts, names(parts))
    dropped <- dropped + sum(vapply(parts, is.null, logical(1)))
    parts <- parts[!vapply(parts, is.null, logical(1))]
    df <- if (length(parts)) do.call(rbind, parts) else NULL
    if (is.null(df) || nrow(df) < 20) stop("too few samples per facet group to form ", n_groups, " groups")
    df <- df[!is.na(df$grp), , drop = FALSE]; df$grp <- droplevels(df$grp)
    if (length(unadj)) cond_note <- sprintf("  \u2022  NOT adjusted in: %s", paste(unique(unadj), collapse = ", "))
    n_made <- nlevels(df$grp)          # the groups actually drawn (cut points can merge)
    fit <- survfit(Surv(time, event) ~ grp, data = df)
    pal <- t2_km_palette(nlevels(df$grp))
    g <- ggsurvplot_facet(fit, data = df, facet.by = facet, palette = pal,
                          conf.int = ci, conf.int.alpha = 0.15, pval = TRUE, pval.size = 3.2 * k,
                          size = k,
                          censor = FALSE, short.panel.labs = TRUE, nrow = NULL,
                          xlim = c(0, xmax), break.time.by = unit$per_year,
                          legend.title = paste(ylab, "group"),
                          xlab = sprintf("Time (%s)", unit$word), ylab = sprintf("%s probability", endpoint),
                          ggtheme = theme_minimal(base_size = 11 * k, base_family = base_family)) +
      ggtitle(title %||% sprintf("%s by %s %s-groups (within panel) — faceted by %s",
                                 elabel, ylab, n_made, paste(facet, collapse = " × ")))
    g <- .km_strip_ci_border(g)                      # no outline on CI bands
    attr(g, "t2summary") <- paste0(sprintf(
      "Faceted KM: %s by %s %d-groups computed WITHIN each %s panel (n=%d%s%s%s). Per-panel log-rank p shown.",
      endpoint, ylab, n_made, paste(facet, collapse = " x "), nrow(df),
      if (capped) sprintf(", ≤%d%s", as.integer(max_time), unit$short) else "", cond_note,
      if (dropped) sprintf(", %d small panel(s) dropped", dropped) else ""),
      if (isTRUE(nonormal)) "  Normal-tissue samples are excluded." else "")
    attr(g, "km_data") <- df                          # sample, grp, facet - for tests
    attr(g, "t2fill") <- t2_fill_of(d, rows = as.character(d[["sample"]]) %in% df$sample)   # the answer's word on not-detected values (lib.R)
    return(g)
  }

  ## ---------------- single panel: signature + groups over the whole cohort ----
  df <- add_marker_grp(df)
  if (is.null(df)) stop(refused %||% "marker has too few distinct values to stratify")
  df <- df[!is.na(df$grp), , drop = FALSE]; df$grp <- droplevels(df$grp)
  if (nlevels(df$grp) < 2) stop("marker has too few distinct values to stratify")
  if (length(unadj)) cond_note <- "  \u2022  NOT adjusted (the covariate fit was not possible)"
  pal <- t2_km_palette(nlevels(df$grp))
  fit <- survfit(Surv(time, event) ~ grp, data = df)

  ## ---------------- single panel: stats + median + shaded CIs ----------------
  lr <- survdiff(Surv(time, event) ~ grp, data = df)
  lp <- stats::pchisq(lr$chisq, length(lr$n) - 1, lower.tail = FALSE)
  df$z <- as.numeric(scale(df$marker))
  cs <- summary(coxph(Surv(time, event) ~ z, data = df))
  hr <- cs$conf.int[1, "exp(coef)"]; lo <- cs$conf.int[1, "lower .95"]
  hi <- cs$conf.int[1, "upper .95"]; cp <- cs$coefficients[1, "Pr(>|z|)"]

  ## median survival per tertile ("NR" = not reached)
  tb <- summary(fit)$table
  medv  <- if (is.matrix(tb)) tb[, "median"] else tb["median"]
  gname <- sub("^grp=", "", if (is.matrix(tb)) rownames(tb) else names(fit$strata))
  medv  <- setNames(medv, gname)[levels(df$grp)]
  medlab <- ifelse(is.na(medv), "NR", paste0(round(medv), unit$short))
  leglabs <- sprintf("%s  (med %s)", levels(df$grp), medlab)
  med_txt <- paste(sprintf("%s %s", levels(df$grp), medlab), collapse = "  |  ")

  n_made <- nlevels(df$grp)          # the groups actually drawn: fewer than asked when cut points merged
  grp_desc <- switch(as.character(n_made), "2" = "halves", "3" = "tertiles",
                     "4" = "quartiles", "5" = "quintiles", sprintf("%d groups", n_made))
  if (any(grepl("^= ", levels(df$grp)))) grp_desc <- "values"      # grouped by value, not by quantile
  cap_txt <- if (capped) sprintf("  •  follow-up ≤ %d%s", as.integer(max_time), unit$short) else ""

  stat_txt <- sprintf("Log-rank p = %s\nCox HR/SD = %.2f (%.2f–%.2f), p = %s",
                      fmtp(lp), hr, lo, hi, fmtp(cp))
  ttl <- title %||% sprintf("%s by %s %s%s", elabel, ylab, grp_desc,
           if (!identical(cohort, "all")) paste0("  [", paste(cohort, collapse = ","), "]") else "  [pan-cancer]")

  g <- ggsurvplot(fit, data = df, pval = stat_txt, pval.size = 4.2 * k, size = k,
                  fontsize = 4.5 * k, font.family = base_family,
                  pval.coord = c(0.02 * xmax, 0.07),
                  conf.int = ci, conf.int.alpha = 0.16,
                  xlim = c(0, xmax), break.time.by = unit$per_year,
                  risk.table = TRUE, risk.table.height = 0.26, tables.y.text = FALSE,
                  tables.theme = theme_cleantable(base_size = 12 * k, base_family = base_family),
                  censor.size = 2 * k, palette = pal,
                  legend.title = paste(ylab, "group"), legend.labs = leglabs,
                  xlab = sprintf("Time (%s)", unit$word), ylab = sprintf("%s probability", endpoint),
                  title = ttl,
                  subtitle = sprintf("n = %d    median %s:  %s%s%s", nrow(df), endpoint, med_txt, cap_txt, cond_note),
                  ggtheme = theme_minimal(base_size = 12 * k, base_family = base_family))
  g$plot <- .km_strip_ci_border(g$plot)              # no outline on CI bands
  ## the risk table's group markers are y-axis "labels" drawn at a fixed 50 pt
  ## by survminer; keep them in proportion, and in the chosen font
  if (!is.null(g$table)) {
    g$table <- g$table + theme(text = element_text(family = base_family))
    mark <- g$table$theme$axis.text.y           # survminer's own element type
    if (!is.null(mark) && is.numeric(tryCatch(mark$size, error = function(e) NULL))) {
      mark$size <- mark$size * k
      g$table$theme$axis.text.y <- mark
    }
    ## survminer labels each row with an escaped dash ("\\-") that current
    ## ggtext draws literally, as a backslash plus a dash; use a plain dash
    ysc <- tryCatch(g$table$scales$get_scales("y"), error = function(e) NULL)
    if (!is.null(ysc) && is.character(ysc$labels)) ysc$labels <- rep("\u2014", length(ysc$labels))
  }
  attr(g, "stats") <- list(n = nrow(df), logrank_p = lp, HR_per_SD = hr, HR_CI = c(lo, hi),
                           cox_p = cp, medians = medv, n_groups = n_groups,
                           max_time = if (capped) max_time else NA,
                           markers = y, adjusted_for = if (do_cond) cond_cols else NULL)
  attr(g, "t2summary") <- paste0(sprintf(
    "%s ~ %s %s (n=%d%s%s).  Median %s: %s.  Log-rank p=%s.  Cox HR/SD=%.2f (%.2f-%.2f), p=%s.",
    endpoint, ylab, grp_desc, nrow(df), if (capped) sprintf(", ≤%d%s", as.integer(max_time), unit$short) else "",
    cond_note, endpoint, med_txt, fmtp(lp), hr, lo, hi, fmtp(cp)),
    if (isTRUE(nonormal)) "  Normal-tissue samples are excluded." else "")
  attr(g, "km_data") <- df                            # sample, grp - for tests
  attr(g, "t2fill") <- t2_fill_of(d, rows = as.character(d[["sample"]]) %in% df$sample)   # the answer's word on not-detected values (lib.R)
  g
}

