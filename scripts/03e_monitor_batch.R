# ==============================================================================
# STEP 03e: MONITOR BATCH JOBS & CHECK QUOTA CAPACITY
# ==============================================================================
# PURPOSE:  Check live status of all submitted batch chunks, report quota
#           usage and remaining capacity, and download completed results.
#           Run this at any time — it is fully non-blocking.
#
# REQUIRES:
#   - batch_manifest.rds (produced by 03c_build_batch_jsonl.R)
#   - One or more batch_job_meta_NNN.rds files (produced by 03d_submit_batch.R)
#   - API key set in .env (GEMINI_API_KEY or OPENAI_API_KEY)
#
# USAGE:
#   1. Set MANIFEST_DIR and rate limit constants below
#   2. Source this script (Ctrl+Shift+S) at any time
#
# OUTPUT:
#   - Console status report for all JSONL files
#   - Downloaded result JSONL files saved to {MANIFEST_DIR}/batch_output/
#   - Updated batch_job_meta_NNN.rds files with completion info
#
# SEE ALSO: 03d_submit_batch.R — submit a chunk
# ==============================================================================

library(here)
library(reticulate)


# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

# Directory containing batch_manifest.rds and batch_job_meta_NNN.rds files.
# This is the OUTPUT_DIR you used in 03c and 03d.
MANIFEST_DIR <- here("output", "Full_OpenAI_JSONL")

# Conda environment name
env_name <- "articLLMate"

# Download completed results automatically?
# TRUE  = download any newly completed jobs found during this run
# FALSE = status report only, no downloads
AUTO_DOWNLOAD <- FALSE

# ------------------------------------------------------------------------------
# Rate limits — update to match your current tier.
# Used to compute remaining capacity and go/no-go for next submission.
# ------------------------------------------------------------------------------

if (TRUE) {

  # OpenAI Tier 4 — gpt-4.1-mini
  # TPD: 1,000,000,000 | Max lines per file: 50,000 | File size limit: 200MB
  # Note: no published concurrent job limit for OpenAI batch
  OAI_MAX_FILE_SIZE  <- 180e6      # 90% of 200MB per-file hard limit
  OAI_MAX_LINES      <- 45000      # 90% of 50k lines-per-file hard limit
  OAI_MAX_TOKENS_TPD <- 900000000  # 90% of 1B TPD (resets midnight UTC)

  # Google Gemini Tier 2 — gemini-2.5-flash
  # Enqueued tokens (all active jobs combined): 400,000,000
  # Concurrent batch jobs: 100 | File size limit: 2GB
  # Note: no published per-file line limit for Gemini batch
  GEM_MAX_FILE_SIZE   <- 1.8e9     # 90% of 2GB per-file hard limit
  GEM_MAX_CONCURRENT  <- 90        # 90% of 100 simultaneous batch job submissions
  GEM_MAX_TOKENS_LIVE <- 360000000 # 90% of 400M enqueued tokens across ALL active jobs

}


# ==============================================================================
# LOAD MANIFEST
# ==============================================================================

manifest_path <- file.path(MANIFEST_DIR, "batch_manifest.rds")
if (!file.exists(manifest_path)) {
  stop("batch_manifest.rds not found in:\n  ", MANIFEST_DIR,
       "\nCheck MANIFEST_DIR above.")
}

manifest     <- readRDS(manifest_path)
api_provider <- manifest$api_provider
model_id     <- manifest$model_id
project_name <- manifest$project_name
chunk_paths  <- manifest$chunk_paths
token_ests   <- manifest$chunk_token_ests
n_chunks     <- manifest$n_chunks

chunk_sizes <- sapply(chunk_paths, function(p) {
  s <- file.info(p)$size
  if (is.na(s)) 0 else s
})


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

if (api_provider == "gemini") {
  if (nchar(Sys.getenv("GEMINI_API_KEY")) == 0) stop("GEMINI_API_KEY not set in .env")
} else {
  if (nchar(Sys.getenv("OPENAI_API_KEY")) == 0) stop("OPENAI_API_KEY not set in .env")
}


