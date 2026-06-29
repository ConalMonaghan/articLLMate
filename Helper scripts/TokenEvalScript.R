library(here)
library(tidyverse)

## This runs AFTER the token computation script, and tries to identify whyy some token # are massive

# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

INPUT_PATH   <- here("input", "R_obs_clean")   # Folder of cleaned .rds files
OUTPUT_PATH  <- here("output", "diagnosticsFinal")  # Where to save the diagnostic outputs
n_inspect    <- 20                              # How many outliers to inspect
token_thresh <- 30000                           # Flag articles above this token count


# ==============================================================================
# SETUP
# ==============================================================================

if (!dir.exists(OUTPUT_PATH)) dir.create(OUTPUT_PATH, recursive = TRUE)

rds_files <- list.files(INPUT_PATH, pattern = "\\.rds$", full.names = TRUE, ignore.case = TRUE)
if (length(rds_files) == 0) stop("No .rds files found in INPUT_PATH.")

cat(sprintf("Found %d .rds file(s)\n\n", length(rds_files)))


# ==============================================================================
# LOAD ALL ARTICLES
# ==============================================================================

all_articles <- list()
source_map   <- character(0)

for (rds_path in rds_files) {
  file_label <- tools::file_path_sans_ext(basename(rds_path))
  obj        <- readRDS(rds_path)
  all_articles <- c(all_articles, obj)
  source_map   <- c(source_map, setNames(rep(file_label, length(obj)), names(obj)))
}

cat(sprintf("Total articles: %d\n\n", length(all_articles)))


# ==============================================================================
# COMPUTE CHARACTER COUNTS (fast proxy for tokens, no tiktoken needed)
# ==============================================================================

cat("Computing character and word counts...\n")

diag_tbl <- tibble(
  article_id  = names(all_articles),
  rds_source  = source_map[names(all_articles)],
  has_title   = map_lgl(all_articles, ~ !is.null(.x$XML$Title)   && !is.na(.x$XML$Title)),
  has_body    = map_lgl(all_articles, ~ !is.null(.x$XML$Text)    && !is.na(.x$XML$Text)),
  has_abstract= map_lgl(all_articles, ~ !is.null(.x$XML$Abstract)&& !is.na(.x$XML$Abstract)),
  n_chars_title    = map_int(all_articles, ~ nchar(.x$XML$Title    %||% "")),
  n_chars_abstract = map_int(all_articles, ~ nchar(.x$XML$Abstract %||% "")),
  n_chars_body     = map_int(all_articles, ~ nchar(.x$XML$Text     %||% "")),
  n_words_body     = map_int(all_articles, ~ lengths(strsplit(trimws(.x$XML$Text %||% ""), "\\s+")))
) %>%
  mutate(
    n_chars_total   = n_chars_title + n_chars_abstract + n_chars_body,
    approx_tokens   = round(n_chars_total / 4),   # ~4 chars per token rule of thumb
    flagged         = approx_tokens > token_thresh
  ) %>%
  arrange(desc(approx_tokens))


# ==============================================================================
# SUMMARY: FLAGGED ARTICLES
# ==============================================================================

cat(paste(rep("=", 60), collapse = ""), "\n")
cat(sprintf("Articles above %s token threshold: %d / %d (%.1f%%)\n",
            formatC(token_thresh, format = "d", big.mark = ","),
            sum(diag_tbl$flagged),
            nrow(diag_tbl),
            mean(diag_tbl$flagged) * 100))
cat(paste(rep("=", 60), collapse = ""), "\n\n")

cat("Top outliers by approximate token count:\n\n")
diag_tbl %>%
  head(n_inspect) %>%
  select(article_id, rds_source, n_words_body, n_chars_body, approx_tokens) %>%
  print(n = n_inspect)


# ==============================================================================
# INSPECT BODY TEXT OF TOP OUTLIERS
# ==============================================================================

cat("\n\nPREVIEW OF TOP OUTLIER BODY TEXT (first and last 500 chars)\n")
cat(paste(rep("=", 60), collapse = ""), "\n")

top_keys <- head(diag_tbl$article_id, n_inspect)

for (key in top_keys) {
  
  body <- all_articles[[key]]$XML$Text %||% ""
  
  cat(sprintf("\n--- %s  [source: %s]  [~%s tokens]\n",
              key,
              source_map[key],
              formatC(diag_tbl$approx_tokens[diag_tbl$article_id == key],
                      format = "d", big.mark = ",")))
  
  cat("  >> FIRST 500 chars:\n")
  cat(substr(body, 1, 500))
  
  cat("\n\n  >> LAST 500 chars:\n")
  cat(substr(body, max(1, nchar(body) - 500), nchar(body)))
  
  cat("\n", paste(rep("-", 40), collapse = ""), "\n")
}


# ==============================================================================
# CHECK: ARE SHORT ARTICLES ACTUALLY EMPTY?
# ==============================================================================

cat("\n\nARTICLES WITH VERY SHORT BODY TEXT (< 200 words)\n")
cat(paste(rep("=", 60), collapse = ""), "\n")

short_articles <- diag_tbl %>%
  filter(n_words_body < 200) %>%
  arrange(n_words_body)

cat(sprintf("  Count: %d\n\n", nrow(short_articles)))

short_articles %>%
  select(article_id, rds_source, has_title, has_body, n_words_body, n_chars_body) %>%
  print(n = 30)


# ==============================================================================
# SAVE FULL DIAGNOSTIC TABLE
# ==============================================================================

csv_path <- file.path(OUTPUT_PATH, "article_diagnostics.csv")
write_csv(diag_tbl, csv_path)
cat(sprintf("\n\n[OK] Full diagnostic table saved: %s\n", csv_path))

cat("\nDone. Check the FIRST/LAST 500 chars of outliers above — look for:\n")
cat("  - Reference list debris at the end\n")
cat("  - XML tag fragments still in the text\n")
cat("  - Repeated content / encoding artefacts\n")
cat("  - Articles that are legitimately very long (reviews, meta-analyses)\n")