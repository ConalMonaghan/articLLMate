# ==============================================================================
# STEP 3e: PARSE BATCH RESULTS INTO STANDARD RDS FORMAT
# ==============================================================================
# PURPOSE:  Read all batch output JSONL files from {OUTPUT_DIR}/batch_output/,
#           parse the LLM responses, and build the same results_list + RDS that
#           03a produces — so Steps 4-6 (summary, post-processing, results
#           object) work identically.
#
#           Run this ONCE after ALL batch chunks have been submitted and
#           downloaded via 03d_submit_batch.R.
#
# REQUIRES:
#   - batch_manifest.rds in OUTPUT_DIR (created by 03c)
#   - batch_output_NNN.jsonl files in {OUTPUT_DIR}/batch_output/ (created by 03d)
#
# USAGE:
#   OUTPUT_DIR <- here("output", "my_project")
#   source("scripts/03e_parse_batch_results.R")
#
# CREATES:
#   results_list       — named list (same format as 03a)
#   files_analysed     — character vector of article IDs
#   errors_log         — list of error records
#   timings            — numeric vector (NA for batch, since timing is per-job)
#   total_elapsed_secs — NA (not meaningful for multi-session batch)
#   Individual .json files per article in OUTPUT_DIR
#   {project_name}_results.rds
#
# SEE ALSO: docs/batch_guide.md for the full walkthrough.
# ==============================================================================

library(here)
library(jsonlite)

# Null-coalescing operator (base R doesn't provide this)
`%||%` <- function(a, b) if (!is.null(a)) a else b

# ---- Standalone helpers (mirror of _MASTER_RUN_PIPELINE.R) ----
# These are only defined here if the master hasn't already defined them,
# so this script works both standalone and when sourced from the pipeline.

if (!exists("resolve_field")) {
  resolve_field <- function(obj, path) {
    parts <- strsplit(path, ".", fixed = TRUE)[[1]]
    current <- obj
    for (p in parts) {
      if (!is.list(current) || is.null(current[[p]])) return(NULL)
      current <- current[[p]]
    }
    current
  }
}

if (!exists("determine_status")) {
  determine_status <- function(api_result, skip_fields) {
    tryCatch({
      if (!is.null(api_result$error)) return("API_ERROR")
      if (is.list(api_result) && length(skip_fields) > 0) {
        for (field_path in skip_fields) {
          val <- resolve_field(api_result, field_path)
          if (isFALSE(val)) return("SKIPPED_IRRELEVANT")
        }
      }
      "PROCESSED"
    }, error = function(e) "PROCESSED")
  }
}


# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

OUTPUT_DIR <- here("output", "Test_OpenAI_JSONL_batch")


# ==============================================================================
# VALIDATION
# ==============================================================================

if (!exists("OUTPUT_DIR") || !dir.exists(OUTPUT_DIR)) {
  stop("Set OUTPUT_DIR to the project output folder before sourcing this script.\n",
       "  Example: OUTPUT_DIR <- here('output', 'my_project')")
}

manifest_path <- file.path(OUTPUT_DIR, "batch_manifest.rds")
if (!file.exists(manifest_path)) {
  stop("batch_manifest.rds not found in OUTPUT_DIR. Run 03c_build_batch_jsonl.R first.")
}

manifest     <- readRDS(manifest_path)
api_provider <- manifest$api_provider
project_name <- manifest$project_name
article_ids  <- manifest$article_ids
read_errors  <- manifest$read_errors
n_articles   <- manifest$n_articles
skip_if_false <- manifest$skip_if_false %||% character(0)

cat(sprintf("Parsing batch results for project '%s' (%s)...\n", project_name, api_provider))
cat(sprintf("  %d articles in manifest, %d with read errors.\n\n", n_articles, sum(read_errors)))


# ==============================================================================
# PHASE 1: Load all batch output JSONL files
# ==============================================================================

cat("Phase 1: Loading batch output files...\n")

batch_output_dir <- file.path(OUTPUT_DIR, "batch_output")
output_files <- sort(list.files(batch_output_dir, pattern = "^batch_output_.*\\.jsonl$",
                                full.names = TRUE))

if (length(output_files) == 0) {
  stop("No batch_output_*.jsonl files found in ", batch_output_dir,
       "\n  Have you run 03d_submit_batch.R for all chunks?")
}

cat(sprintf("  Found %d output file(s).\n", length(output_files)))

# Parse all results into a single lookup by article ID
all_batch_results <- list()

for (output_file in output_files) {
  cat(sprintf("  Parsing: %s\n", basename(output_file)))
  result_lines <- readLines(output_file, warn = FALSE)
  n_parsed <- 0

  for (line in result_lines) {
    if (nchar(trimws(line)) == 0) next # Lets just skip all failed rows

    parsed <- tryCatch({
      fromJSON(line, simplifyDataFrame = FALSE)
    }, error = function(e) {
      cat(sprintf("    [WARN] Could not parse line: %s\n", e$message))
      NULL
    })

    if (is.null(parsed)) next

    # Extract the key/ID depending on provider format
    if (api_provider == "gemini") {
      result_key <- parsed$key
    } else if (api_provider == "openai") {
      result_key <- parsed$custom_id
    } else {
      result_key <- if (!is.null(parsed$key)) parsed$key else parsed$custom_id
    }

    if (!is.null(result_key)) {
      all_batch_results[[result_key]] <- parsed
      n_parsed <- n_parsed + 1
    }
  }
  cat(sprintf("    %d results parsed.\n", n_parsed))
}

