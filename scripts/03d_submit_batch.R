# ==============================================================================
# STEP 03d: SUBMIT A SINGLE BATCH CHUNK
# ==============================================================================
# PURPOSE:  Upload one JSONL file to the batch API (OpenAI or Gemini) and
#           save job metadata for tracking. Does NOT poll or block — once the
#           job is submitted this script exits immediately.
#
#           Use 03e_monitor_batch.R to check status and download results.
#
# REQUIRES:
#   - A JSONL file produced by 03c_build_batch_jsonl.R
#   - API key set in .env (GEMINI_API_KEY or OPENAI_API_KEY)
#
# USAGE:
#   1. Set the USER CONFIGURATION block below
#   2. Source this script (Ctrl+Shift+S)
#
# OUTPUT:
#   - {OUTPUT_DIR}/batch_job_meta_NNN.rds  (job tracking metadata)
#   - {OUTPUT_DIR}/batch_output/           (created if it does not exist)
#
# SEE ALSO: 03e_monitor_batch.R — check status, capacity, and download results
# ==============================================================================

library(here)
library(reticulate)


# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

# Path to the JSONL chunk you want to submit
JSONL_FILE <- here("output", "Test_OpenAI_JSONL_batch", "batch_input", "batch_input_001.jsonl")

# Directory where job metadata (.rds) will be saved.
# Use the same folder as your other scripts so 03e_monitor_batch.R can find it.
OUTPUT_DIR <- here("output", "Test_OpenAI_JSONL_batch")

# API provider and model
api_provider <- "openai"        # "openai" or "gemini"
model_id     <- "gpt-5-mini"  # e.g. "gpt-5-mini" [cheaper than 5.4], "gemini-2.5-flash"

# Conda environment name
env_name <- "articLLMate"


# ==============================================================================
# SETUP & VALIDATION
# ==============================================================================

if (!file.exists(JSONL_FILE)) {
  stop("JSONL file not found:\n  ", JSONL_FILE)
}

if (!api_provider %in% c("openai", "gemini")) {
  stop("api_provider must be 'openai' or 'gemini'. Got: '", api_provider, "'")
}

# Create output directories if they do not exist
if (!dir.exists(OUTPUT_DIR)) {
  dir.create(OUTPUT_DIR, recursive = TRUE)
  cat(sprintf("Created OUTPUT_DIR: %s\n", OUTPUT_DIR))
}

batch_output_dir <- file.path(OUTPUT_DIR, "batch_output")
if (!dir.exists(batch_output_dir)) {
  dir.create(batch_output_dir, recursive = TRUE)
  cat(sprintf("Created batch_output dir: %s\n", batch_output_dir))
}

# Derive chunk number from filename (e.g. batch_input_003.jsonl -> 3)
chunk_num <- as.integer(sub(".*_(\\d+)\\.jsonl$", "\\1", basename(JSONL_FILE)))
if (is.na(chunk_num)) chunk_num <- 1L

# Guard against duplicate submission
meta_path <- file.path(OUTPUT_DIR, sprintf("batch_job_meta_%03d.rds", chunk_num))
if (file.exists(meta_path)) {
  existing <- readRDS(meta_path)
  cat(sprintf("[WARNING] This file appears to have been submitted already.\n"))
  cat(sprintf("  File:         %s\n", basename(JSONL_FILE)))
  cat(sprintf("  Submitted at: %s\n", existing$submitted_at))
  if (!is.null(existing$job_id))   cat(sprintf("  Job ID:       %s\n", existing$job_id))
  if (!is.null(existing$job_name)) cat(sprintf("  Job name:     %s\n", existing$job_name))
  cat("  To resubmit, delete the .rds file and re-run.\n\n")
  stop("Aborting to prevent duplicate submission.")
}

chunk_size <- file.info(JSONL_FILE)$size

cat("==============================================================\n")
cat(" Submitting batch chunk\n")
cat(sprintf("  Provider:  %s\n", api_provider))
cat(sprintf("  Model:     %s\n", model_id))
cat(sprintf("  File:      %s\n", basename(JSONL_FILE)))
cat(sprintf("  File size: %.1f MB\n", chunk_size / 1e6))
cat("==============================================================\n\n")


