library(here)
library(tidyverse)


# This script screens all .rds files in a folder, removes articles that are too
# short (failed extraction) or too long (conference abstract books / junk), and
# saves three outputs per source file:
#   1. A cleaned .rds with only valid articles
#   2. A "too short" exclusion list (.csv)
#   3. A "too long" exclusion list (.csv)
# Plus a single combined exclusion report across all files.


# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

INPUT_PATH   <- here("input", "R_obs_short")    # Folder of cleaned .rds files
OUTPUT_PATH  <- here("input", "R_obs_clean") # Where to save filtered .rds files
REPORT_PATH  <- here("output", "diagnostics")   # Where to save exclusion reports

MIN_WORDS    <- 500     # Exclude articles with fewer words than this
MAX_WORDS    <- 30000   # Exclude articles with more words than this


# ==============================================================================
# SETUP
# ==============================================================================

# Null coalescing operator — returns b if a is NULL, NA, or length 0
`%||%` <- function(a, b) if (!is.null(a) && !is.na(a) && length(a) > 0) a else b

if (!dir.exists(OUTPUT_PATH)) dir.create(OUTPUT_PATH, recursive = TRUE)
if (!dir.exists(REPORT_PATH)) dir.create(REPORT_PATH, recursive = TRUE)

rds_files <- list.files(INPUT_PATH, pattern = "\\.rds$", full.names = TRUE, ignore.case = TRUE)
if (length(rds_files) == 0) stop("No .rds files found in INPUT_PATH.")

cat("Article Length Screener\n")
cat(paste(rep("=", 60), collapse = ""), "\n")
cat(sprintf("  Input folder:   %s\n", INPUT_PATH))
cat(sprintf("  Output folder:  %s\n", OUTPUT_PATH))
cat(sprintf("  Min words:      %s\n", formatC(MIN_WORDS, format = "d", big.mark = ",")))
cat(sprintf("  Max words:      %s\n", formatC(MAX_WORDS, format = "d", big.mark = ",")))
cat(sprintf("  Files found:    %d\n\n", length(rds_files)))


# ==============================================================================
# PROCESS EACH FILE
# ==============================================================================

# Accumulate exclusion rows across all files for the combined report
all_excluded_short <- list()
all_excluded_long  <- list()

# Accumulate per-file summary rows for the final table
summary_rows <- list()

