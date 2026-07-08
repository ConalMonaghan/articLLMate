# ==============================================================================
# AUDIT LEDGER — the "master sheet" for the data-input pipeline
# ==============================================================================
#
# PURPOSE:
# A single tidy data frame, one row per article, keyed by a stable `article_id`
# (the accession id / filename stem used as the list key throughout the
# pre-processing scripts). Columns accrue as articles pass through stages; a
# stage only fills its own columns. The ledger is the audit trail that lets us
# reconcile the true starting N of articles against what survives each stage.
#
# The ledger is persisted after every stage as BOTH:
#   - <output>/audit_ledger.csv   (human-readable)
#   - <output>/audit_ledger.rds   (pipeline-consumable, preserves types)
#
# DESIGN NOTES:
# - Grow-only and idempotent: re-running a stage upserts (merges) by article_id
#   rather than appending duplicates, so partial re-runs are safe.
# - Route-agnostic: `ingest_route` records how an article entered the pipeline
#   ("extraction" today; "image" reserved for the future PDF->Gemma branch).
#
# AUTHOR: Dr Conal Monaghan (+ articLLMate logging branch)
# ==============================================================================

library(tibble)
library(dplyr)
library(readr)

# Null/NA coalescing helper — returns b if a is NULL, NA, or length 0.
`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0) return(b)
  if (length(a) == 1 && is.na(a)) return(b)
  a
}

# Vectorized "is TRUE" that treats NA as FALSE (logical columns may hold NA).
isTRUE_vec <- function(x) !is.na(x) & x

# ------------------------------------------------------------------------------
# Canonical column schema.
# Every column the ledger can ever hold, with its type template. Keeping this in
# one place means new articles and new stages always align to the same shape.
# ------------------------------------------------------------------------------
LEDGER_SCHEMA <- list(
  # Identity & provenance
  article_id       = NA_character_,
  source_batch     = NA_character_,
  ingest_route     = NA_character_,   # "extraction" | "image" (reserved)
  pdf_path         = NA_character_,
  xml_path         = NA_character_,

  # Stage 1: PDF -> XML (GROBID)
  xml_created      = NA,              # logical
  grobid_status    = NA_character_,   # "ok" | "failed" | "no_pdf"

  # Stage 2a: DOI detection + Crossref metadata
  extracted_doi    = NA_character_,
  crossref_doi     = NA_character_,
  doi_match        = NA,              # logical: extracted vs crossref agree
  meta_found       = NA,              # logical

  # Stage 2b: body extraction
  parse_ok         = NA,              # logical
  has_title        = NA,              # logical
  has_body         = NA,              # logical
  parse_error      = NA_character_,

  # Stage 2c: length filter
  n_words          = NA_integer_,
  length_status    = NA_character_,   # "kept" | "too_short" | "too_long"

  # Stage 2d: content filter (STUB — reserved for a later branch)
  content_flag     = NA_character_,   # e.g. "toc" | "erratum" | "editorial"

  # Stage 2e: truncation (STUB — reserved for a later branch)
  truncated        = NA,              # logical

  # Stage 3: token profiling
  n_tokens         = NA_integer_,

  # Rollup
  final_status     = NA_character_,   # "included" | "excluded"
  exclusion_reason = NA_character_,
  last_stage       = NA_character_,
  updated_at       = NA_character_
)

# Paths for the two on-disk representations, derived from an output folder.
ledger_paths <- function(output_dir) {
  list(
    csv = file.path(output_dir, "audit_ledger.csv"),
    rds = file.path(output_dir, "audit_ledger.rds")
  )
}

# ------------------------------------------------------------------------------
# ledger_init(): build an empty ledger (zero rows) with the full schema.
# ------------------------------------------------------------------------------
ledger_init <- function() {
  cols <- lapply(LEDGER_SCHEMA, function(template) template[0])
  as_tibble(cols)
}

# ------------------------------------------------------------------------------
# ledger_load(): load an existing ledger from disk (prefers RDS for types),
# or return a fresh empty ledger if none exists.
# ------------------------------------------------------------------------------
ledger_load <- function(output_dir) {
  paths <- ledger_paths(output_dir)
  if (file.exists(paths$rds)) {
    ledger <- readRDS(paths$rds)
    return(ledger_conform(ledger))
  }
  ledger_init()
}

# ------------------------------------------------------------------------------
# ledger_conform(): ensure a ledger has exactly the schema columns, adding any
# missing ones (as typed NA) and dropping nothing. Used on load and before save
# so older ledgers stay forward-compatible as the schema grows.
# ------------------------------------------------------------------------------
ledger_conform <- function(ledger) {
  for (col in names(LEDGER_SCHEMA)) {
    if (!col %in% names(ledger)) {
      ledger[[col]] <- rep(LEDGER_SCHEMA[[col]], nrow(ledger))
    }
  }
  # Preserve schema order first, then any extra columns a caller may have added.
  ordered <- c(names(LEDGER_SCHEMA), setdiff(names(ledger), names(LEDGER_SCHEMA)))
  ledger[, ordered]
}

# ------------------------------------------------------------------------------
# ledger_upsert(): merge stage results into the ledger by article_id.
#
# `updates` is a data frame that MUST contain an `article_id` column plus any
# subset of ledger columns to write. New article_ids are inserted; existing ones
# have only the supplied (non-NA) columns overwritten. Idempotent: re-running a
# stage produces the same ledger.
#
# `stage` (optional) is recorded in `last_stage`; `updated_at` is stamped for all
# touched rows.
# ------------------------------------------------------------------------------
ledger_upsert <- function(ledger, updates, stage = NA_character_) {
  stopifnot("article_id" %in% names(updates))
  ledger  <- ledger_conform(ledger)
  updates <- as_tibble(updates)

  now <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # Add bookkeeping columns to the incoming update frame.
  if (!is.na(stage)) updates$last_stage <- stage
  updates$updated_at <- now

  # Columns we're actually writing (intersect with schema, minus the key).
  write_cols <- setdiff(intersect(names(updates), names(ledger)), "article_id")

  existing_ids <- ledger$article_id
  upd_ids      <- updates$article_id

  # --- Update rows already present -------------------------------------------
  in_ledger <- upd_ids %in% existing_ids
  if (any(in_ledger)) {
    upd_existing <- updates[in_ledger, , drop = FALSE]
    match_idx    <- match(upd_existing$article_id, ledger$article_id)
    for (col in write_cols) {
      new_vals <- upd_existing[[col]]
      # Only overwrite where the incoming value is non-NA, so a stage that
      # doesn't know about a column can't blank out an earlier stage's value.
      keep <- !is.na(new_vals)
      if (any(keep)) {
        ledger[[col]][match_idx[keep]] <- new_vals[keep]
      }
    }
  }

  # --- Insert genuinely new rows ---------------------------------------------
  if (any(!in_ledger)) {
    upd_new <- updates[!in_ledger, , drop = FALSE]
    new_rows <- ledger_init()
    # Seed the right number of empty rows.
    new_rows <- new_rows[rep(NA_integer_, nrow(upd_new)), , drop = FALSE]
    new_rows$article_id <- upd_new$article_id
    for (col in intersect(write_cols, names(upd_new))) {
      new_rows[[col]] <- upd_new[[col]]
    }
    ledger <- bind_rows(ledger, new_rows)
  }

  ledger
}

# ------------------------------------------------------------------------------
# ledger_finalize(): compute the rollup columns (final_status, exclusion_reason)
# from the per-stage evidence. Called once at the end of a run before the funnel.
#
# An article is EXCLUDED if any hard gate failed; the first failing gate (in
# pipeline order) sets the reason. Otherwise it is INCLUDED.
# ------------------------------------------------------------------------------
ledger_finalize <- function(ledger) {
  ledger <- ledger_conform(ledger)

  classify <- function(row) {
    if (isFALSE(row$xml_created %||% NA))        return(c("excluded", "GROBID failed (no XML)"))
    if (isFALSE(row$parse_ok %||% NA))           return(c("excluded", "XML parse failed"))
    if (isTRUE((row$length_status %||% "") == "too_short")) return(c("excluded", "Too short"))
    if (isTRUE((row$length_status %||% "") == "too_long"))  return(c("excluded", "Too long"))
    if (!is.na(row$content_flag))                return(c("excluded", paste0("Content flag: ", row$content_flag)))
    c("included", NA_character_)
  }

  status <- character(nrow(ledger))
  reason <- character(nrow(ledger))
  for (i in seq_len(nrow(ledger))) {
    res <- classify(as.list(ledger[i, ]))
    status[i] <- res[1]
    reason[i] <- res[2]
  }
  ledger$final_status     <- status
  ledger$exclusion_reason <- reason
  ledger
}

# ------------------------------------------------------------------------------
# ledger_save(): write both CSV and RDS. Conforms to schema first.
# ------------------------------------------------------------------------------
ledger_save <- function(ledger, output_dir) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  ledger <- ledger_conform(ledger)
  paths  <- ledger_paths(output_dir)
  saveRDS(ledger, paths$rds)
  write_csv(ledger, paths$csv)
  invisible(ledger)
}
