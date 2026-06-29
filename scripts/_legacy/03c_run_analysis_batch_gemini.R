# ==============================================================================
# STEP 3c: GEMINI BATCH ANALYSIS
# ==============================================================================
# PURPOSE:  Instead of calling the Gemini API one article at a time, this script:
#           1) Builds a JSONL file with all requests
#           2) Uploads it via the google-genai SDK
#           3) Submits a batch job (50% cheaper, 24-hour SLO)
#           4) Polls until completion
#           5) Downloads and parses results into the same results_list format
#              used by 03a so that Steps 4-6 work identically.
#
# EXPECTS FROM MASTER:
#   input_type = "xml" → xml_files, n_articles
#   input_type = "rds" → article_keys, articles_data, n_articles
#   Always: prompt_text, model_id, api_provider, OUTPUT_DIR, project_name, save_interval
#
# CREATES: results_list, files_analysed, errors_log, timings, total_elapsed_secs
#
# BATCH API LIMITS (Gemini):
#   - Max input file size: 2GB per JSONL file
#   - 24-hour processing SLO (asynchronous)
#   - Uses google-genai SDK (NOT google-generativeai)
#   - Each JSONL line is a self-contained GenerateContentRequest
#
# NOTE ON system_instruction:
#   There is a known issue (googleapis/python-genai#1190) where system_instruction
#   may not work in batch requests. We use two strategies:
#   1. Try systemInstruction in the JSONL (camelCase REST field name)
#   2. If that doesn't work, users can set BATCH_SYSTEM_PROMPT_INLINE=TRUE to
#      prepend the system prompt into the user message instead.
# ==============================================================================

cat(sprintf("Preparing Gemini batch for %d articles using %s...\n\n", n_articles, model_id))


# ==============================================================================
# CONFIGURATION — Batch control parameters
# ==============================================================================

# Maximum JSONL file size in bytes (1.5GB safety margin under 2GB API limit)
BATCH_MAX_FILE_SIZE   <- 1.5e9

# Maximum number of requests per batch job (conservative limit)
# Gemini docs don't specify a hard cap, but splitting very large batches
# improves reliability and allows partial recovery on failure.
BATCH_MAX_REQUESTS    <- 30000

# How often to poll the batch job status (in seconds)
BATCH_POLL_INTERVAL   <- 60

# Whether to inline the system prompt in the user message (workaround for
# system_instruction bug). Set to TRUE if batch results are missing system context.
BATCH_SYSTEM_PROMPT_INLINE <- FALSE


# ==============================================================================
# PHASE 1: Build article list and extract text
# ==============================================================================

cat("Phase 1: Extracting article text...\n")

article_texts  <- vector("list", n_articles)
article_ids    <- character(n_articles)
read_errors    <- logical(n_articles)

for (i in seq_len(n_articles)) {

  if (input_type == "xml") {
    file_path     <- xml_files[i]
    article_ids[i] <- basename(file_path)

    text_content <- tryCatch({
      readChar(file_path, file.info(file_path)$size)
    }, error = function(e) { NA })

  } else if (input_type == "rds") {
    key            <- article_keys[i]
    article_ids[i] <- key
    article        <- articles_data[[key]]

    title_text <- if (!is.null(article$XML$Title) && !is.na(article$XML$Title)) article$XML$Title else ""
    body_text  <- if (!is.null(article$XML$Text) && !is.na(article$XML$Text)) article$XML$Text else NA

    if (!is.na(body_text) && nchar(body_text) > 0) {
      text_content <- paste0(title_text, "\n\n", body_text)
    } else {
      text_content <- NA
    }
  }

  if (!is.na(text_content) && nchar(text_content) > 0) {
    article_texts[[i]] <- text_content
    read_errors[i]     <- FALSE
  } else {
    article_texts[[i]] <- NA
    read_errors[i]     <- TRUE
  }
}

n_valid <- sum(!read_errors)
n_errors <- sum(read_errors)
cat(sprintf("  [OK] %d articles ready, %d read errors.\n", n_valid, n_errors))


# ==============================================================================
# PHASE 2: Build JSONL file(s)
# ==============================================================================

cat("\nPhase 2: Building JSONL batch file(s)...\n")

