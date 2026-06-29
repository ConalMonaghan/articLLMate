# ==============================================================================
# STEP 3: RUN THE ANALYSIS LOOP
# ==============================================================================
# PURPOSE:  Loop over all .xml articles, call the API for each one, and save:
#           1) Individual .json files per article (immediate, crash-safe)
#           2) A partial .rds backup every save_interval articles
#           3) Final results as .rds at the end
#
# EXPECTS FROM MASTER:  xml_files OR R object, n_articless, prompt_text, model_id,
#                        api_provider, OUTPUT_DIR, project_name, save_interval
# CREATES:              results_list, files_analysed, errors_log, timings,
#                        total_elapsed_secs
# ==============================================================================

cat(sprintf("Starting analysis of %d articles using %s (%s)...\n\n",
            n_articles, model_id, api_provider))

# ---- 3a. Set up the API client via Python ----
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
            temperature=0.1
        )
        result = json.loads(response.choices[0].message.content)
        return result
    except Exception as e:
        return {'error': str(e)}
")

} else if (api_provider == "anthropic") {
  stop("Anthropic API support not yet implemented. Use api_provider = 'openai' for now.")

} else {
  stop("Unknown api_provider: '", api_provider, "'")
}

cat("  [OK] API client ready.\n\n")


# ---- 3b. Initialise tracking variables ----
results_list   <- vector("list", n_articles)
files_analysed <- character(n_articles)
errors_log     <- list()
timings        <- numeric(n_articles)


# ---- 3c. THE LOOP ----
tic("Total Analysis")
pb <- txtProgressBar(min = 0, max = n_articles, style = 3)

for (i in seq_along(xml_files)) {

  file_path <- xml_files[i]
  file_name <- basename(file_path)
  start_time <- Sys.time()

  # Track filename
  files_analysed[i] <- file_name

  # A. Read the XML file
  text_content <- tryCatch({
    readChar(file_path, file.info(file_path)$size)
  }, error = function(e) {
    NA
  })

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
      cat(sprintf("\n  [ERROR] %s: %s\n", file_name, api_result$error))
      errors_log[[length(errors_log) + 1]] <- list(
        file = file_name, error = api_result$error, index = i
      )
    }

    # Safely handle non-list results (malformed LLM JSON)
    if (!is.list(api_result)) {
      cat(sprintf("\n  [WARN] %s: LLM returned non-list result (type: %s). Wrapping.\n",
                  file_name, typeof(api_result)))
      api_result <- list(raw_response = api_result)
    }
    api_result$filename <- file_name
    api_result$status   <- status
    results_list[[i]]   <- api_result

  } else {
    # Could not read file
    status <- "READ_ERROR"
    results_list[[i]] <- list(filename = file_name, status = "READ_ERROR")
    errors_log[[length(errors_log) + 1]] <- list(
      file  = file_name,
      error = "Could not read file or file is empty",
      index = i
    )
  }

  # C. Save individual JSON immediately (crash-safe)
  json_out_name <- sub("\\.xml$", ".json", file_name)
  tryCatch({
    write_json(api_result, file.path(OUTPUT_DIR, json_out_name),
               auto_unbox = TRUE, pretty = TRUE)
  }, error = function(e) {
    cat(sprintf("\n  [WARN] Could not save JSON for %s: %s\n", file_name, e$message))
  })

  # D. Track timing
  duration <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
  timings[i] <- duration

  # E. Update progress bar
  setTxtProgressBar(pb, i)

  # F. Periodic RDS backup (silent save, no per-file printout)
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


# ---- 3d. Save final RDS ----
cat("Saving results...\n")

project_results <- setNames(results_list, files_analysed)
rds_path <- file.path(OUTPUT_DIR, paste0(project_name, "_results.rds"))
saveRDS(project_results, rds_path)
cat(sprintf("  [OK] R list object saved: %s\n", rds_path))

# Clean up partial backup
partial_rds <- file.path(OUTPUT_DIR, paste0(project_name, "_results_partial.rds"))
if (file.exists(partial_rds)) file.remove(partial_rds)

cat("Analysis complete. Post-processing will generate the CSV.\n")