# ==============================================================================
# SET UP PYTHON CLIENT
# ==============================================================================

use_condaenv(env_name, required = TRUE)

if (api_provider == "gemini") {
  py_run_string("
import os
from google import genai
client = genai.Client(api_key=os.environ.get('GEMINI_API_KEY'))
")
} else {
  py_run_string("
from openai import OpenAI
client = OpenAI()
")
}


# ==============================================================================
# BUILD STATUS TABLE FROM MANIFEST + METADATA FILES
# ==============================================================================

# One row per JSONL file in the manifest
status_tbl <- data.frame(
  file         = basename(unlist(chunk_paths)),
  tokens       = token_ests,
  size_mb      = round(chunk_sizes / 1e6, 1),
  submitted    = FALSE,
  submitted_at = as.POSIXct(NA),
  live_status  = "NOT SUBMITTED",
  completed    = FALSE,
  downloaded   = FALSE,
  output_file  = NA_character_,
  job_ref      = NA_character_,  # job_id (OpenAI) or job_name (Gemini)
  chunk_num    = seq_len(n_chunks),
  stringsAsFactors = FALSE
)

# Load all metadata files found in MANIFEST_DIR
meta_files <- list.files(MANIFEST_DIR, pattern = "^batch_job_meta_\\d+\\.rds$",
                         full.names = TRUE)
meta_list <- list()

for (mf in meta_files) {
  meta <- readRDS(mf)
  i    <- meta$chunk_num
  if (i < 1 || i > n_chunks) next
  meta_list[[i]]              <- meta
  status_tbl$submitted[i]     <- TRUE
  status_tbl$submitted_at[i]  <- meta$submitted_at
  status_tbl$job_ref[i]       <- if (!is.null(meta$job_id)) meta$job_id else meta$job_name
  if (!is.null(meta$output_file) && file.exists(meta$output_file)) {
    status_tbl$downloaded[i]  <- TRUE
    status_tbl$completed[i]   <- TRUE
    status_tbl$live_status[i] <- "COMPLETED"
    status_tbl$output_file[i] <- meta$output_file
  }
}

batch_output_dir <- file.path(MANIFEST_DIR, "batch_output")
if (!dir.exists(batch_output_dir)) dir.create(batch_output_dir, recursive = TRUE)


# ==============================================================================
# QUERY LIVE STATUS — submitted but not yet downloaded
# ==============================================================================

pending_rows <- which(status_tbl$submitted & !status_tbl$downloaded)

if (length(pending_rows) > 0) {
  cat(sprintf("Querying live status for %d in-flight job(s)...\n\n",
              length(pending_rows)))

  for (i in pending_rows) {
    meta    <- meta_list[[i]]
    job_ref <- status_tbl$job_ref[i]

    # ---- Gemini ----
    if (api_provider == "gemini") {

      py_run_string(sprintf("
try:
    _job    = client.batches.get(name='%s')
    _status = _job.state.name
except Exception as e:
    _status = f'ERROR: {str(e)}'
", job_ref))
      live_status <- py$`_status`
      status_tbl$live_status[i] <- live_status
      status_tbl$completed[i]   <- live_status == "JOB_STATE_SUCCEEDED"

      if (live_status == "JOB_STATE_SUCCEEDED" && AUTO_DOWNLOAD) {
        out_path <- file.path(batch_output_dir,
                              sprintf("batch_output_%03d.jsonl", i))
        cat(sprintf("  %s complete — downloading...\n", status_tbl$file[i]))
        py_run_string(sprintf("
_result_bytes = client.files.download(file=_job.dest.file_name)
with open('%s', 'wb') as f:
    f.write(_result_bytes)
print('  Done.')
", out_path))
        meta$completed_at         <- Sys.time()
        meta$output_file          <- out_path
        saveRDS(meta, file.path(MANIFEST_DIR,
                                sprintf("batch_job_meta_%03d.rds", i)))
        status_tbl$downloaded[i]  <- TRUE
        status_tbl$output_file[i] <- out_path
      }

    # ---- OpenAI ----
    } else {

      py_run_string(sprintf("
try:
    _job            = client.batches.retrieve('%s')
    _status         = _job.status
    _output_file_id = getattr(_job, 'output_file_id', None)
except Exception as e:
    _status         = f'ERROR: {str(e)}'
    _output_file_id = None
", job_ref))
      live_status    <- py$`_status`
      output_file_id <- py$`_output_file_id`

      status_tbl$live_status[i] <- toupper(live_status)
      status_tbl$completed[i]   <- live_status == "completed"

      if (live_status == "completed" && AUTO_DOWNLOAD &&
          !is.null(output_file_id) && output_file_id != "None") {
        out_path <- file.path(batch_output_dir,
                              sprintf("batch_output_%03d.jsonl", i))
        cat(sprintf("  %s complete — downloading...\n", status_tbl$file[i]))
        py_run_string(sprintf("
_result_content = client.files.content('%s')
with open('%s', 'wb') as f:
    f.write(_result_content.content)
print('  Done.')
", output_file_id, out_path))
        meta$completed_at         <- Sys.time()
        meta$output_file          <- out_path
        saveRDS(meta, file.path(MANIFEST_DIR,
                                sprintf("batch_job_meta_%03d.rds", i)))
        status_tbl$downloaded[i]  <- TRUE
        status_tbl$output_file[i] <- out_path
      }
    }
  }
}


# ==============================================================================
# CAPACITY CALCULATION
# ==============================================================================

now_utc <- as.POSIXct(Sys.time(), tz = "UTC")

if (api_provider == "openai") {

  # TPD resets at midnight UTC — sum tokens from jobs submitted since then
  midnight_utc     <- as.POSIXct(format(now_utc, "%Y-%m-%d"), tz = "UTC")
  submitted_today  <- which(status_tbl$submitted &
                              !is.na(status_tbl$submitted_at) &
                              status_tbl$submitted_at >= midnight_utc)
  tokens_today     <- sum(status_tbl$tokens[submitted_today])
  tokens_remaining <- max(0, OAI_MAX_TOKENS_TPD - tokens_today)
  pct_used         <- round(100 * tokens_today / OAI_MAX_TOKENS_TPD, 1)
  next_reset_utc   <- midnight_utc + 86400

} else {

  # Gemini: enqueued token limit applies across ALL currently active jobs
  active_idx       <- which(status_tbl$submitted & !status_tbl$completed)
  active_jobs      <- length(active_idx)
  tokens_in_flight <- sum(status_tbl$tokens[active_idx])
  tokens_remaining <- max(0, GEM_MAX_TOKENS_LIVE - tokens_in_flight)
  jobs_remaining   <- max(0, GEM_MAX_CONCURRENT - active_jobs)

}

# Next unsubmitted file
next_row <- which(!status_tbl$submitted)[1]


# ==============================================================================
# REPORT
# ==============================================================================

cat("\n")
cat("==============================================================\n")
cat(sprintf(" BATCH STATUS REPORT — %s\n",
            format(Sys.time(), "%Y-%m-%d %H:%M %Z")))
cat(sprintf(" Project:  %s\n", project_name))
cat(sprintf(" Provider: %s  |  Model: %s\n", api_provider, model_id))
cat("==============================================================\n\n")

# Per-file status table
cat(sprintf(" %-35s %-13s %-9s %-20s %s\n",
            "File", "Est Tokens", "Size(MB)", "Status", "Downloaded"))
cat(paste(rep("-", 88), collapse = ""), "\n")

for (i in seq_len(n_chunks)) {
  dl_label <- if (status_tbl$downloaded[i])  "YES"   else
              if (status_tbl$completed[i])    "READY" else "-"
  cat(sprintf("  %-33s %-13s %-9.1f %-20s %s\n",
              status_tbl$file[i],
              format(status_tbl$tokens[i], big.mark = ",", scientific = FALSE),
              status_tbl$size_mb[i],
              status_tbl$live_status[i],
              dl_label))
}

cat(paste(rep("-", 88), collapse = ""), "\n\n")

# Summary counts
cat(sprintf("  Completed:   %d / %d files\n", sum(status_tbl$completed), n_chunks))
cat(sprintf("  In-flight:   %d file(s)\n",    sum(status_tbl$submitted & !status_tbl$completed)))
cat(sprintf("  Pending:     %d file(s)\n",    sum(!status_tbl$submitted)))
cat(sprintf("  Downloaded:  %d file(s)\n\n",  sum(status_tbl$downloaded)))

# Capacity
cat("--------------------------------------------------------------\n")
cat(" QUOTA / CAPACITY\n")
cat("--------------------------------------------------------------\n")

if (api_provider == "openai") {
  cat(sprintf("  Daily token limit (90%% ceiling):  %s\n",
              format(OAI_MAX_TOKENS_TPD, big.mark = ",")))
  cat(sprintf("  Tokens submitted today (UTC):     %s  (%.1f%%)\n",
              format(tokens_today, big.mark = ","), pct_used))
  cat(sprintf("  Remaining today:                  %s tokens\n",
              format(tokens_remaining, big.mark = ",")))
  cat(sprintf("  Quota resets at:                  %s UTC\n\n",
              format(next_reset_utc, "%Y-%m-%d 00:00")))
} else {
  cat(sprintf("  Enqueued token limit (90%% ceiling):  %s\n",
              format(GEM_MAX_TOKENS_LIVE, big.mark = ",")))
  cat(sprintf("  Tokens currently in-flight:          %s\n",
              format(tokens_in_flight, big.mark = ",")))
  cat(sprintf("  Remaining enqueue capacity:          %s tokens\n",
              format(tokens_remaining, big.mark = ",")))
  cat(sprintf("  Concurrent job limit (90%% ceiling):  %d\n", GEM_MAX_CONCURRENT))
  cat(sprintf("  Active jobs:                         %d\n", active_jobs))
  cat(sprintf("  Remaining job slots:                 %d\n\n", jobs_remaining))
}

# Go / No-go
cat("--------------------------------------------------------------\n")
cat(" NEXT SUBMISSION\n")
cat("--------------------------------------------------------------\n")

if (is.na(next_row)) {
  cat("  All files submitted. Nothing pending.\n")
} else {
  next_tokens <- status_tbl$tokens[next_row]
  next_file   <- status_tbl$file[next_row]
  next_size   <- status_tbl$size_mb[next_row]

  cat(sprintf("  Next file:  %s  (%s tokens, %.1f MB)\n",
              next_file,
              format(next_tokens, big.mark = ","),
              next_size))

  if (api_provider == "openai") {
    can_submit <- tokens_remaining >= next_tokens
  } else {
    can_submit <- tokens_remaining >= next_tokens && jobs_remaining > 0
  }

  if (can_submit) {
    cat("  Status:     READY TO SUBMIT\n")
    cat(sprintf("  Action:     Set JSONL_FILE to %s in 03d_submit_batch.R\n", next_file))
  } else {
    cat("  Status:     NOT READY — insufficient quota\n")
    if (api_provider == "openai") {
      cat(sprintf("  Deficit:    %s tokens over today's remaining budget\n",
                  format(next_tokens - tokens_remaining, big.mark = ",")))
      cat(sprintf("  Retry after: %s UTC\n",
                  format(next_reset_utc, "%Y-%m-%d 00:00")))
    } else {
      if (jobs_remaining <= 0) {
        cat("  Reason:     Concurrent job limit reached — wait for a job to complete\n")
      }
      if (tokens_remaining < next_tokens) {
        cat(sprintf("  Reason:     Enqueued token deficit of %s — wait for a job to complete\n",
                    format(next_tokens - tokens_remaining, big.mark = ",")))
      }
    }
  }
}

cat("==============================================================\n\n")