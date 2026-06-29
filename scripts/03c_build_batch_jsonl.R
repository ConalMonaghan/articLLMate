# ==============================================================================
# STEP 3c: BUILD BATCH JSONL FILES
# ==============================================================================
# PURPOSE:  Extract article text and write provider-specific JSONL files for
#           batch API submission. NO API calls are made here — this is a pure
#           data-preparation step.
#
#           Output JSONL files are saved to: {OUTPUT_DIR}/batch_input/
#           One file per chunk (auto-split by size or request count).
#
# EXPECTS FROM MASTER:
#   input_type = "xml" → xml_files, n_articles
#   input_type = "rds" → article_keys, articles_data, n_articles
#   Always: prompt_text, model_id, api_provider, OUTPUT_DIR, project_name
#
# CREATES:  JSONL file(s) in {OUTPUT_DIR}/batch_input/
#           batch_manifest.rds — metadata for 03d/03e to use
#
# SUPPORTED PROVIDERS: "gemini", "openai"
#
# USAGE:
#   This script is sourced by _MASTER_RUN_PIPELINE.R when batch_mode = TRUE.
#   After running, use 03d_submit_batch.R to submit each JSONL file, then
#   03e_parse_batch_results.R to combine results into the standard RDS format.
#
# SEE ALSO: docs/batch_guide.md for the full student walkthrough.
# ==============================================================================

cat(sprintf("Building batch JSONL for %d articles [%s / %s]...\n\n",
            n_articles, api_provider, model_id))


# ==============================================================================
# CONFIGURATION — Chunking limits (provider-specific)
# ==============================================================================
#
# OpenAI gpt-4o-mini batch API hard limits (as of 2025):
#   - 50,000 requests per file  → use 45,000 (conservative)
#   - 200 MB per file           → use 190 MB (conservative)
#   - 5,000,000 tokens per day  → use 4,500,000 per chunk so each chunk fits
#     within one day's quota without queuing.  Tokens are estimated as
#     ceiling(bytes_in_jsonl_line / 4) — a slight overestimate that keeps us
#     safely under the limit.
#
# Gemini has no published per-batch token cap, so we use large file/count limits
# only.  Adjust if your project quota is lower.

if (api_provider == "openai") {
  # OpenAI Tier 4 — gpt-4.1-mini
  # TPD: 1,000,000,000 | Max requests per file: 50,000 | File size limit: 200MB
  BATCH_MAX_FILE_SIZE <- 180e6      # 90% of 200MB hard limit
  BATCH_MAX_REQUESTS  <- 45000      # 90% of 50k lines-per-file limit
  BATCH_MAX_TOKENS    <- 900000000  # 90% of 1B TPD
} else {
  # Google Gemini Tier 2 — gemini-2.5-flash
  # Enqueued tokens (all active jobs combined): 400,000,000
  # Concurrent batch jobs: 100 | File size limit: 2GB
  BATCH_MAX_FILE_SIZE  <- 1.8e9     # 90% of 2GB per-file limit
  BATCH_MAX_CONCURRENT <- 90        # 90% of 100 concurrent job limit
  BATCH_MAX_TOKENS     <- 360000000 # 90% of 400M total enqueued tokens
  # No per-file line limit published — file size is the binding split constraint
}

# Whether to inline the system prompt into the user message.
# Workaround for Gemini batch bug (googleapis/python-genai#1190) where
# systemInstruction may be ignored. Set TRUE if results lack system context.
BATCH_SYSTEM_PROMPT_INLINE <- FALSE


# ==============================================================================
# VALIDATION
# ==============================================================================

if (!api_provider %in% c("gemini", "openai")) {
  stop("Batch JSONL generation currently supports api_provider = 'gemini' or 'openai'. Got: '",
       api_provider, "'")
}


# ==============================================================================
# PHASE 1: Extract article text
# ==============================================================================

cat("Phase 1: Extracting article text...\n")

article_texts <- vector("list", n_articles)
article_ids   <- character(n_articles)
read_errors   <- logical(n_articles)