cat(sprintf("\n  Total results: %d (expected: %d)\n",
            length(all_batch_results), sum(!read_errors)))

# Warn about missing results
n_missing <- sum(!read_errors) - length(all_batch_results)
if (n_missing > 0) {
  cat(sprintf("  [WARN] %d articles have no batch result. They may have failed or the chunk hasn't been submitted yet.\n", n_missing))
}


# ==============================================================================
# PHASE 2: Extract LLM response text from provider-specific format
# ==============================================================================

cat("\nPhase 2: Building results list...\n")

# Helper: extract the LLM's text response from a batch result
extract_response_text <- function(batch_result, provider) {
  if (provider == "gemini") {
    # Gemini: response → candidates[1] → content → parts[1] → text
    batch_result$response$candidates[[1]]$content$parts[[1]]$text
  } else if (provider == "openai") {
    # OpenAI: response → body → choices[1] → message → content
    batch_result$response$body$choices[[1]]$message$content
  }
}

results_list   <- vector("list", n_articles)
files_analysed <- character(n_articles)
errors_log     <- list()
timings        <- rep(NA_real_, n_articles)

for (i in seq_len(n_articles)) {

  article_id        <- article_ids[i]
  files_analysed[i] <- article_id

  # Handle read errors (article couldn't be extracted in 03c)
  if (read_errors[i]) {
    results_list[[i]] <- list(filename = article_id, status = "READ_ERROR")
    errors_log[[length(errors_log) + 1]] <- list(
      file  = article_id,
      error = "Could not read article or text is empty",
      index = i
    )
    next
  }

  batch_result <- all_batch_results[[article_id]]

  # No result returned
  if (is.null(batch_result)) {
    results_list[[i]] <- list(filename = article_id, status = "API_ERROR")
    errors_log[[length(errors_log) + 1]] <- list(
      file  = article_id,
      error = "No result returned from batch API (chunk may not have been submitted)",
      index = i
    )
    next
  }

  # Check for API-level errors in the result
  if (api_provider == "openai") {
    error_obj <- batch_result$error
    if (!is.null(error_obj) && length(error_obj) > 0) {
      error_msg <- paste("OpenAI batch error:", error_obj$code, "-", error_obj$message)
      results_list[[i]] <- list(filename = article_id, status = "API_ERROR", error = error_msg)
      errors_log[[length(errors_log) + 1]] <- list(file = article_id, error = error_msg, index = i)
      next
    }
  }

  # Extract and parse the LLM response text
  api_result <- tryCatch({
    response_text <- extract_response_text(batch_result, api_provider)
    fromJSON(response_text, simplifyDataFrame = FALSE)
  }, error = function(e) {
    list(error = paste("Result parse error:", e$message))
  })

  # Determine status using config-driven logic (no hardcoded field names)
  status <- determine_status(api_result, skip_if_false)

  if (status == "API_ERROR") {
    cat(sprintf("  [ERROR] %s: %s\n", article_id, api_result$error))
    errors_log[[length(errors_log) + 1]] <- list(
      file = article_id, error = api_result$error, index = i
    )
  }

  # Safely handle non-list results (malformed LLM JSON)
  if (!is.list(api_result)) {
    cat(sprintf("  [WARN] %s: LLM returned non-list result (type: %s). Wrapping.\n",
                article_id, typeof(api_result)))
    api_result <- list(raw_response = api_result)
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


# ==============================================================================
# PHASE 3: Summary and save
# ==============================================================================

# Status summary
status_counts <- table(sapply(results_list, function(x) if (!is.null(x$status)) x$status else "UNKNOWN"))
cat("\n  Status summary:\n")
for (s in names(status_counts)) {
  cat(sprintf("    %-20s %d\n", s, status_counts[s]))
}

# Save final RDS
cat("\nSaving final results...\n")
project_results <- setNames(results_list, files_analysed)
rds_path <- file.path(OUTPUT_DIR, paste0(project_name, "_results.rds"))
saveRDS(project_results, rds_path)
cat(sprintf("  Results saved: %s\n", rds_path))

# Set variables that downstream scripts (04, 05, 06) expect
total_elapsed_secs <- NA_real_

cat(sprintf("\nBatch parsing complete. %d articles → %d results.\n",
            n_articles, sum(sapply(results_list, function(x) x$status == "PROCESSED"))))
if (length(errors_log) > 0) {
  cat(sprintf("  Errors: %d (see errors_log for details)\n", length(errors_log)))
}
cat("\nYou can now run Steps 4-6 (summary, post-processing, results object).\n")