# Build the user message template
user_msg_prefix <- "Analyze this academic paper and return your response as JSON:\n\n"

# Decide whether to put system prompt in systemInstruction or inline it
if (BATCH_SYSTEM_PROMPT_INLINE) {
  system_instruction_json <- "null"
  user_msg_full_prefix <- paste0(prompt_text, "\n\n---\n\n", user_msg_prefix)
  cat("  [NOTE] System prompt will be inlined in user message (workaround mode).\n")
} else {
  user_msg_full_prefix <- user_msg_prefix
}

# Create JSONL in OUTPUT_DIR
jsonl_dir <- file.path(OUTPUT_DIR, "batch_input")
if (!dir.exists(jsonl_dir)) dir.create(jsonl_dir, recursive = TRUE)

# Track which articles go into which chunk
chunk_index     <- 1
chunk_line_count <- 0
chunk_file_size  <- 0
chunk_path       <- file.path(jsonl_dir, sprintf("batch_input_%03d.jsonl", chunk_index))
chunk_con        <- file(chunk_path, open = "w")
chunk_paths      <- chunk_path
article_chunk_map <- integer(n_articles)  # which chunk each article is in

for (i in seq_len(n_articles)) {

  if (read_errors[i]) next

  # Build the request JSON for this article
  user_content <- paste0(user_msg_full_prefix, article_texts[[i]])

  # Build the request object
  request_obj <- list(
    key = article_ids[i],
    request = list(
      contents = list(list(
        parts = list(list(text = user_content))
      )),
      generationConfig = list(
        responseMimeType = "application/json",
        temperature = 0.1
      )
    )
  )

  # Add systemInstruction unless we're inlining it
  if (!BATCH_SYSTEM_PROMPT_INLINE) {
    request_obj$request$systemInstruction <- list(
      parts = list(list(text = prompt_text))
    )
  }

  # Convert to single-line JSON
  json_line <- toJSON(request_obj, auto_unbox = TRUE)

  # Check if adding this line would exceed chunk limits
  line_bytes <- nchar(json_line, type = "bytes") + 1  # +1 for newline
  if (chunk_line_count > 0 &&
      (chunk_file_size + line_bytes > BATCH_MAX_FILE_SIZE ||
       chunk_line_count >= BATCH_MAX_REQUESTS)) {
    # Close current chunk, start a new one
    close(chunk_con)
    cat(sprintf("  Chunk %d: %d requests, %.1f MB\n",
                chunk_index, chunk_line_count, chunk_file_size / 1e6))

    chunk_index     <- chunk_index + 1
    chunk_line_count <- 0
    chunk_file_size  <- 0
    chunk_path       <- file.path(jsonl_dir, sprintf("batch_input_%03d.jsonl", chunk_index))
    chunk_con        <- file(chunk_path, open = "w")
    chunk_paths      <- c(chunk_paths, chunk_path)
  }

  writeLines(json_line, chunk_con)
  chunk_line_count <- chunk_line_count + 1
  chunk_file_size  <- chunk_file_size + line_bytes
  article_chunk_map[i] <- chunk_index
}

close(chunk_con)
cat(sprintf("  Chunk %d: %d requests, %.1f MB\n",
            chunk_index, chunk_line_count, chunk_file_size / 1e6))

n_chunks <- length(chunk_paths)
cat(sprintf("\n  [OK] %d JSONL file(s) created in %s\n", n_chunks, jsonl_dir))


# ==============================================================================
# PHASE 3: Upload, submit, and poll via Python
# ==============================================================================

cat("\nPhase 3: Uploading and submitting batch job(s) to Gemini...\n")

