# ==============================================================================
# STAGE 2a: DOI DETECTION + CROSSREF METADATA
# ==============================================================================
#
# PURPOSE:
# For each XML, extract the GROBID DOI and (if present) enrich with Crossref
# metadata. This is a logging-aware refactor of "PDF XML pipeline/2. XML and X
# crossref to R.R": same core logic, but it (a) reads its levers from the master
# environment, (b) reports per-article status into the audit ledger, and (c)
# records extracted_doi vs the DOI Crossref returns so mismatches are auditable.
#
# EXPECTS (from the master environment):
#   ledger              - the audit ledger (tibble)
#   XML_DIR             - folder of GROBID .tei.xml files
#   STAGE_DIRS$crossref - output folder for this stage (02a_Crossref_Metadata)
#   STAGE_OBJECT        - standard object filename ("articles.rds")
#   crossref_email      - polite-pool email for rcrossref
#   autosave_frequency  - checkpoint the .rds every N files
#
# PRODUCES:
#   ledger              - extracted_doi / crossref_doi / doi_match / meta_found
#   STAGE_DIRS$crossref/articles.rds - list keyed by article_id with
#                                      $XML (raw), $EXTRACTED_DOI, $META
#   CURRENT_OBJECT      - updated to point at this stage's object (the baton)
# ==============================================================================

library(xml2)
library(purrr)
library(rcrossref)

Sys.setenv(crossref_email = crossref_email %||% "your.email@example.com")

article_id_from_xml <- function(xml_path) {
  sub("\\.grobid\\.tei(\\.xml)?$|\\.tei(\\.xml)?$|\\.xml$", "",
      basename(xml_path), ignore.case = TRUE)
}

xml_files <- list.files(XML_DIR, pattern = "\\.xml$", full.names = TRUE, ignore.case = TRUE)
total_articles <- length(xml_files)
if (total_articles == 0) stop("p2a_crossref: no XML files found in XML_DIR.")

stage_dir <- STAGE_DIRS$crossref
if (!dir.exists(stage_dir)) dir.create(stage_dir, recursive = TRUE)
db_path <- file.path(stage_dir, STAGE_OBJECT)

# Resume: load an existing enriched object if present.
if (file.exists(db_path)) {
  temp_db <- readRDS(db_path)
  cat(sprintf("  [OK] Loaded existing metadata object with %d record(s).\n", length(temp_db)))
} else {
  temp_db <- list()
  cat("  [OK] Starting fresh metadata object.\n")
}

cat(sprintf("  Processing %d XML file(s) for DOI + Crossref...\n", total_articles))
pb <- txtProgressBar(min = 0, max = total_articles, style = 3)

# Accumulate per-article ledger updates.
upd <- vector("list", total_articles)

for (i in seq_along(xml_files)) {
  current_file <- xml_files[i]
  list_key <- article_id_from_xml(current_file)

  # Checkpoint: skip if already enriched.
  if (!is.null(temp_db[[list_key]]$META) && length(temp_db[[list_key]]$META) > 0) {
    prev_doi <- temp_db[[list_key]]$EXTRACTED_DOI %||% NA_character_
    upd[[i]] <- tibble(article_id = list_key,
                       extracted_doi = prev_doi,
                       meta_found = TRUE)
    setTxtProgressBar(pb, i)
    next
  }

  doc <- tryCatch(read_xml(current_file), error = function(e) NULL)
  xml_string <- if (!is.null(doc)) as.character(doc) else NA_character_
  meta <- list()
  extracted_doi <- NA_character_
  crossref_doi  <- NA_character_

  if (!is.null(doc)) {
    xml_ns_strip(doc)
    doi_node <- xml_find_first(doc, "//idno[@type='DOI']")
    extracted_doi <- if (!is.na(doi_node)) xml_text(doi_node) else NA_character_

    if (!is.na(extracted_doi) && extracted_doi != "") {
      safe_cr <- safely(cr_works)(extracted_doi)
      if (!is.null(safe_cr$result)) {
        meta <- safe_cr$result$data
        if (!is.null(meta$doi)) crossref_doi <- meta$doi[1]
      }
    }
  }

  temp_db[[list_key]] <- list(
    XML = xml_string,
    EXTRACTED_DOI = extracted_doi,
    META = meta
  )

  meta_found <- length(meta) > 0
  doi_match  <- if (!is.na(extracted_doi) && !is.na(crossref_doi)) {
    tolower(extracted_doi) == tolower(crossref_doi)
  } else NA

  upd[[i]] <- tibble(
    article_id    = list_key,
    extracted_doi = extracted_doi,
    crossref_doi  = crossref_doi,
    doi_match     = doi_match,
    meta_found    = meta_found
  )

  Sys.sleep(0.1)
  setTxtProgressBar(pb, i)

  if (i %% autosave_frequency == 0) saveRDS(temp_db, db_path)
}

close(pb)
saveRDS(temp_db, db_path)

# Push all per-article updates into the ledger in one merge.
ledger <- ledger_upsert(ledger, bind_rows(upd), stage = "p2a_crossref")

n_meta   <- sum(isTRUE_vec(ledger$meta_found))
n_no_doi <- sum(is.na(ledger$extracted_doi) & isTRUE_vec(ledger$xml_created))
n_mismatch <- sum(ledger$doi_match == FALSE, na.rm = TRUE)

cat(sprintf("\n  [OK] Metadata object saved: %s\n", db_path))
cat(sprintf("  [SUMMARY] Metadata found: %d  |  No DOI in XML: %d  |  DOI mismatches: %d\n",
            n_meta, n_no_doi, n_mismatch))

# Pass the baton: this object is the input to the next producing stage.
CURRENT_OBJECT <- db_path
