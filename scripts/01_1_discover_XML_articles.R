# ==============================================================================
# STEP 1: DISCOVER ARTICLES
# ==============================================================================
# PURPOSE:  Find all .xml files in the input directory, count them,
#           and set up the output directory.
#
# EXPECTS FROM MASTER:  INPUT_DIR, OUTPUT_DIR
# CREATES:              xml_files (character vector), n_articles (integer)
# ==============================================================================



cat("Looking for articles...\n")

# ---- 1a. Check input directory exists ----
if (!dir.exists(INPUT_DIR)) {
  stop(
    "\n\n",
    "=== INPUT DIRECTORY NOT FOUND ===\n",
    "Cannot find: ", INPUT_DIR, "\n",
    "Check the INPUT_DIR path in _MASTER_RUN_PIPELINE.R\n"
  )
}

# ---- 1b. Find all .xml files ----
xml_files  <- list.files(INPUT_DIR, pattern = "\\.xml$", full.names = TRUE)
n_articles <- length(xml_files)

if (n_articles == 0) {
  stop(
    "\n\n",
    "=== NO XML FILES FOUND ===\n",
    "Directory exists but contains no .xml files: ", INPUT_DIR, "\n",
    "This pipeline expects .xml format. If you have .pdf files,\n",
    "run the pdf-to-xml conversion pipeline first.\n"
  )
}

cat(sprintf("  [OK] Found %d .xml documents in:\n       %s\n", n_articles, INPUT_DIR))

# ---- 1c. Create output directory ----
if (!dir.exists(OUTPUT_DIR)) {
  dir.create(OUTPUT_DIR, recursive = TRUE)
  cat(sprintf("  [OK] Created output directory:\n       %s\n", OUTPUT_DIR))
} else {
  # Check if there are already some .json results (partial previous run)
  existing_jsons <- list.files(OUTPUT_DIR, pattern = "\\.json$")
  if (length(existing_jsons) > 0) {
    cat(sprintf("  [NOTE] Output directory already contains %d .json files from a previous run.\n",
                length(existing_jsons)))
    cat("         Existing files will be overwritten if the same articles are processed.\n")
  }
  cat(sprintf("  [OK] Output directory exists:\n       %s\n", OUTPUT_DIR))
}

cat(sprintf("\nArticle discovery complete. %d articles queued for analysis.\n", n_articles))
