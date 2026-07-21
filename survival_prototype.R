## survival_prototype.R
## ============================================================================
## Kaplan-Meier survival view for T2.
##
## When the user picks a time-to-event endpoint for X (OS / PFI / DSS / DFI) we
## stratify the chosen y-marker into tertiles and draw a KM curve per tertile
## with SHADED confidence bands, an ordered palette, the MEDIAN survival per
## tertile, and the log-rank p + Cox HR (per 1 SD) embedded in the plot. If a
## `facet` variable is given, draw a faceted grid of KM plots instead.
##
## T2 clinical carries event + time for each endpoint:
##   OS/OS.time  PFI/PFI.time  DSS/DSS.time  DFI/DFI.time   (event 1/0; days)
##
##   g <- survival_km('MKI67', endpoint='OS', dbfile='tcga.db', roles=gitr_default_roles)
##   print(g)                                   # curve + risk table
##   g2 <- survival_km('CD8A','OS', cohort=c('BRCA','LUAD'), facet='tumtype', ...)
## ============================================================================

suppressMessages({ library(survival); library(survminer); library(ggplot2) })
if (!exists("gitr")) source("gitr.R")

T2_ENDPOINTS <- c(OS  = "Overall Survival",
                  PFI = "Progression-Free Interval",
                  DSS = "Disease-Specific Survival",
                  DFI = "Disease-Free Interval")

## Ordered cool->warm palette (Low -> High). Chosen so the translucent CI bands
## read as a low/high gradient and stay distinguishable where they overlap.
t2_km_palette <- function(n) {
  switch(as.character(n),
    "2" = c("#3B7DB4", "#C0392B"),
    "3" = c("#3B7DB4", "#E3A93A", "#C0392B"),
    "4" = c("#2C6FAD", "#2E9E88", "#E3A93A", "#C0392B"),
    grDevices::colorRampPalette(c("#2C6FAD", "#E3A93A", "#C0392B"))(n))
}

fmtp <- function(p) {
  if (is.na(p)) return("NA")
  if (p <= 0)   return("< 1e-300")      # underflowed to 0
  if (p < 1e-3) return(sprintf("%.1e", p))
  sprintf("%.3g", p)
}

