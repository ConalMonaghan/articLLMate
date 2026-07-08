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
#   OUTPUT_DIR    - folder holding <source_batch>_Clean.rds (from stage 2b)
#   REPORT_DIR    - where exclusion CSVs are written
#   source_batch  - used to locate the input object and name outputs
#   MIN_WORDS, MAX_WORDS
#
# PRODUCES:
#   ledger        - n_words / length_status filled
#   <OUTPUT_DIR>/<source_batch>_Screened.rds - kept articles only
#   <REPORT_DIR>/<source_batch>_excluded_{short,long}.csv
# ==============================================================================

library(purrr)
library(readr)

in_path  <- file.path(OUTPUT_DIR, paste0(source_batch, "_Clean.rds"))
out_path <- file.path(OUTPUT_DIR, paste0(source_batch, "_Screened.rds"))

if (!file.exists(in_path)) {
  stop("p2c_length_filter: expected input not found (run stage 2b first): ", in_path)
}
if (!dir.exists(REPORT_DIR)) dir.create(REPORT_DIR, recursive = TRUE)

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
            file.path(REPORT_DIR, paste0(source_batch, "_excluded_short.csv")))
}
if (any(excl$length_status == "too_long")) {
  write_csv(dplyr::filter(excl, length_status == "too_long"),
            file.path(REPORT_DIR, paste0(source_batch, "_excluded_long.csv")))
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
