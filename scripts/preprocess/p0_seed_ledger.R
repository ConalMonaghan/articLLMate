# ==============================================================================
# STAGE 0: SEED THE LEDGER FROM THE ORIGINAL PDF CORPUS
# ==============================================================================
#
# PURPOSE:
# Establish the TRUE starting N of articles by enumerating the original PDF
# folder. Every downstream count traces back to this seed, so GROBID failures
# (PDFs that never produced an XML) are recorded rather than silently dropped.
#
# EXPECTS (from the master environment):
#   ledger        - the audit ledger (tibble); usually ledger_init() or loaded
#   PDF_DIR       - folder of original .pdf files (or NA to skip PDF seeding)
#   source_batch  - label for this corpus (e.g. "APA", "Sage")
#   ingest_route  - "extraction" (default) | "image" (reserved)
#
# PRODUCES:
#   ledger        - reassigned with one row per original PDF
#
# NOTE:
# If PDF_DIR is NA / missing, the pipeline is being started from the XML stage
# instead (an allowed fallback). In that case this stage does nothing and the
# XML discovery in stage 1 seeds the ledger.
# ==============================================================================

article_id_from_pdf <- function(pdf_path) {
  sub("\\.pdf$", "", basename(pdf_path), ignore.case = TRUE)
}

if (is.null(PDF_DIR) || (length(PDF_DIR) == 1 && is.na(PDF_DIR))) {
  cat("  [SKIP] No PDF_DIR set — ledger will be seeded from the XML stage.\n")
} else if (!dir.exists(PDF_DIR)) {
  cat(sprintf("  [WARN] PDF_DIR does not exist: %s — seeding skipped.\n", PDF_DIR))
} else {
  pdf_files <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE, ignore.case = TRUE)
  n_pdf <- length(pdf_files)
  cat(sprintf("  [OK] Found %d original PDF(s) in: %s\n", n_pdf, PDF_DIR))

  if (n_pdf > 0) {
    seed <- tibble(
      article_id   = article_id_from_pdf(pdf_files),
      source_batch = source_batch,
      ingest_route = ingest_route,
      pdf_path     = pdf_files
    )
    ledger <- ledger_upsert(ledger, seed, stage = "p0_seed_ledger")
    cat(sprintf("  [OK] Seeded ledger with %d article(s) as the starting N.\n", n_pdf))
  }
}