survival_km <- function(y, endpoint = "OS", cohort = "all", n_groups = 3,
                        dbfile = "tcga.db", roles = NULL, nonormal = TRUE,
                        facet = NULL, ci = TRUE, title = NULL) {
  stopifnot(endpoint %in% names(T2_ENDPOINTS))
  y  <- y[1]; ev <- endpoint; tm <- paste0(endpoint, ".time")
  facet <- facet[!is.na(facet) & nzchar(facet)]
  facet <- head(setdiff(facet, c(y, ev, tm)), 2)          # up to two facet vars

  ## pull marker + full clinical (gitr joins clinpheno, so event/time/facet come along)
  d <- suppressWarnings(gitr(y, cohort = cohort, nonormal = nonormal,
                             dbfile = dbfile, roles = roles))
  miss <- setdiff(c(y, ev, tm, facet), names(d))
  if (length(miss)) stop("column(s) not found: ", paste(miss, collapse = ", "))

  num <- function(x) suppressWarnings(as.numeric(as.character(x)))
  df <- data.frame(marker = num(d[[y]]), time = num(d[[tm]]), event = num(d[[ev]]))
  for (fv in facet) df[[fv]] <- as.character(d[[fv]])
  keep <- stats::complete.cases(df[, c("marker", "time", "event")]) & df$time > 0
  df <- df[keep, , drop = FALSE]
  if (nrow(df) < 20) stop("too few complete cases (", nrow(df), ") for ", y, " / ", endpoint)

  ## tertiles (equal-count bins) of the marker
  labs <- switch(as.character(n_groups),
                 "2" = c("Low", "High"), "3" = c("Low", "Mid", "High"),
                 "4" = c("Q1", "Q2", "Q3", "Q4"), paste0("G", seq_len(n_groups)))
  br <- unique(quantile(df$marker, probs = seq(0, 1, length.out = n_groups + 1), na.rm = TRUE))
  br[1] <- -Inf; br[length(br)] <- Inf
  df$grp <- droplevels(cut(df$marker, breaks = br, labels = labs[seq_len(length(br) - 1)],
                           include.lowest = TRUE))
  if (nlevels(df$grp) < 2) stop("marker has too few distinct values to stratify")
  pal <- t2_km_palette(nlevels(df$grp))

  fit <- survfit(Surv(time, event) ~ grp, data = df)

  ## ---------------- faceted grid ----------------
  if (length(facet)) {
    g <- ggsurvplot_facet(fit, data = df, facet.by = facet, palette = pal,
                          conf.int = ci, conf.int.alpha = 0.15, pval = TRUE, pval.size = 3.2,
                          censor = FALSE, short.panel.labs = TRUE, nrow = NULL,
                          legend.title = paste(y, "tertile"),
                          xlab = "Time (days)", ylab = sprintf("%s probability", endpoint),
                          ggtheme = theme_minimal(base_size = 11)) +
      ggtitle(title %||% sprintf("%s by %s tertiles — faceted by %s",
                                 T2_ENDPOINTS[[endpoint]], y, paste(facet, collapse = " × ")))
    attr(g, "t2summary") <- sprintf(
      "Faceted KM: %s by %s tertiles, faceted by %s (n=%d). Per-panel log-rank p shown on each panel.",
      endpoint, y, paste(facet, collapse = " x "), nrow(df))
    return(g)
  }

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
  medlab <- ifelse(is.na(medv), "NR", paste0(round(medv), "d"))
  leglabs <- sprintf("%s  (med %s)", levels(df$grp), medlab)
  med_txt <- paste(sprintf("%s %s", levels(df$grp), medlab), collapse = "  |  ")

  stat_txt <- sprintf("Log-rank p = %s\nCox HR/SD = %.2f (%.2f–%.2f), p = %s",
                      fmtp(lp), hr, lo, hi, fmtp(cp))
  ttl <- title %||% sprintf("%s by %s tertiles%s", T2_ENDPOINTS[[endpoint]], y,
           if (!identical(cohort, "all")) paste0("  [", paste(cohort, collapse = ","), "]") else "  [pan-cancer]")

  g <- ggsurvplot(fit, data = df, pval = stat_txt, pval.size = 4.2,
                  pval.coord = c(0.02 * max(df$time), 0.07),
                  conf.int = ci, conf.int.alpha = 0.16,
                  risk.table = TRUE, risk.table.height = 0.26, tables.y.text = FALSE,
                  tables.theme = theme_cleantable(), censor.size = 2, palette = pal,
                  legend.title = paste(y, "tertile"), legend.labs = leglabs,
                  xlab = "Time (days)", ylab = sprintf("%s probability", endpoint),
                  title = ttl,
                  subtitle = sprintf("n = %d    median %s:  %s", nrow(df), endpoint, med_txt),
                  ggtheme = theme_minimal(base_size = 12))
  attr(g, "stats") <- list(n = nrow(df), logrank_p = lp, HR_per_SD = hr, HR_CI = c(lo, hi),
                           cox_p = cp, medians = medv)
  attr(g, "t2summary") <- sprintf(
    "%s ~ %s tertiles (n=%d).  Median %s: %s.  Log-rank p=%s.  Cox HR/SD=%.2f (%.2f-%.2f), p=%s.",
    endpoint, y, nrow(df), endpoint, med_txt, fmtp(lp), hr, lo, hi, fmtp(cp))
  g
}
`%||%` <- function(a, b) if (is.null(a)) b else a

## save a ggsurvplot (curve + risk table) or faceted plot to a file
save_km <- function(g, file, width = 950, height = 840, res = 110) {
  grDevices::png(file, width = width, height = height, res = res); print(g); grDevices::dev.off()
  invisible(file)
}

## ---- demo when run directly -----------------------------------------------
.invoked <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  length(fa) && identical(basename(sub("^--file=", "", fa[1])), "survival_prototype.R")
}
if (.invoked()) {
  a  <- commandArgs(trailingOnly = TRUE)
  DB <- if (length(a) >= 1) a[1] else if (file.exists("tcga.db.pre_rebuild")) "tcga.db.pre_rebuild" else "tcga.db"
  demo <- function(mark, end, coh = "all", facet = NULL, tag = NULL) {
    g <- survival_km(mark, endpoint = end, cohort = coh, facet = facet,
                     dbfile = DB, roles = gitr_default_roles)
    out <- sprintf("survival_demo_%s.png", tag %||% paste(mark, end, sep = "_"))
    save_km(g, out, height = if (length(facet)) 620 else 840)
    st <- attr(g, "stats")
    if (!is.null(st)) cat(sprintf("  %s: n=%d log-rank p=%.2g HR/SD=%.2f cox p=%.2g medians=%s\n",
        out, st$n, st$logrank_p, st$HR_per_SD, st$cox_p,
        paste(ifelse(is.na(st$medians), "NR", round(st$medians)), collapse = "/")))
    else cat(sprintf("  %s (faceted)\n", out))
  }
  demo("MKI67", "OS", "all")
  demo("CD8A",  "OS", "SKCM")
  demo("MKI67", "OS", c("BRCA", "LUAD", "KIRC"), facet = "tumtype", tag = "MKI67_OS_facet")
}
