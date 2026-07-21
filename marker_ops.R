## marker_ops.R
## ============================================================================
## Shared marker transforms used by BOTH graphing tools — the scatter plotter
## (lib.R) and the Kaplan-Meier survival view (survival_prototype.R) — so the
## "combine several probes" and "remove influences of covariates" logic lives in
## one place instead of being duplicated.
## ============================================================================

## z-score a numeric vector (NA-safe; a constant vector is only centred).
.zscore_vec <- function(v) {
  v <- as.numeric(v)
  m <- mean(v, na.rm = TRUE); s <- stats::sd(v, na.rm = TRUE)
  if (is.na(s) || s == 0) v - m else (v - m) / s
}

## Combine several probe columns into ONE marker = the MEDIAN of the per-probe
## z-scores, per sample. `mat` is a matrix/data.frame (rows = samples, cols =
## probes). A single column is returned unchanged. NA-safe: each probe is
## z-scored ignoring its own NAs, and the row median ignores missing probes.
combine_markers_median_z <- function(mat) {
  mat <- as.matrix(mat)
  storage.mode(mat) <- "double"
  if (ncol(mat) <= 1) return(as.numeric(mat))
  z <- apply(mat, 2, .zscore_vec)
  apply(z, 1, stats::median, na.rm = TRUE)
}

## Remove the influence of covariates from a numeric response: return
## residuals(lm(y ~ covars)), aligned to the input length. `covars` is a
## data.frame of numeric and/or factor columns. Rows with any NA in y/covars are
## dropped from the fit and returned as NA; if the fit isn't possible the
## response is returned unchanged.
residualize_on <- function(y, covars) {
  y <- as.numeric(y)
  covars <- as.data.frame(covars, stringsAsFactors = FALSE, check.names = FALSE)
  if (ncol(covars) == 0) return(y)
  out <- rep(NA_real_, length(y))
  ok  <- stats::complete.cases(cbind(data.frame(.y = y), covars))
  if (sum(ok) < ncol(covars) + 2L) return(y)          # too few to fit
  dd  <- data.frame(.y = y[ok], covars[ok, , drop = FALSE], check.names = FALSE)
  fml <- stats::as.formula(paste("`.y` ~",
           paste(sprintf("`%s`", names(covars)), collapse = " + ")))
  fit <- tryCatch(stats::lm(fml, data = dd), error = function(e) NULL)
  if (is.null(fit)) return(y)
  out[ok] <- as.numeric(stats::residuals(fit))
  out
}
