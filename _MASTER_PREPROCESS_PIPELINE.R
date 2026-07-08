# ==============================================================================
# MASTER PRE-PROCESSING PIPELINE: articLLMate  (data-input phases 0-3)
# ==============================================================================
#
# PURPOSE:
# One place to run the data-input steps that turn a PDF corpus into clean,
# analysis-ready article objects — with a single AUDIT LEDGER that follows every
# article from the original corpus through each stage. Set the levers below, flip
# the stage toggles on/off, and source this whole file. Every stage writes its
# status into output/<project>/audit_ledger.csv, and the run ends with a funnel
# summary reconciling the starting N against what survives.
#
# This mirrors _MASTER_RUN_PIPELINE.R (the main analysis run): config block at
# the top, modular stage scripts sourced in order, communicating through the
# shared R environment.
#
# HOW TO USE:
# 1. (Pre-step) Run GROBID to turn PDFs into XML — see "PDF XML pipeline/
#    1_pdf to xml.py" and docs/preprocess_guide.md. This master detects the
#    resulting XML; it does not run GROBID for you.
# 2. Set the USER CONFIGURATION below.
# 3. Source this entire script.
#
# FUTURE (next branch): an `ingest_route = "image"` path will send PDFs straight
# to a vision model instead of the extraction pipeline. The ledger schema and
# toggles are already shaped for it; only "extraction" is wired up today.
#
# AUTHOR: Dr Conal Monaghan (+ articLLMate Logging branch)
# ==============================================================================

library(here)
library(tibble)
library(dplyr)
library(readr)

# ==============================================================================
# USER CONFIGURATION - Edit these before each run
# ==============================================================================

project_name  <- "my_preprocess"          # Output subfolder under output/
source_batch  <- "TEST"                    # Corpus label (e.g. "APA", "Sage"); also names the .rds objects
ingest_route  <- "extraction"              # "extraction" (wired) | "image" (reserved for a later branch)
env_name      <- "articLLMate"             # Conda env (used by the token stage)

# ---- Input / output paths ----
PDF_DIR    <- NA                                       # Folder of ORIGINAL .pdf files (NA = start from XML, no GROBID reconciliation)
XML_DIR    <- here("input", "Test xml files")          # Folder of GROBID .tei.xml output
OUTPUT_DIR <- here("output", project_name)             # Objects + ledger + summary (auto-created)
REPORT_DIR <- here("output", project_name, "reports")  # Exclusion CSVs

# ---- Stage toggles: TRUE = run, FALSE = skip ----
run_seed_ledger    <- TRUE     # Stage 0:  seed ledger from PDF corpus (needs PDF_DIR)
run_pdf_to_xml     <- TRUE     # Stage 1:  reconcile PDFs vs GROBID XML
run_crossref       <- TRUE     # Stage 2a: DOI detection + Crossref metadata
run_body_extract   <- TRUE     # Stage 2b: extract Title/DOI/body, slim the XML
run_content_filter <- FALSE    # Stage 2d: TOC/errata/editorial removal (STUB — not implemented)
run_truncate       <- FALSE    # Stage 2e: truncate to main text only (STUB — not implemented)
run_length_filter  <- TRUE     # Stage 2c: word-count screen
run_token_profile  <- TRUE     # Stage 3:  token usage prediction

# ---- Levers ----
crossref_email     <- Sys.getenv("CROSSREF_EMAIL", unset = "your.email@example.com")
autosave_frequency <- 100        # Checkpoint the metadata .rds every N files (stage 2a)
MIN_WORDS          <- 500        # Stage 2c: exclude articles shorter than this
MAX_WORDS          <- 30000      # Stage 2c: exclude articles longer than this
token_encoding     <- "cl100k_base"   # Stage 3: tiktoken encoding

