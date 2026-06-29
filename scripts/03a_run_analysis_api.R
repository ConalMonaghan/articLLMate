# ==============================================================================
# STEP 3a: RUN THE ANALYSIS LOOP (API MODE)
# ==============================================================================
# PURPOSE:  Loop over all articles (from XML files or RDS objects), call the
#           API for each one, and save:
#           1) Individual .json files per article (immediate, crash-safe)
#           2) A partial .rds backup every save_interval articles
#           3) Final results as .rds at the end
#
# EXPECTS FROM MASTER:
#   input_type = "xml" → xml_files, n_articles
#   input_type = "rds" → article_keys, articles_data, n_articles
#   Always: prompt_text, model_id, api_provider, OUTPUT_DIR, project_name, save_interval
#
# CREATES: results_list, files_analysed, errors_log, timings, total_elapsed_secs
# ==============================================================================

cat(sprintf("Starting analysis of %d articles using %s (%s)...\n\n",
            n_articles, model_id, api_provider))

# ---- 3a.1 Set up the API client via Python ----
if (api_provider == "openai") {

  py_run_string("
import json
from openai import OpenAI

def analyze_paper(text_content, system_prompt, model_id):
    \"\"\"Call OpenAI API with the article text and prompt. Returns parsed JSON dict.\"\"\"
    client = OpenAI()
    try:
        response = client.chat.completions.create(
            model=model_id,
            messages=[
                {'role': 'system', 'content': system_prompt},
                {'role': 'user', 'content': f'Analyze this academic paper and return your response as JSON:\\n\\n{text_content}'}
            ],
            response_format={'type': 'json_object'},
            temperature=0
        )
        result = json.loads(response.choices[0].message.content)
        return result
    except Exception as e:
        return {'error': str(e)}
")

} else if (api_provider == "gemini") {

  py_run_string("
import json
import google.generativeai as genai
import os

genai.configure(api_key=os.environ.get('GEMINI_API_KEY'))

def analyze_paper(text_content, system_prompt, model_id):
    \"\"\"Call Gemini API with the article text and prompt. Returns parsed JSON dict.\"\"\"
    try:
        model = genai.GenerativeModel(
            model_name=model_id,
            system_instruction=system_prompt,
            generation_config={'response_mime_type': 'application/json', 'temperature': 0}
        )
        response = model.generate_content(
            f'Analyze this academic paper and return your response as JSON:\\n\\n{text_content}'
        )
        result = json.loads(response.text)
        return result
    except Exception as e:
        return {'error': str(e)}
")

} else {
  stop("Unknown api_provider: '", api_provider, "'. Supported: 'openai', 'gemini'.")
}

cat("  [OK] API client ready.\n\n")


# ---- 3a.2 Initialise tracking variables ----
results_list   <- vector("list", n_articles)
files_analysed <- character(n_articles)
errors_log     <- list()
timings        <- numeric(n_articles)


# ---- 3a.3 THE LOOP ----
tic("Total Analysis")
pb <- txtProgressBar(min = 0, max = n_articles, style = 3)

for (i in seq_len(n_articles)) {

  start_time <- Sys.time()

  # A. Get article text and identifier based on input_type
  if (input_type == "xml") {
    file_path  <- xml_files[i]
    article_id <- basename(file_path)

    text_content <- tryCatch({
      readChar(file_path, file.info(file_path)$size)
    }, error = function(e) { NA })

  } else if (input_type == "rds") {
    key        <- article_keys[i]
    article_id <- key
    article    <- articles_data[[key]]

    # Combine title + text
    title_text <- if (!is.null(article$XML$Title) && !is.na(article$XML$Title)) article$XML$Title else ""
    body_text  <- if (!is.null(article$XML$Text) && !is.na(article$XML$Text)) article$XML$Text else NA

    if (!is.na(body_text) && nchar(body_text) > 0) {
      text_content <- paste0(title_text, "\n\n", body_text)
    } else {
      text_content <- NA
    }
  }

  # Track identifier
  files_analysed[i] <- article_id

  # B. Call the API (if text was read successfully)
  if (!is.na(text_content) && nchar(text_content) > 0) {

    api_result <- tryCatch({
      py$analyze_paper(text_content, prompt_text, model_id)
    }, error = function(e) {
      list(error = paste("R-Python bridge error:", e$message))
    })

    # Determine status using config-driven logic (no hardcoded field names)
    status <- determine_status(api_result, table_config$skip_if_false)

    if (status == "API_ERROR") {
      cat(sprintf("\n  [ERROR] %s: %s\n", article_id, api_result$error))
      errors_log[[length(errors_log) + 1]] <- list(
        file = article_id, error = api_result$error, index = i
      )
    }

    # Safely handle non-list results (malformed LLM JSON)
    if (!is.list(api_result)) {
      cat(sprintf("\n  [WARN] %s: LLM returned non-list result (type: %s). Wrapping.\n",
                  article_id, typeof(api_result)))
      api_result <- list(raw_response = api_result)
    }
    api_result$filename <- article_id
    api_result$status   <- status
    results_list[[i]]   <- api_result

  } else {
    # Could not read article
    status <- "READ_ERROR"
    results_list[[i]] <- list(filename = article_id, status = "READ_ERROR")
    errors_log[[length(errors_log) + 1]] <- list(
      file  = article_id,
      error = "Could not read article or text is empty",
      index = i
    )
  }

  # C. Save individual JSON immediately (crash-safe)
  # Sanitize identifier for filename (replace / and other invalid chars with _)
  json_out_name <- paste0(gsub("[/\\\\:*?\"<>|]", "_", sub("\\.xml$", "", article_id)), ".json")
  tryCatch({
    write_json(api_result, file.path(OUTPUT_DIR, json_out_name),
               auto_unbox = TRUE, pretty = TRUE)
  }, error = function(e) {
    cat(sprintf("\n  [WARN] Could not save JSON for %s: %s\n", article_id, e$message))
  })

  # D. Track timing
  duration <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
  timings[i] <- duration

  # E. Update progress bar
  setTxtProgressBar(pb, i)

  # F. Periodic RDS backup
  if (i %% save_interval == 0) {
    tryCatch({
      partial_rds <- setNames(results_list[1:i], files_analysed[1:i])
      saveRDS(partial_rds, file.path(OUTPUT_DIR, paste0(project_name, "_results_partial.rds")))
    }, error = function(e) {
      cat(sprintf("\n  [WARN] Partial save failed: %s\n", e$message))
    })
  }
}

close(pb)
total_elapsed <- toc(quiet = TRUE)
total_elapsed_secs <- total_elapsed$toc - total_elapsed$tic

cat(sprintf("\n\nLoop complete. %d articles processed in %.1f seconds.\n",
            n_articles, total_elapsed_secs))


# ---- 3a.4 Save final RDS ----
cat("Saving results...\n")

project_results <- setNames(results_list, files_analysed)
rds_path <- file.path(OUTPUT_DIR, paste0(project_name, "_results.rds"))
saveRDS(project_results, rds_path)
cat(sprintf("  [OK] R list object saved: %s\n", rds_path))

# Clean up partial backup
partial_rds <- file.path(OUTPUT_DIR, paste0(project_name, "_results_partial.rds"))
if (file.exists(partial_rds)) file.remove(partial_rds)

cat("Analysis complete. Post-processing will generate the CSV.\n")