# Set up the Python batch client
py_run_string("
import json
import time
import os
from google import genai
from google.genai import types

client = genai.Client(api_key=os.environ.get('GEMINI_API_KEY'))
")

tic("Total Batch Processing")

# Store job names for each chunk
batch_job_names   <- character(n_chunks)
batch_job_results <- vector("list", n_chunks)

for (chunk_idx in seq_len(n_chunks)) {

  chunk_file <- chunk_paths[chunk_idx]
  cat(sprintf("\n  --- Chunk %d of %d ---\n", chunk_idx, n_chunks))

  # Upload the JSONL file
  cat("  Uploading JSONL file...\n")
  py_run_string(sprintf("
_uploaded_file = client.files.upload(
    file='%s',
    config=types.UploadFileConfig(
        display_name='%s-batch-%03d',
        mime_type='jsonl'
    )
)
print(f'  Uploaded: {_uploaded_file.name}')
", chunk_file, project_name, chunk_idx))

  # Create batch job
  cat("  Submitting batch job...\n")
  py_run_string(sprintf("
_batch_job = client.batches.create(
    model='%s',
    src=_uploaded_file.name,
    config={'display_name': '%s-batch-%03d'}
)
_job_name = _batch_job.name
print(f'  Job created: {_job_name}')
print(f'  State: {_batch_job.state.name}')
", model_id, project_name, chunk_idx))

  # Save job name for resume capability
  job_name <- py$`_job_name`
  batch_job_names[chunk_idx] <- job_name

  # Save job metadata to disk (for resume if R session dies)
  job_meta <- list(
    job_name     = job_name,
    chunk_file   = chunk_file,
    chunk_index  = chunk_idx,
    n_chunks     = n_chunks,
    model_id     = model_id,
    project_name = project_name,
    submitted_at = Sys.time()
  )
  saveRDS(job_meta, file.path(OUTPUT_DIR, sprintf("batch_job_meta_%03d.rds", chunk_idx)))

  # Poll for completion
  cat(sprintf("  Polling for completion (checking every %d seconds)...\n", BATCH_POLL_INTERVAL))
  poll_start <- Sys.time()

  py_run_string(sprintf("
import time

_poll_interval = %d
_job_name = '%s'
_poll_count = 0

while True:
    _batch_job = client.batches.get(name=_job_name)
    _state = _batch_job.state.name
    _poll_count += 1

    if _state in ('JOB_STATE_SUCCEEDED', 'JOB_STATE_FAILED', 'JOB_STATE_CANCELLED'):
        break

    # Print status every poll
    elapsed_min = (_poll_count * _poll_interval) / 60
    print(f'    [{elapsed_min:.0f} min] Status: {_state}')

    time.sleep(_poll_interval)

print(f'  Final state: {_state}')
_batch_state = _state
", BATCH_POLL_INTERVAL, job_name))

  batch_state <- py$`_batch_state`
  poll_elapsed <- as.numeric(difftime(Sys.time(), poll_start, units = "mins"))
  cat(sprintf("  Batch %d finished in %.1f minutes. State: %s\n", chunk_idx, poll_elapsed, batch_state))

  if (batch_state == "JOB_STATE_FAILED") {
    cat("  [ERROR] Batch job failed. Check Google Cloud console for details.\n")
    # Try to get error info
    py_run_string("
try:
    _error_info = str(_batch_job)
    print(f'  Error details: {_error_info}')
except:
    print('  Could not retrieve error details.')
")
    batch_job_results[[chunk_idx]] <- list()
    next
  }

  if (batch_state == "JOB_STATE_CANCELLED") {
    cat("  [WARN] Batch job was cancelled.\n")
    batch_job_results[[chunk_idx]] <- list()
    next
  }

  # Download results
  cat("  Downloading results...\n")
  results_output_path <- file.path(OUTPUT_DIR, sprintf("batch_output_%03d.jsonl", chunk_idx))

  py_run_string(sprintf("
_result_bytes = client.files.download(file=_batch_job.dest.file_name)

# Write raw bytes to file
with open('%s', 'wb') as f:
    f.write(_result_bytes)

print(f'  Results saved to: %s')
", results_output_path, results_output_path))

  cat(sprintf("  [OK] Results downloaded to %s\n", results_output_path))

  # Parse the results JSONL
  result_lines <- readLines(results_output_path, warn = FALSE)
  chunk_results <- list()

  for (line in result_lines) {
    if (nchar(trimws(line)) == 0) next

    parsed <- tryCatch({
      fromJSON(line, simplifyDataFrame = FALSE)
    }, error = function(e) {
      cat(sprintf("  [WARN] Could not parse result line: %s\n", e$message))
      NULL
    })

    if (!is.null(parsed) && !is.null(parsed$key)) {
      chunk_results[[parsed$key]] <- parsed
    }
  }

  batch_job_results[[chunk_idx]] <- chunk_results
  cat(sprintf("  [OK] Parsed %d results from chunk %d.\n", length(chunk_results), chunk_idx))
}

total_elapsed <- toc(quiet = TRUE)
total_elapsed_secs <- total_elapsed$toc - total_elapsed$tic


# ==============================================================================
# PHASE 4: Build results_list (same format as 03a)
# ==============================================================================

cat("\nPhase 4: Building results list...\n")

# Flatten all chunk results into one lookup
all_batch_results <- list()
for (chunk_idx in seq_len(n_chunks)) {
  for (key in names(batch_job_results[[chunk_idx]])) {
    all_batch_results[[key]] <- batch_job_results[[chunk_idx]][[key]]
  }
}

results_list   <- vector("list", n_articles)
files_analysed <- character(n_articles)
errors_log     <- list()
timings        <- rep(NA_real_, n_articles)

for (i in seq_len(n_articles)) {

  article_id      <- article_ids[i]
  files_analysed[i] <- article_id

  if (read_errors[i]) {
    # Article couldn't be read
    results_list[[i]] <- list(filename = article_id, status = "READ_ERROR")
    errors_log[[length(errors_log) + 1]] <- list(
      file  = article_id,
      error = "Could not read article or text is empty",
      index = i
    )
    next
  }

  batch_result <- all_batch_results[[article_id]]

  if (is.null(batch_result)) {
    # Article was submitted but no result returned
    results_list[[i]] <- list(filename = article_id, status = "API_ERROR")
    errors_log[[length(errors_log) + 1]] <- list(
      file  = article_id,
      error = "No result returned from batch API",
      index = i
    )
    next
  }

  # Extract the actual LLM response text from the batch result
  api_result <- tryCatch({
    # Navigate: response → candidates[1] → content → parts[1] → text
    response_text <- batch_result$response$candidates[[1]]$content$parts[[1]]$text
    fromJSON(response_text, simplifyDataFrame = FALSE)
  }, error = function(e) {
    list(error = paste("Result parse error:", e$message))
  })

  # Determine status (same logic as 03a)
  if (!is.null(api_result$error)) {
    status <- "API_ERROR"
    cat(sprintf("  [ERROR] %s: %s\n", article_id, api_result$error))
    errors_log[[length(errors_log) + 1]] <- list(
      file  = article_id,
      error = api_result$error,
      index = i
    )
  } else if (isFALSE(api_result$relevance_check$examines_psychopathology) ||
             isFALSE(api_result$relevance_check$is_relevant)) {
    status <- "SKIPPED_IRRELEVANT"
  } else {
    status <- "PROCESSED"
  }

  api_result$filename <- article_id
  api_result$status   <- status
  results_list[[i]]   <- api_result

  # Save individual JSON (for consistency with 03a output)
  json_out_name <- paste0(gsub("[/\\\\:*?\"<>|]", "_", sub("\\.xml$", "", article_id)), ".json")
  tryCatch({
    write_json(api_result, file.path(OUTPUT_DIR, json_out_name),
               auto_unbox = TRUE, pretty = TRUE)
  }, error = function(e) {
    cat(sprintf("  [WARN] Could not save JSON for %s: %s\n", article_id, e$message))
  })
}

# Count statuses
status_counts <- table(sapply(results_list, function(x) x$status %||% "UNKNOWN"))
cat("\n  Status summary:\n")
for (s in names(status_counts)) {
  cat(sprintf("    %-20s %d\n", s, status_counts[s]))
}


# ==============================================================================
# PHASE 5: Save final RDS
# ==============================================================================

cat("\nPhase 5: Saving final results...\n")

project_results <- setNames(results_list, files_analysed)
rds_path <- file.path(OUTPUT_DIR, paste0(project_name, "_results.rds"))
saveRDS(project_results, rds_path)
cat(sprintf("  [OK] Results saved: %s\n", rds_path))

cat(sprintf("\nBatch analysis complete. %d articles processed in %.1f minutes.\n",
            n_articles, total_elapsed_secs / 60))
cat(sprintf("  JSONL input:  %s\n", jsonl_dir))
cat(sprintf("  Results:      %s\n", rds_path))
if (length(errors_log) > 0) {
  cat(sprintf("  Errors:       %d (see errors_log for details)\n", length(errors_log)))
}