# ==============================================================================
# PIPELINE
# ==============================================================================
#
# Script                        | Purpose                              | Ledger columns filled
# ------------------------------|--------------------------------------|-----------------------------------
# audit_ledger.R                | Ledger helpers (init/upsert/save)    | (infrastructure)
# p0_seed_ledger.R              | Seed from original PDF corpus        | article_id, pdf_path, source_batch
# p1_pdf_to_xml.R               | Reconcile PDFs vs GROBID XML         | xml_created, grobid_status, xml_path
# p2a_crossref.R                | DOI detection + Crossref metadata    | extracted_doi, crossref_doi, doi_match, meta_found
# p2b_body_extract.R            | Extract Title/DOI/body, slim XML     | parse_ok, has_title, has_body, parse_error
# p2d_content_filter.R (STUB)   | TOC/errata/editorial removal         | content_flag (reserved)
# p2e_truncate.R       (STUB)   | Truncate to main text only           | truncated (reserved)
# p2c_length_filter.R           | Word-count screen                    | n_words, length_status
# p3_token_profile.R            | Token usage prediction               | n_tokens
# funnel_summary.R              | Funnel table + human-readable report | (reads finalized ledger)
#
# ==============================================================================

PRE_DIR <- here("scripts", "preprocess")

# ---- Load ledger helpers and initialise / resume the ledger ------------------
source(file.path(PRE_DIR, "audit_ledger.R"))

if (!dir.exists(OUTPUT_DIR)) dir.create(OUTPUT_DIR, recursive = TRUE)
run_started_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

ledger <- ledger_load(OUTPUT_DIR)   # empty if this is a fresh run, else resumes
cat(sprintf("\n[LEDGER] Starting with %d existing row(s).\n", nrow(ledger)))

# Helper: run a stage script then persist the ledger (crash-safe checkpoint).
run_stage <- function(label, script, active) {
  if (!isTRUE(active)) {
    cat(sprintf("\n========== %s [SKIPPED] ==========\n", label))
    return(invisible(NULL))
  }
  cat(sprintf("\n========== %s ==========\n", label))
  source(file.path(PRE_DIR, script), local = FALSE)
  ledger_save(ledger, OUTPUT_DIR)
  cat(sprintf("  [LEDGER] Saved — %d row(s).\n", nrow(ledger)))
}

# ==============================================================================
# RUN STAGES
# ==============================================================================

if (ingest_route != "extraction") {
  stop("ingest_route = '", ingest_route,
       "' is reserved for a future branch. Only 'extraction' is wired up.")
}

run_stage("STAGE 0: Seed Ledger (PDF corpus)",       "p0_seed_ledger.R",   run_seed_ledger)
run_stage("STAGE 1: PDF -> XML Reconciliation",      "p1_pdf_to_xml.R",    run_pdf_to_xml)
run_stage("STAGE 2a: DOI + Crossref Metadata",       "p2a_crossref.R",     run_crossref)
run_stage("STAGE 2b: Body Extraction",               "p2b_body_extract.R", run_body_extract)
run_stage("STAGE 2d: Content Filter (STUB)",         "p2d_content_filter.R", run_content_filter)
run_stage("STAGE 2e: Truncate to Main Text (STUB)",  "p2e_truncate.R",     run_truncate)
run_stage("STAGE 2c: Length Filter",                 "p2c_length_filter.R", run_length_filter)
run_stage("STAGE 3: Token Usage Prediction",         "p3_token_profile.R", run_token_profile)

# ==============================================================================
# FINALISE: rollup statuses, write funnel + summary
# ==============================================================================
cat("\n========== FINALISE: Audit Funnel & Summary ==========\n")
ledger <- ledger_finalize(ledger)
ledger_save(ledger, OUTPUT_DIR)
source(file.path(PRE_DIR, "funnel_summary.R"), local = FALSE)

cat("\n========================================\n")
cat("Pre-processing complete. Audit trail in:", OUTPUT_DIR, "\n")
cat("========================================\n")
