# ==============================================================================
# STEP 1b: DISCOVER ARTICLES FROM RDS OBJECTS
# ==============================================================================
# PURPOSE:  Load articles from .rds R objects. Supports a single .rds file
#           or a folder containing multiple .rds files.
#
#           Expected RDS structure (per article):
#             PUBLISHER$`DOI`$XML$Title
#             PUBLISHER$`DOI`$XML$DOI
#             PUBLISHER$`DOI`$XML$Text
#             PUBLISHER$`DOI`$EXTRACTED_DOI
#             PUBLISHER$`DOI`$META
#
# EXPECTS FROM MASTER:  INPUT_FILE, OUTPUT_DIR
# CREATES:              article_keys (character vector of DOIs),
#                        articles_data (named list of article entries),
#                        n_articles (integer)
# ==============================================================================

cat("Looking for RDS articles...\n")

# ---- 1a. Load RDS file(s) ----
rds_files <- character(0)

if (file.exists(INPUT_FILE) && !dir.exists(INPUT_FILE)) {
  # INPUT_FILE is a single .rds file
  rds_files <- INPUT_FILE
  cat(sprintf("  [OK] Single RDS file: %s\n", INPUT_FILE))

} else if (dir.exists(INPUT_FILE)) {
  # INPUT_FILE points to a folder — find all .rds files in it
  rds_files <- list.files(INPUT_FILE, pattern = "\\.rds$", full.names = TRUE, ignore.case = TRUE)
  cat(sprintf("  [OK] Found %d .rds file(s) in folder: %s\n", length(rds_files), INPUT_FILE))

} else {
  stop(
    "\n\n",
    "=== RDS INPUT NOT FOUND ===\n",
    "Cannot find: ", INPUT_FILE, "\n",
    "Set INPUT_FILE in _MASTER_RUN_PIPELINE.R to a .rds file or a folder of .rds files.\n"
  )
}

if (length(rds_files) == 0) {
  stop(
    "\n\n",
    "=== NO RDS FILES FOUND ===\n",
    "Directory exists but contains no .rds files: ", INPUT_FILE, "\n"
  )
}

# ---- 1b. Load and combine all RDS objects ----
articles_data <- list()
rds_source_map <- list()  # tracks which RDS file each article came from

for (rds_path in rds_files) {
  cat(sprintf("  Loading: %s ...\n", basename(rds_path)))
  rds_obj <- readRDS(rds_path)

  # The RDS object is a named list keyed by DOI
  # Each entry should have $XML$Text at minimum
  if (!is.list(rds_obj) || length(rds_obj) == 0) {
    cat(sprintf("  [WARN] Skipping empty or non-list object: %s\n", basename(rds_path)))
    next
  }

  # Track source file for each article (used by dashboard rds_source column)
  for (k in names(rds_obj)) {
    rds_source_map[[k]] <- basename(rds_path)
  }

  # Merge articles into the combined list
  articles_data <- c(articles_data, rds_obj)
}

# Print per-file article counts when loading from a folder
if (length(rds_files) > 1) {
  cat("\n  Articles per RDS file:\n")
  source_vec <- unlist(rds_source_map)
  for (src in unique(source_vec)) {
    n_from_src <- sum(source_vec == src)
    cat(sprintf("    %-40s %d articles\n", src, n_from_src))
  }
  cat("\n")
}

# ---- 1c. Extract article keys and validate ----
article_keys <- names(articles_data)
n_articles   <- length(article_keys)

if (n_articles == 0) {
  stop(
    "\n\n",
    "=== NO ARTICLES FOUND IN RDS ===\n",
    "The loaded RDS object(s) contain no articles.\n"
  )
}

# Validate that articles have the expected $XML$Text structure
valid_count <- 0
invalid_keys <- character(0)

for (key in article_keys) {
  article <- articles_data[[key]]
  has_text <- !is.null(article$XML$Text) && !is.na(article$XML$Text) && nchar(article$XML$Text) > 0
  if (has_text) {
    valid_count <- valid_count + 1
  } else {
    invalid_keys <- c(invalid_keys, key)
  }
}

cat(sprintf("  [OK] %d articles loaded (%d with valid text, %d missing text)\n",
            n_articles, valid_count, length(invalid_keys)))

if (length(invalid_keys) > 0 && length(invalid_keys) <= 10) {
  cat("  [WARN] Articles missing $XML$Text:\n")
  for (k in invalid_keys) cat(sprintf("         - %s\n", k))
} else if (length(invalid_keys) > 10) {
  cat(sprintf("  [WARN] %d articles missing $XML$Text (showing first 5):\n", length(invalid_keys)))
  for (k in head(invalid_keys, 5)) cat(sprintf("         - %s\n", k))
}

# ---- 1d. Create output directory ----
if (!dir.exists(OUTPUT_DIR)) {
  dir.create(OUTPUT_DIR, recursive = TRUE)
  cat(sprintf("  [OK] Created output directory:\n       %s\n", OUTPUT_DIR))
} else {
  existing_jsons <- list.files(OUTPUT_DIR, pattern = "\\.json$")
  if (length(existing_jsons) > 0) {
    cat(sprintf("  [NOTE] Output directory already contains %d .json files from a previous run.\n",
                length(existing_jsons)))
    cat("         Existing files will be overwritten if the same articles are processed.\n")
  }
  cat(sprintf("  [OK] Output directory exists:\n       %s\n", OUTPUT_DIR))
}

cat(sprintf("\nArticle discovery complete. %d articles queued for analysis.\n", n_articles))
