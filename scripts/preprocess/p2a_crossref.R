# ==============================================================================
# STAGE 2a: DOI RESOLUTION + CROSSREF METADATA
# ==============================================================================
#
# PURPOSE:
# For each XML, resolve the CORRECT article DOI and attach verified Crossref
# metadata. Uses the DOI resolver (doi_resolver.R), which normalizes GROBID's
# extracted DOI (stripping APA `.supp` supplemental suffixes), verifies every
# candidate against the article's own header metadata (author + year + journal +
# title, canonicalized-exact), and falls back to a bibliographic search when
# there is no usable DOI. Nothing is accepted unless it verifies; the rest are
# flagged needs_review for the downstream resolver.
#
# EXPECTS (from the master environment):
#   ledger              - the audit ledger (tibble)
#   XML_DIR             - folder of GROBID .tei.xml files
#   STAGE_DIRS$crossref / STAGE_OBJECT - output folder + object filename
#   crossref_email      - polite-pool email for rcrossref
#   autosave_frequency  - checkpoint every N files
#   PRE_DIR             - preprocess script folder (to source the resolver)
#
# PRODUCES:
#   ledger              - extracted_doi / crossref_doi / doi_match / meta_found /
#                         resolution_method / verified / needs_review
#   STAGE_DIRS$crossref/articles.rds - list keyed by article_id ($XML raw,
#                         $META verified, $EXTRACTED_DOI, $RESOLVED_DOI)
#   STAGE_DIRS$crossref/doi_log.csv  - per-article resolution audit trail
#   CURRENT_OBJECT      - updated to this stage's object (the baton)
# ==============================================================================

library(xml2)
library(purrr)
library(readr)
library(dplyr)

source(file.path(PRE_DIR, "doi_resolver.R"))

Sys.setenv(crossref_email = crossref_email %||% "your.email@example.com")

xml_files <- list.files(XML_DIR, pattern = "\\.xml$", full.names = TRUE, ignore.case = TRUE)
total_articles <- length(xml_files)
if (total_articles == 0) stop("p2a_crossref: no XML files found in XML_DIR.")

stage_dir <- STAGE_DIRS$crossref
if (!dir.exists(stage_dir)) dir.create(stage_dir, recursive = TRUE)
db_path  <- file.path(stage_dir, STAGE_OBJECT)
log_path <- file.path(stage_dir, "doi_log.csv")

# ---- Resume: reload prior object + log so re-runs pick up where they stopped --
temp_db  <- if (file.exists(db_path)) readRDS(db_path) else list()
log_rows <- list()
if (file.exists(log_path)) {
  prev <- read_csv(log_path, show_col_types = FALSE)
  for (k in seq_len(nrow(prev))) log_rows[[prev$article_id[k]]] <- prev[k, ]
}
cat(sprintf("  [OK] Resolving %d article(s) (%d already done)...\n",
            total_articles, sum(vapply(temp_db, function(x) isTRUE(x$DONE), logical(1)))))

pb <- txtProgressBar(min = 0, max = total_articles, style = 3)

for (i in seq_along(xml_files)) {
  f <- xml_files[i]
  key <- article_id_from_xml(f)

  if (isTRUE(temp_db[[key]]$DONE)) { setTxtProgressBar(pb, i); next }

  doc <- tryCatch(read_xml(f), error = function(e) NULL)
  if (is.null(doc)) {
    temp_db[[key]] <- list(XML = NA_character_, META = list(),
                           EXTRACTED_DOI = NA, RESOLVED_DOI = NA, DONE = TRUE)
    log_rows[[key]] <- tibble(article_id = key, doi_raw = NA, doi_normalized = NA,
                              had_supp = NA, doi_resolved = NA,
                              resolution_method = "parse_error", verified = FALSE,
                              needs_review = TRUE, title_ok = NA, author_ok = NA,
                              year_ok = NA, journal_ok = NA, cr_type = NA)
    setTxtProgressBar(pb, i); next
  }

  xm <- xml_article_meta(doc)
  r  <- resolve_article(xm, id = key)

  temp_db[[key]] <- list(
    XML = as.character(doc), META = r$META,
    EXTRACTED_DOI = r$doi_raw, RESOLVED_DOI = r$doi_resolved, DONE = TRUE
  )
  log_rows[[key]] <- tibble(
    article_id = key, doi_raw = r$doi_raw %||% NA, doi_normalized = r$doi_normalized %||% NA,
    had_supp = r$had_supp, doi_resolved = r$doi_resolved %||% NA,
    resolution_method = r$resolution_method, verified = r$verified, needs_review = r$needs_review,
    title_ok = r$title_ok, author_ok = r$author_ok, year_ok = r$year_ok,
    journal_ok = r$journal_ok, cr_type = r$cr_type %||% NA
  )

  Sys.sleep(0.02)
  setTxtProgressBar(pb, i)
  if (i %% autosave_frequency == 0) {
    saveRDS(temp_db, db_path); write_csv(bind_rows(log_rows), log_path)
  }
}
close(pb)

saveRDS(temp_db, db_path)
log_df <- bind_rows(log_rows)
write_csv(log_df, log_path)

# ---- Fold the resolution outcome into the ledger -----------------------------
upd <- log_df |> transmute(
  article_id,
  extracted_doi     = doi_raw,
  crossref_doi      = doi_resolved,
  doi_match         = !is.na(doi_raw) & !is.na(doi_resolved) & tolower(doi_raw) == tolower(doi_resolved),
  meta_found        = verified,
  resolution_method = resolution_method,
  verified          = verified,
  needs_review      = needs_review
)
ledger <- ledger_upsert(ledger, upd, stage = "p2a_crossref")

CURRENT_OBJECT <- db_path

cat(sprintf("\n  [OK] Metadata object saved: %s\n", db_path))
cat(sprintf("  [OK] DOI log saved: %s\n", log_path))
cat("  [SUMMARY] Resolution methods:\n")
print(count(log_df, resolution_method, name = "n") |> arrange(desc(n)))
cat(sprintf("  needs_review: %d / %d\n", sum(log_df$needs_review), nrow(log_df)))
