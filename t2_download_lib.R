## t2_download_lib.R -- verified downloads for the dataset builders (CPTAC/00-download.R,
## TCGATARGETGTEX/00-download.R, TCGA/275-MSI.R). Source it; it needs nothing else.
##
## A source file is fetched to <dest>.part, checked against the sha256 manifest next to the script
## (`checksums.sha256`, one line per file: "<sha256>  <name>", the format of `sha256sum`), and only then
## renamed to <dest>. A file the manifest does not list is a STOP that prints the hash it computed, unless
## T2_RECORD_CHECKSUMS=1 is set: then the hash is appended to the manifest (the first run records, every
## later run verifies). A mismatch is always a stop: the .part file is removed, nothing is renamed.
##   t2_sha256(path)
##   t2_verify_checksum(path, name, manifest)    check (or record) one file already on disk
##   t2_download_verified(url, dest, name, manifest, size = NA, quiet = TRUE)

t2_sha256 <- function(path) {
  if (requireNamespace("digest", quietly = TRUE)) return(digest::digest(file = path, algo = "sha256", serialize = FALSE))
  o <- system2("sha256sum", shQuote(path), stdout = TRUE)
  strsplit(o[1], " ", fixed = TRUE)[[1]][1]
}

.t2_manifest <- function(manifest) {
  if (!file.exists(manifest)) return(setNames(character(0), character(0)))
  l <- readLines(manifest, warn = FALSE)
  m <- regmatches(l, regexec("^([0-9a-fA-F]{64})  (.+)$", l))
  m <- m[lengths(m) == 3]
  setNames(tolower(vapply(m, `[`, "", 2)), vapply(m, `[`, "", 3))
}

t2_verify_checksum <- function(path, name, manifest) {
  have <- .t2_manifest(manifest)
  got <- t2_sha256(path)
  if (name %in% names(have)) {
    if (!identical(got, unname(have[[name]])))
      stop(sprintf("checksum mismatch for %s: expected %s, got %s (manifest %s)", name, have[[name]], got, manifest), call. = FALSE)
    return(invisible(TRUE))
  }
  if (identical(Sys.getenv("T2_RECORD_CHECKSUMS"), "1")) {
    cat(sprintf("%s  %s\n", got, name), file = manifest, append = TRUE)
    message("recorded sha256 of ", name, " in ", manifest, ": ", got)
    return(invisible(TRUE))
  }
  stop(sprintf("no checksum for %s in %s (computed sha256 %s); check the file, then re-run with T2_RECORD_CHECKSUMS=1 to record it",
               name, manifest, got), call. = FALSE)
}

t2_download_verified <- function(url, dest, name, manifest, size = NA, quiet = TRUE) {
  part <- paste0(dest, ".part")
  unlink(part)
  rc <- utils::download.file(url, part, mode = "wb", quiet = quiet)
  if (!identical(as.integer(rc), 0L) || !file.exists(part)) { unlink(part); stop("download failed: ", url, call. = FALSE) }
  got <- file.info(part)$size
  if (!is.na(size) && got != size) { unlink(part); stop(sprintf("%s: downloaded %.0f bytes, expected %.0f", name, got, size), call. = FALSE) }
  tryCatch(t2_verify_checksum(part, name, manifest), error = function(e) { unlink(part); stop(e) })
  if (!file.rename(part, dest)) stop("could not rename ", part, " to ", dest, call. = FALSE)
  invisible(dest)
}