for (i in seq_len(n_articles)) {

  if (input_type == "xml") {
    file_path      <- xml_files[i]
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

n_valid  <- sum(!read_errors)
n_errors <- sum(read_errors)
cat(sprintf("  %d articles ready, %d read errors.\n", n_valid, n_errors))


# ==============================================================================
# PHASE 2: Write JSONL file(s) — provider-specific format
# ==============================================================================

cat("\nPhase 2: Writing JSONL batch file(s)...\n")

user_msg_prefix <- "Analyze this academic paper and return your response as JSON:\n\n"

# Handle system-prompt inlining (Gemini workaround)
if (BATCH_SYSTEM_PROMPT_INLINE && api_provider == "gemini") {
  user_msg_full_prefix <- paste0(prompt_text, "\n\n---\n\n", user_msg_prefix)
  cat("  [NOTE] System prompt inlined in user message (Gemini workaround mode).\n")
} else {
  user_msg_full_prefix <- user_msg_prefix
}

# Create output directory
jsonl_dir <- file.path(OUTPUT_DIR, "batch_input")
if (!dir.exists(jsonl_dir)) dir.create(jsonl_dir, recursive = TRUE)

# ---- Helper: build one JSONL line per provider ----

build_jsonl_line_gemini <- function(article_id, user_content, prompt_text, inline) {
  request_obj <- list(
    key = article_id,
    request = list(
      contents = list(list(
        parts = list(list(text = user_content))
      )),
      generationConfig = list(
        responseMimeType = "application/json"
      )
    )
  )
  if (!inline) {
    request_obj$request$systemInstruction <- list(
      parts = list(list(text = prompt_text))
    )
  }
  toJSON(request_obj, auto_unbox = TRUE)
}

build_jsonl_line_openai <- function(article_id, user_content, prompt_text, model_id) {
  request_obj <- list(
    custom_id = article_id,
    method = "POST",
    url = "/v1/chat/completions",
    body = list(
      model = model_id,
      messages = list(
        list(role = "system", content = prompt_text),
        list(role = "user", content = user_content)
      ),
      response_format = list(type = "json_object")
    )
  )
  toJSON(request_obj, auto_unbox = TRUE)
}

# ---- Write chunks ----

chunk_index       <- 1
chunk_line_count  <- 0
chunk_file_size   <- 0
chunk_token_count <- 0
chunk_path        <- file.path(jsonl_dir, sprintf("batch_input_%03d.jsonl", chunk_index))
chunk_con         <- file(chunk_path, open = "w")
chunk_paths       <- chunk_path
chunk_token_ests  <- integer(0)  # per-chunk token totals, one entry per closed chunk
article_chunk_map <- integer(n_articles)

for (i in seq_len(n_articles)) {

  if (read_errors[i]) next

  user_content <- paste0(user_msg_full_prefix, article_texts[[i]])

  # Build provider-specific JSON line
  if (api_provider == "gemini") {
    json_line <- build_jsonl_line_gemini(article_ids[i], user_content, prompt_text,
                                         BATCH_SYSTEM_PROMPT_INLINE)
  } else if (api_provider == "openai") {
    json_line <- build_jsonl_line_openai(article_ids[i], user_content, prompt_text,
                                          model_id)
  }

  # Check if adding this line would exceed any chunk limit
  line_bytes  <- nchar(json_line, type = "bytes") + 1L   # +1 for newline
  line_tokens <- ceiling(line_bytes / 4)                 # ~4 bytes per token (conservative)

  exceeds_size   <- chunk_file_size   + line_bytes   > BATCH_MAX_FILE_SIZE
  exceeds_tokens <- chunk_token_count + line_tokens  > BATCH_MAX_TOKENS
  exceeds_lines  <- if (api_provider == "openai") chunk_line_count >= BATCH_MAX_REQUESTS else FALSE

  if (chunk_line_count > 0 && (exceeds_size || exceeds_tokens || exceeds_lines)) {
    close(chunk_con)
    cat(sprintf("  Chunk %d: %d requests, %.1f MB, ~%s est. tokens\n",
                chunk_index, chunk_line_count, chunk_file_size / 1e6,
                formatC(chunk_token_count, format = "d", big.mark = ",")))

    chunk_token_ests     <- c(chunk_token_ests, chunk_token_count)
    chunk_index          <- chunk_index + 1
    chunk_line_count     <- 0
    chunk_file_size      <- 0
    chunk_token_count    <- 0
    chunk_path           <- file.path(jsonl_dir, sprintf("batch_input_%03d.jsonl", chunk_index))
    chunk_con            <- file(chunk_path, open = "w")
    chunk_paths          <- c(chunk_paths, chunk_path)
  }

  writeLines(json_line, chunk_con)
  chunk_line_count  <- chunk_line_count  + 1
  chunk_file_size   <- chunk_file_size   + line_bytes
  chunk_token_count <- chunk_token_count + line_tokens
  article_chunk_map[i] <- chunk_index
}

close(chunk_con)
cat(sprintf("  Chunk %d: %d requests, %.1f MB, ~%s est. tokens\n",
            chunk_index, chunk_line_count, chunk_file_size / 1e6,
            formatC(chunk_token_count, format = "d", big.mark = ",")))
chunk_token_ests <- c(chunk_token_ests, chunk_token_count)

n_chunks <- length(chunk_paths)


# ==============================================================================
# PHASE 3: Save manifest (metadata for 03d and 03e)
# ==============================================================================

batch_manifest <- list(
  project_name      = project_name,
  model_id          = model_id,
  api_provider      = api_provider,
  prompt_file       = prompt_file,
  skip_if_false     = table_config$skip_if_false,   # needed by 03e determine_status
  n_articles        = n_articles,
  n_valid           = n_valid,
  n_chunks          = n_chunks,
  chunk_paths       = chunk_paths,
  chunk_token_ests  = chunk_token_ests,             # estimated tokens per chunk
  article_ids       = article_ids,
  read_errors       = read_errors,
  article_chunk_map = article_chunk_map,
  created_at        = Sys.time()
)

manifest_path <- file.path(OUTPUT_DIR, "batch_manifest.rds")
saveRDS(batch_manifest, manifest_path)

cat(sprintf("\n  %d JSONL file(s) saved to: %s\n", n_chunks, jsonl_dir))
cat(sprintf("  Manifest saved to:        %s\n", manifest_path))
cat("\n============================================================\n")
cat("JSONL generation complete. Next steps:\n")
cat("  1. Run 03d_submit_batch.R for each JSONL chunk\n")
cat("  2. Run 03e_parse_batch_results.R to combine results\n")
cat("============================================================\n")
