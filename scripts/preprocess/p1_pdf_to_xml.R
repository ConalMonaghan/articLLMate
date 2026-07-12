# ==============================================================================
# STAGE 1: PDF -> XML (GROBID) + RECONCILIATION
# ==============================================================================
#
# PURPOSE:
# Reconcile the original PDF corpus against the XML that GROBID actually
# produced. This stage does NOT run GROBID itself — the GROBID Docker + Python
# step ("PDF XML pipeline/1_pdf to xml.py") is run as a documented pre-step
# because it needs a running GROBID server and a GPU. Instead, this stage
# detects the resulting XML files and records, per article, whether extraction
# succeeded.
#
# This is where "number of original articles" becomes auditable: any PDF with
# no matching XML is flagged grobid_status = "failed".
#
# EXPECTS (from the master environment):
#   ledger    - the audit ledger (tibble)
#   XML_DIR   - folder of GROBID .tei.xml output
#   source_batch, ingest_route
#
# PRODUCES:
#   ledger    - reassigned with xml_created / grobid_status / xml_path filled
#
# KEY MATCHING:
# GROBID names output "<stem>.grobid.tei.xml" from "<stem>.pdf", so the article
# id (filename stem) is the join key between the PDF seed rows and XML files.
# ==============================================================================

article_id_from_xml <- function(xml_path) {
  sub("\\.grobid\\.tei(\\.xml)?$|\\.tei(\\.xml)?$|\\.xml$", "",
      basename(xml_path), ignore.case = TRUE)
}

if (is.null(XML_DIR) || (length(XML_DIR) == 1 && is.na(XML_DIR)) || !dir.exists(XML_DIR)) {
  stop("p1_pdf_to_xml: XML_DIR is required and must exist: ", XML_DIR %||% "NA")
}

xml_files <- list.files(XML_DIR, pattern = "\\.xml$", full.names = TRUE, ignore.case = TRUE)
n_xml <- length(xml_files)
cat(sprintf("  [OK] Found %d XML file(s) in: %s\n", n_xml, XML_DIR))

xml_tbl <- tibble(
  article_id   = article_id_from_xml(xml_files),
  xml_path     = xml_files,
  xml_created  = TRUE,
  grobid_status = "ok",
  source_batch = source_batch,
  ingest_route = ingest_route
)

# Upsert the XML successes. New article_ids (XML with no seeded PDF) are added,
# which covers the "start from XML stage" fallback.
ledger <- ledger_upsert(ledger, xml_tbl, stage = "p1_pdf_to_xml")

# ---- Reconcile: any seeded PDF row that still has no XML failed GROBID --------
seeded_pdfs <- !is.na(ledger$pdf_path)
no_xml      <- is.na(ledger$xml_created) | !isTRUE_vec(ledger$xml_created)
failed_idx  <- which(seeded_pdfs & no_xml)

if (length(failed_idx) > 0) {
  failed <- tibble(
    article_id    = ledger$article_id[failed_idx],
    xml_created   = FALSE,
    grobid_status = "failed"
  )
  ledger <- ledger_upsert(ledger, failed, stage = "p1_pdf_to_xml")
}

n_seeded  <- sum(seeded_pdfs)
n_ok      <- sum(isTRUE_vec(ledger$xml_created))
n_failed  <- length(failed_idx)

cat(sprintf("  [RECONCILE] PDFs seeded: %d  |  XML produced: %d  |  GROBID failures: %d\n",
            n_seeded, n_ok, n_failed))
if (n_failed > 0) {
  cat("  [WARN] Some PDFs produced no XML (see grobid_status = 'failed' in ledger).\n")
}
