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
#    resulting XML; it does not run GROBID for you. Grobid is a bit of a pain, better on PC than Mac as it can run via CUDA. 
# 2. Set the USER CONFIGURATION below.
# 3. Source this entire script.
#
# FUTURE (next branch): an `ingest_route = "image"` path will send PDFs straight
# to a vision model instead of the extraction pipeline. The ledger schema and
# toggles are already shaped for it; only "extraction" is wired up today.
#
# AUTHOR: Dr Conal Monaghan (+ articLLMate Logging branch)
# ==============================================================================

# ---- Ensure every package the pre-processing pipeline needs is present -------
# Checked once here so no stage fails midway with a missing dependency. The
# token stage additionally needs a conda env with `tiktoken` (see env_name).
.required_pkgs <- c(
  "here", "tibble", "dplyr", "readr",   # infrastructure / ledger / summaries
  "xml2", "purrr",                       # XML parsing, iteration
  "rcrossref",                            # Crossref metadata (Stage 2a)
  "ellmer",                               # Claude API DOI resolver (Stage 2a2)
  "reticulate",                           # tiktoken bridge (Stage 3)
  "jsonlite"                              # run manifest
)
.missing <- .required_pkgs[!vapply(.required_pkgs, requireNamespace,
                                    logical(1), quietly = TRUE)]
if (length(.missing) > 0) {
  message("Installing missing packages: ", paste(.missing, collapse = ", "))
  install.packages(.missing)
}
invisible(lapply(.required_pkgs, library, character.only = TRUE))

# ==============================================================================
# USER CONFIGURATION - Edit these before each run
# ==============================================================================

project_name  <- "Ho_SPSP"          # Output subfolder under output/
source_batch  <- "SPSP"                    # Corpus label (e.g. "APA", "Sage"); also names the .rds objects
ingest_route  <- "extraction"              # "extraction" (wired) | "image" (reserved for a later branch)
env_name      <- "articLLMate"             # Conda env (used by the token stage)

# ---- Input / output paths ----
# Everything lives together under one numbered project folder. Each stage that
# runs writes its output into its own numbered folder whose number matches the
# script number (02a, 02b, ...), so "which folders exist" tells you what ran.
PROJECT_DIR <- here("input", project_name)
PDF_DIR    <- file.path(PROJECT_DIR, "00_PDFS")          # 00: ORIGINAL .pdf files (year subfolders OK); NA = start from XML
XML_DIR    <- file.path(PROJECT_DIR, "01_Article_Text")  # 01: GROBID .tei.xml output
OUTPUT_DIR <- PROJECT_DIR                                # Ledger, funnel, summary, manifest at the project root

# Per-stage output folders (created on demand) and the standard object filename.
STAGE_OBJECT <- "articles.rds"
STAGE_DIRS <- list(
  crossref = file.path(PROJECT_DIR, "02a_Crossref_Metadata"),  # p2a
  llm      = file.path(PROJECT_DIR, "02a2_LLM_Resolved"),      # p2a2 (Claude)
  body     = file.path(PROJECT_DIR, "02b_Body_Text"),          # p2b
  length   = file.path(PROJECT_DIR, "02c_Length_Screened"),    # p2c
  content  = file.path(PROJECT_DIR, "02d_Content_Filtered"),   # p2d (stub)
  truncate = file.path(PROJECT_DIR, "02e_Truncated"),          # p2e (stub)
  tokens   = file.path(PROJECT_DIR, "03_Token_Profiled")       # p3
)

# ---- Stage toggles: TRUE = run, FALSE = skip ----
run_seed_ledger    <- TRUE     # Stage 0:  seed ledger from PDF corpus (needs PDF_DIR)
run_pdf_to_xml     <- TRUE     # Stage 1:  reconcile PDFs vs GROBID XML
run_crossref       <- TRUE     # Stage 2a: DOI resolution + Crossref metadata
run_llm_resolver   <- TRUE     # Stage 2a2: Claude API mop-up for needs_review DOIs
run_body_extract   <- TRUE     # Stage 2b: extract Title/DOI/body, slim the XML
run_content_filter <- FALSE    # Stage 2d: TOC/errata/editorial removal (STUB — not implemented)
run_truncate       <- FALSE    # Stage 2e: truncate to main text only (STUB — not implemented)
run_length_filter  <- TRUE     # Stage 2c: word-count screen
run_token_profile  <- TRUE     # Stage 3:  token usage prediction

# ---- Levers ----
crossref_email     <- Sys.getenv("CROSSREF_EMAIL", unset = "your.email@example.com")
autosave_frequency <- 100        # Checkpoint the metadata .rds every N files (stage 2a)
llm_web_search     <- FALSE      # Stage 2a2: let Claude web-search for the last unresolved DOIs (costs tokens; opt-in)
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
source(file.path(PRE_DIR, "run_manifest.R"))

if (!dir.exists(OUTPUT_DIR)) dir.create(OUTPUT_DIR, recursive = TRUE)
run_started_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

ledger <- ledger_load(OUTPUT_DIR)   # empty if this is a fresh run, else resumes
cat(sprintf("\n[LEDGER] Starting with %d existing row(s).\n", nrow(ledger)))

# Pointer to the latest article object as it flows through the stage folders.
# Each producing stage reads this and updates it (the "baton"), so skipped stub
# stages never break the chain.
CURRENT_OBJECT <- NA_character_

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
run_stage("STAGE 2a2: LLM DOI Resolver (Claude)",    "p2a2_llm_resolver.R", run_llm_resolver)
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

# ---- Reproducibility manifest ------------------------------------------------
write_run_manifest(
  output_dir     = OUTPUT_DIR,
  xml_dir        = XML_DIR,
  ledger         = ledger,
  run_started_at = run_started_at,
  config = list(
    project_name = project_name,
    source_batch = source_batch,
    ingest_route = ingest_route,
    env_name     = env_name,
    PDF_DIR      = if (length(PDF_DIR) == 1 && is.na(PDF_DIR)) NA_character_ else PDF_DIR,
    XML_DIR      = XML_DIR,
    OUTPUT_DIR   = OUTPUT_DIR,
    stages = list(
      seed_ledger    = run_seed_ledger,
      pdf_to_xml     = run_pdf_to_xml,
      crossref       = run_crossref,
      body_extract   = run_body_extract,
      content_filter = run_content_filter,
      truncate       = run_truncate,
      length_filter  = run_length_filter,
      token_profile  = run_token_profile
    ),
    levers = list(
      crossref_email_set = nzchar(crossref_email),  # record only that one was set, not the address (PII)
      autosave_frequency = autosave_frequency,
      MIN_WORDS          = MIN_WORDS,
      MAX_WORDS          = MAX_WORDS,
      token_encoding     = token_encoding
    )
  )
)

cat("\n========================================\n")
cat("Pre-processing complete. Audit trail in:", OUTPUT_DIR, "\n")
cat("========================================\n")
