# ==============================================================================
# STAGE 2c: LENGTH FILTER (screen out too-short / too-long articles)
# ==============================================================================
#
# PURPOSE:
# Word-count screen: articles below MIN_WORDS are likely failed extractions;
# above MAX_WORDS are likely conference-abstract books / junk. Logging-aware
# refactor of "PDF XML pipeline/4. Strip_poor_files.R": same thresholds and
# exclusion CSVs, but operating on the single slimmed object from stage 2b and
# recording each article's length_status in the audit ledger.
#
# EXPECTS (from the master environment):
#   ledger        - the audit ledger (tibble)
#   CURRENT_OBJECT- path to the previous stage's object (baton); falls back to
#                   STAGE_DIRS$body/articles.rds
#   STAGE_DIRS$length / STAGE_OBJECT - this stage's output folder + filename
#   MIN_WORDS, MAX_WORDS
#
# PRODUCES:
#   ledger        - n_words / length_status filled
#   STAGE_DIRS$length/articles.rds - kept articles only
#   STAGE_DIRS$length/excluded_{short,long}.csv - exclusion reports
#   CURRENT_OBJECT- updated to this stage's object (the baton)
# ==============================================================================

library(purrr)
library(readr)

in_path <- if (!is.na(CURRENT_OBJECT) && file.exists(CURRENT_OBJECT)) {
  CURRENT_OBJECT
} else {
  file.path(STAGE_DIRS$body, STAGE_OBJECT)
}
stage_dir <- STAGE_DIRS$length
if (!dir.exists(stage_dir)) dir.create(stage_dir, recursive = TRUE)
out_path <- file.path(stage_dir, STAGE_OBJECT)

if (!file.exists(in_path)) {
  stop("p2c_length_filter: expected input not found (run stage 2b first): ", in_path)
}

obj <- readRDS(in_path)
if (!is.list(obj) || length(obj) == 0) stop("p2c_length_filter: empty object.")

keys <- names(obj)
n_total <- length(keys)

word_counts <- map_int(obj, ~ lengths(strsplit(trimws(.x$XML$Text %||% ""), "\\s+")))

length_status <- ifelse(word_counts < MIN_WORDS, "too_short",
                 ifelse(word_counts > MAX_WORDS, "too_long", "kept"))

upd <- tibble(
  article_id    = keys,
  n_words       = as.integer(word_counts),
  length_status = length_status
)
ledger <- ledger_upsert(ledger, upd, stage = "p2c_length_filter")

# ---- Exclusion CSVs ----------------------------------------------------------
excl <- upd %>%
  dplyr::filter(length_status != "kept") %>%
  dplyr::mutate(
    title  = map_chr(article_id, ~ obj[[.x]]$XML$Title %||% NA_character_),
    reason = length_status
  )

if (any(excl$length_status == "too_short")) {
  write_csv(dplyr::filter(excl, length_status == "too_short"),
            file.path(stage_dir, "excluded_short.csv"))
}
if (any(excl$length_status == "too_long")) {
  write_csv(dplyr::filter(excl, length_status == "too_long"),
            file.path(stage_dir, "excluded_long.csv"))
}

# ---- Save kept-only object ---------------------------------------------------
keep_keys <- keys[length_status == "kept"]
saveRDS(obj[keep_keys], out_path)

n_short <- sum(length_status == "too_short")
n_long  <- sum(length_status == "too_long")
n_kept  <- length(keep_keys)

cat(sprintf("  [SUMMARY] Total: %d  |  Too short: %d  |  Too long: %d  |  Kept: %d\n",
            n_total, n_short, n_long, n_kept))
cat(sprintf("  [OK] Screened object saved: %s\n", out_path))

CURRENT_OBJECT <- out_path