for (rds_path in rds_files) {

  file_label  <- tools::file_path_sans_ext(basename(rds_path))
  output_file <- file.path(OUTPUT_PATH, paste0(file_label, "_screened.rds"))

  cat(paste(rep("-", 60), collapse = ""), "\n")
  cat(sprintf("Processing: %s\n", basename(rds_path)))

  obj <- readRDS(rds_path)
  if (!is.list(obj) || length(obj) == 0) {
    cat("  [WARN] Empty or non-list object — skipping.\n\n")
    next
  }

  n_total <- length(obj)
  keys    <- names(obj)

  # ----------------------------------------------------------------------------
  # Compute word count for every article in this file
  # ----------------------------------------------------------------------------
  word_counts <- map_int(obj, ~ lengths(strsplit(trimws(.x$XML$Text %||% ""), "\\s+")))

  # ----------------------------------------------------------------------------
  # Classify each article
  # ----------------------------------------------------------------------------
  too_short <- keys[word_counts < MIN_WORDS]
  too_long  <- keys[word_counts > MAX_WORDS]
  keep      <- keys[word_counts >= MIN_WORDS & word_counts <= MAX_WORDS]

  n_short   <- length(too_short)
  n_long    <- length(too_long)
  n_kept    <- length(keep)

  cat(sprintf("  Total articles:   %d\n", n_total))
  cat(sprintf("  Too short (<%-5d words): %d  (%.1f%%)\n", MIN_WORDS, n_short, n_short / n_total * 100))
  cat(sprintf("  Too long  (>%-5d words): %d  (%.1f%%)\n", MAX_WORDS, n_long,  n_long  / n_total * 100))
  cat(sprintf("  Retained:                 %d  (%.1f%%)\n\n", n_kept, n_kept / n_total * 100))

  # ----------------------------------------------------------------------------
  # Build exclusion tables for this file
  # ----------------------------------------------------------------------------

  # Helper: build a tidy exclusion tibble for a set of keys
  make_exclusion_tbl <- function(exc_keys, reason_label) {
    if (length(exc_keys) == 0) return(tibble())
    tibble(
      article_id    = exc_keys,
      rds_source    = file_label,
      n_words       = word_counts[exc_keys],
      approx_tokens = round(word_counts[exc_keys] * 1.3),
      title         = map_chr(exc_keys,
                        ~ obj[[.x]]$XML$Title %||% NA_character_),
      reason        = reason_label
    )
  }

  tbl_short <- make_exclusion_tbl(too_short, paste0("Too short (< ", MIN_WORDS, " words)"))
  tbl_long  <- make_exclusion_tbl(too_long,  paste0("Too long  (> ", MAX_WORDS, " words)"))

  # Save per-file exclusion CSVs
  if (nrow(tbl_short) > 0) {
    short_csv <- file.path(REPORT_PATH, paste0(file_label, "_excluded_short.csv"))
    write_csv(tbl_short, short_csv)
    cat(sprintf("  [OK] Short exclusion list saved: %s\n", basename(short_csv)))
  }

  if (nrow(tbl_long) > 0) {
    long_csv <- file.path(REPORT_PATH, paste0(file_label, "_excluded_long.csv"))
    write_csv(tbl_long, long_csv)
    cat(sprintf("  [OK] Long exclusion list saved:  %s\n", basename(long_csv)))

    # Print the long exclusions so they're visible in console — these are the
    # ones worth knowing about by name
    cat("\n  Articles excluded as too long:\n")
    tbl_long %>%
      arrange(desc(n_words)) %>%
      { for (r in seq_len(nrow(.)))
          cat(sprintf("    %-40s  %s words  |  %s\n",
                      .$article_id[r],
                      formatC(.$n_words[r], format = "d", big.mark = ","),
                      substr(.$title[r] %||% "(no title)", 1, 60))) }
  }

  cat("\n")

  # Accumulate for combined report
  all_excluded_short[[file_label]] <- tbl_short
  all_excluded_long[[file_label]]  <- tbl_long

  # ----------------------------------------------------------------------------
  # Save the filtered .rds (kept articles only)
  # ----------------------------------------------------------------------------
  obj_clean <- obj[keep]
  saveRDS(obj_clean, file = output_file)
  cat(sprintf("  [OK] Screened object saved: %s  (%d articles)\n\n",
              basename(output_file), n_kept))

  # Accumulate summary
  summary_rows[[file_label]] <- tibble(
    source   = file_label,
    n_total  = n_total,
    n_short  = n_short,
    n_long   = n_long,
    n_kept   = n_kept,
    pct_kept = round(n_kept / n_total * 100, 1)
  )
}


# ==============================================================================
# COMBINED EXCLUSION REPORT
# ==============================================================================

cat(paste(rep("=", 60), collapse = ""), "\n")
cat("COMBINED SCREENING SUMMARY\n")
cat(paste(rep("=", 60), collapse = ""), "\n\n")

summary_tbl <- bind_rows(summary_rows)

# Totals row
totals <- tibble(
  source   = "TOTAL",
  n_total  = sum(summary_tbl$n_total),
  n_short  = sum(summary_tbl$n_short),
  n_long   = sum(summary_tbl$n_long),
  n_kept   = sum(summary_tbl$n_kept),
  pct_kept = round(sum(summary_tbl$n_kept) / sum(summary_tbl$n_total) * 100, 1)
)

bind_rows(summary_tbl, totals) %>%
  { for (r in seq_len(nrow(.)))
      cat(sprintf("  %-35s  total=%-6d  short=%-5d  long=%-4d  kept=%-6d  (%.1f%%)\n",
                  .$source[r], .$n_total[r], .$n_short[r],
                  .$n_long[r], .$n_kept[r], .$pct_kept[r])) }

# Save combined exclusion CSVs
combined_short <- bind_rows(all_excluded_short)
combined_long  <- bind_rows(all_excluded_long)

if (nrow(combined_short) > 0) {
  combined_short_path <- file.path(REPORT_PATH, "ALL_excluded_short.csv")
  write_csv(combined_short, combined_short_path)
  cat(sprintf("\n  [OK] Combined short exclusion list: %s  (%d articles)\n",
              basename(combined_short_path), nrow(combined_short)))
}

if (nrow(combined_long) > 0) {
  combined_long_path <- file.path(REPORT_PATH, "ALL_excluded_long.csv")
  write_csv(combined_long, combined_long_path)
  cat(sprintf("  [OK] Combined long exclusion list:  %s  (%d articles)\n",
              basename(combined_long_path), nrow(combined_long)))
}

cat("\nDone.\n")