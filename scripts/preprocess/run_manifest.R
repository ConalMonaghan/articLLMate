# ==============================================================================
# RUN MANIFEST — reproducibility metadata for a pre-processing run
# ==============================================================================
#
# PURPOSE:
# Capture everything needed to reproduce (or audit) a run: timestamps, R and
# package versions, the GROBID version that produced the XML, the git commit /
# branch / working-tree state, the config levers used, and headline article
# counts. Written as <OUTPUT_DIR>/run_manifest.json.
#
# Designed to be called once at the end of _MASTER_PREPROCESS_PIPELINE.R.
# ==============================================================================

library(jsonlite)

# ---- git state (safe: returns NA fields if git or repo unavailable) ----------
capture_git_state <- function() {
  git_cmd <- function(args) {
    out <- tryCatch(
      suppressWarnings(system2("git", args, stdout = TRUE, stderr = FALSE)),
      error = function(e) character(0)
    )
    if (length(out) == 0) NA_character_ else paste(out, collapse = "\n")
  }
  status <- git_cmd(c("status", "--porcelain"))
  list(
    commit = git_cmd(c("rev-parse", "HEAD")),
    branch = git_cmd(c("rev-parse", "--abbrev-ref", "HEAD")),
    dirty  = if (is.na(status)) NA else nzchar(status)
  )
}

# ---- GROBID version, read from a sample TEI XML header -----------------------
# GROBID stamps <application ident="GROBID" version="..."> in the encodingDesc.
# Reading it from the actual output is more reliable than a running server,
# which may be offline by the time pre-processing runs.
capture_grobid_version <- function(xml_dir) {
  if (is.null(xml_dir) || (length(xml_dir) == 1 && is.na(xml_dir)) || !dir.exists(xml_dir)) {
    return(NA_character_)
  }
  xmls <- list.files(xml_dir, pattern = "\\.xml$", full.names = TRUE, ignore.case = TRUE)
  if (length(xmls) == 0) return(NA_character_)
  tryCatch({
    doc <- xml2::read_xml(xmls[1])
    xml2::xml_ns_strip(doc)
    node <- xml2::xml_find_first(doc, "//application[@ident='GROBID']")
    if (is.na(node)) return(NA_character_)
    xml2::xml_attr(node, "version")
  }, error = function(e) NA_character_)
}

# ---- package versions for the libraries this pipeline relies on ---------------
capture_package_versions <- function(pkgs) {
  versions <- vapply(pkgs, function(p) {
    tryCatch(as.character(utils::packageVersion(p)), error = function(e) NA_character_)
  }, character(1))
  as.list(versions)
}

# ------------------------------------------------------------------------------
# write_run_manifest(): assemble and write the manifest JSON.
#   output_dir     - where to write run_manifest.json
#   config         - named list of the config levers used
#   ledger         - the finalized audit ledger (for headline counts)
#   xml_dir        - used to sniff the GROBID version
#   run_started_at - optional start timestamp string
# ------------------------------------------------------------------------------
write_run_manifest <- function(output_dir, config, ledger,
                               xml_dir = NULL, run_started_at = NULL) {

  pkgs <- c("xml2", "rcrossref", "purrr", "dplyr", "tibble", "readr",
            "reticulate", "jsonlite", "yaml", "here", "tidyverse")

  counts <- list(
    corpus_n     = nrow(ledger),
    xml_created  = sum(isTRUE_vec(ledger$xml_created)),
    parsed_ok    = sum(isTRUE_vec(ledger$parse_ok)),
    meta_found   = sum(isTRUE_vec(ledger$meta_found)),
    included     = sum(ledger$final_status == "included", na.rm = TRUE),
    excluded     = sum(ledger$final_status == "excluded", na.rm = TRUE)
  )

  manifest <- list(
    manifest_written_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %z"),
    run_started_at      = run_started_at %||% NA_character_,
    session = list(
      r_version = R.version.string,
      platform  = R.version$platform,
      os        = Sys.info()[["sysname"]],
      os_release = Sys.info()[["release"]]
    ),
    git             = capture_git_state(),
    grobid_version  = capture_grobid_version(xml_dir),
    package_versions = capture_package_versions(pkgs),
    config          = config,
    counts          = counts
  )

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  path <- file.path(output_dir, "run_manifest.json")
  write_json(manifest, path, auto_unbox = TRUE, pretty = TRUE, null = "null")
  cat(sprintf("  [OK] Run manifest written: %s\n", path))
  invisible(manifest)
}