# ==============================================================================
# LOAD .env
# ==============================================================================

dotenv_path <- here(".env")
if (file.exists(dotenv_path)) {
  env_lines <- readLines(dotenv_path, warn = FALSE)
  for (line in env_lines) {
    line <- trimws(line)
    if (nchar(line) == 0 || startsWith(line, "#")) next
    parts <- strsplit(line, "=", fixed = TRUE)[[1]]
    if (length(parts) >= 2) {
      do.call(Sys.setenv, setNames(
        list(paste(parts[-1], collapse = "=")),
        trimws(parts[1])
      ))
    }
  }
}

use_condaenv(env_name, required = TRUE)


# ==============================================================================
# SUBMIT — GEMINI
# ==============================================================================

if (api_provider == "gemini") {

  if (nchar(Sys.getenv("GEMINI_API_KEY")) == 0) stop("GEMINI_API_KEY not set in .env")

  py_run_string("
import os
from google import genai
from google.genai import types
client = genai.Client(api_key=os.environ.get('GEMINI_API_KEY'))
")

  cat("Uploading JSONL file to Gemini Files API...\n")
  py_run_string(sprintf("
_uploaded_file = client.files.upload(
    file='%s',
    config=types.UploadFileConfig(
        display_name='batch-chunk-%03d',
        mime_type='application/jsonl'
    )
)
print(f'  Uploaded: {_uploaded_file.name}')
", JSONL_FILE, chunk_num))

  cat("Submitting batch job...\n")
  py_run_string(sprintf("
_batch_job = client.batches.create(
    model='%s',
    src=_uploaded_file.name,
    config={'display_name': 'batch-chunk-%03d'}
)
_job_name  = _batch_job.name
_job_state = _batch_job.state.name
print(f'  Job name: {_job_name}')
print(f'  State:    {_job_state}')
", model_id, chunk_num))

  job_meta <- list(
    job_name     = py$`_job_name`,
    job_id       = NULL,
    chunk_file   = JSONL_FILE,
    chunk_num    = chunk_num,
    api_provider = api_provider,
    model_id     = model_id,
    submitted_at = Sys.time(),
    completed_at = NULL,
    output_file  = NULL
  )


# ==============================================================================
# SUBMIT — OPENAI
# ==============================================================================

} else if (api_provider == "openai") {

  if (nchar(Sys.getenv("OPENAI_API_KEY")) == 0) stop("OPENAI_API_KEY not set in .env")

  py_run_string("
from openai import OpenAI
client = OpenAI()
")

  cat("Uploading JSONL file to OpenAI Files API...\n")
  py_run_string(sprintf("
_uploaded_file = client.files.create(
    file=open('%s', 'rb'),
    purpose='batch'
)
print(f'  File ID: {_uploaded_file.id}')
", JSONL_FILE))

  cat("Submitting batch job...\n")
  py_run_string("
_batch_job = client.batches.create(
    input_file_id=_uploaded_file.id,
    endpoint='/v1/chat/completions',
    completion_window='24h'
)
_job_id     = _batch_job.id
_job_status = _batch_job.status
print(f'  Batch ID: {_job_id}')
print(f'  Status:   {_job_status}')
")

  job_meta <- list(
    job_name     = NULL,
    job_id       = py$`_job_id`,
    chunk_file   = JSONL_FILE,
    chunk_num    = chunk_num,
    api_provider = api_provider,
    model_id     = model_id,
    submitted_at = Sys.time(),
    completed_at = NULL,
    output_file  = NULL
  )
}


# ==============================================================================
# SAVE METADATA AND EXIT
# ==============================================================================

saveRDS(job_meta, meta_path)

cat(sprintf("\nMetadata saved: %s\n", basename(meta_path)))
cat("\n==============================================================\n")
cat(" Submitted. Script complete.\n")
cat(" Run 03e_monitor_batch.R to check status and download results.\n")
cat("==============================================================\n")