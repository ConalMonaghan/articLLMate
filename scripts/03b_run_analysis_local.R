# ==============================================================================
# STEP 3b: RUN THE ANALYSIS LOOP (LOCAL MODE - OLLAMA)
# ==============================================================================
# PURPOSE:  Loop over all articles (from XML files or RDS objects), run each
#           through a local model via Ollama REST API, and save:
#           1) Individual .json files per article (immediate, crash-safe)
#           2) A partial .rds backup every save_interval articles
#           3) Final results as .rds at the end
#
#           Uses httr2 to call Ollama's REST API (no R ollama package needed).
#
# EXPECTS FROM MASTER:
#   input_type = "xml" → xml_files, n_articles
#   input_type = "rds" → article_keys, articles_data, n_articles
#   Always: prompt_text, model_id, OUTPUT_DIR, project_name, save_interval
#   Optional: ollama_num_ctx, ollama_temperature, ollama_think, strip_thinking_tokens
#
# CREATES: results_list, files_analysed, errors_log, timings, total_elapsed_secs
# ==============================================================================

cat(sprintf("Starting LOCAL analysis of %d articles using %s (Ollama)...\n\n",
            n_articles, model_id))

# ---- Build Ollama options ----
ollama_opts <- list()
if (exists("ollama_num_ctx") && !is.na(ollama_num_ctx)) {
  ollama_opts$num_ctx <- as.integer(ollama_num_ctx)
}
if (exists("ollama_temperature") && !is.na(ollama_temperature)) {
  ollama_opts$temperature <- ollama_temperature
}


# ---- 3b.1 Initialise tracking variables ----
results_list   <- vector("list", n_articles)
files_analysed <- character(n_articles)
errors_log     <- list()
timings        <- numeric(n_articles)


# ---- 3b.2 THE LOOP ----
tic("Total Analysis")

pb <- txtProgressBar(min = 0, max = n_articles, style = 3)

for (i in seq_len(n_articles)) {

  start_time <- Sys.time()

  # A. Get article text and identifier
  if (input_type == "xml") {
    file_path    <- xml_files[i]
    article_id   <- basename(file_path)
    text_content <- tryCatch({
      readChar(file_path, file.info(file_path)$size)
    }, error = function(e) { NA })

  } else if (input_type == "rds") {
    key        <- article_keys[i]
    article_id <- key
    article    <- articles_data[[key]]

    title_text <- if (!is.null(article$XML$Title) && !is.na(article$XML$Title)) article$XML$Title else ""
    body_text  <- if (!is.null(article$XML$Text)  && !is.na(article$XML$Text))  article$XML$Text  else NA

    text_content <- if (!is.na(body_text) && nchar(body_text) > 0) {
      paste0(title_text, "\n\n", body_text)
    } else {
      NA
    }
  }

  # B. Call Ollama REST API
  if (!is.na(text_content) && nchar(text_content) > 0) {

    api_result <- tryCatch({

      messages <- list(
        list(role = "system", content = prompt_text),
        list(role = "user",   content = paste0("Analyze this academic paper and return your response as JSON:\n\n", text_content))
      )

      req_body <- list(
        model    = model_id,
        messages = messages,
        stream   = FALSE,
        format   = "json"
      )

      # think: FALSE disables model-level reasoning (recommended for Gemma4 to
      # prevent looping/garbled output). TRUE enables it. NA = omit (model default).
      if (exists("ollama_think") && !is.na(ollama_think)) {
        req_body$think <- isTRUE(ollama_think)
      }

      if (length(ollama_opts) > 0) {
        req_body$options <- ollama_opts
      }

      resp <- httr2::request("http://localhost:11434/api/chat") |>
        httr2::req_body_json(req_body) |>
        httr2::req_timeout(600) |>
        httr2::req_perform()

      response_body <- httr2::resp_body_json(resp)
      response_text <- response_body$message$content

      # Strip thinking-token blocks before the JSON payload.
      # Gemma4 format: <|channel>thought\n...<channel|>
      # Fallback format (DeepSeek-R1 etc.): <think>...</think>
      # (?s) enables DOTALL so . matches newlines — required for multiline blocks.
      # After stripping, extract the first {...} in case prose remains before the JSON.
      if (exists("strip_thinking_tokens") && isTRUE(strip_thinking_tokens)) {
        response_text <- gsub("(?s)<\\|channel>thought\\n.*?<channel\\|>", "",
                              response_text, perl = TRUE)
        response_text <- gsub("(?s)<think(?:ing)?>.*?</think(?:ing)?>", "",
                              response_text, ignore.case = TRUE, perl = TRUE)
        response_text <- trimws(response_text)
        if (!startsWith(response_text, "{") && !startsWith(response_text, "[")) {
          json_match <- regmatches(response_text,
                                   regexpr("(?s)\\{.*\\}", response_text, perl = TRUE))
          if (length(json_match) > 0) response_text <- json_match
        }
      }

      # Sanitise control characters that local models sometimes embed unescaped
      # inside JSON strings (tab, carriage-return). JSON requires these to be
      # escaped; a literal tab or CR inside a string value is a parse error.
      response_text <- gsub("\t", " ",  response_text, fixed = TRUE)
      response_text <- gsub("\r", "",   response_text, fixed = TRUE)

      jsonlite::fromJSON(response_text, simplifyDataFrame = FALSE)

    }, error = function(e) {
      list(error = paste("Ollama error:", e$message))
    })

    # Safely handle non-list results (malformed LLM JSON)
    if (!is.list(api_result)) {
      api_result <- list(raw_response = api_result)
    }
    api_result$filename <- article_id

  } else {
    api_result <- list(filename = article_id, status = "READ_ERROR",
                       error = "Could not read article or text is empty")
  }

  duration <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))

  files_analysed[i] <- article_id

  # Determine status
  status <- determine_status(api_result, table_config$skip_if_false)

  if (status == "API_ERROR") {
    cat(sprintf("\n  [ERROR] %s: %s\n", article_id, api_result$error))
    errors_log[[length(errors_log) + 1]] <- list(
      file = article_id, error = api_result$error, index = i
    )
    if (exists("FAILURE_COUNT")) FAILURE_COUNT <<- FAILURE_COUNT + 1L
  }

  api_result$status <- status
  results_list[[i]] <- api_result
  timings[i]        <- duration

  # Save individual JSON (crash-safe)
  json_out_name <- paste0(gsub("[/\\\\:*?\"<>|]", "_", sub("\\.xml$", "", article_id)), ".json")
  tryCatch({
    write_json(api_result, file.path(OUTPUT_DIR, json_out_name),
               auto_unbox = TRUE, pretty = TRUE)
  }, error = function(e) {
    cat(sprintf("\n  [WARN] Could not save JSON for %s: %s\n", article_id, e$message))
  })

  setTxtProgressBar(pb, i)

  # Periodic RDS backup
  if (i %% save_interval == 0) {
    tryCatch({
      partial_rds <- setNames(results_list[1:i], files_analysed[1:i])
      saveRDS(partial_rds, file.path(OUTPUT_DIR, paste0(project_name, "_results_partial.rds")))
    }, error = function(e) {
      cat(sprintf("\n  [WARN] Partial save failed: %s\n", e$message))
    })
  }

  # Dashboard logging
  if (exists("log_to_dashboard") && is.function(log_to_dashboard)) {
    tryCatch({
      rds_source <- if (input_type == "rds") basename(INPUT_FILE) else basename(xml_files[i])
      log_to_dashboard(
        article_id = article_id,
        rds_source = rds_source,
        status     = status,
        duration   = duration,
        index      = i,
        api_result = api_result
      )
    }, error = function(e) {
      cat(sprintf("\n  [WARN] Dashboard log failed: %s\n", e$message))
    })
  }
}

close(pb)

total_elapsed <- toc(quiet = TRUE)
total_elapsed_secs <- total_elapsed$toc - total_elapsed$tic

cat(sprintf("\n\nLoop complete. %d articles processed in %.1f seconds.\n",
            n_articles, total_elapsed_secs))


# ---- 3b.3 Save final RDS ----
cat("Saving results...\n")

project_results <- setNames(results_list, files_analysed)
rds_path <- file.path(OUTPUT_DIR, paste0(project_name, "_results.rds"))
saveRDS(project_results, rds_path)
cat(sprintf("  [OK] R list object saved: %s\n", rds_path))

# Clean up partial backup
partial_rds <- file.path(OUTPUT_DIR, paste0(project_name, "_results_partial.rds"))
if (file.exists(partial_rds)) file.remove(partial_rds)

cat("Analysis complete. Post-processing will generate the CSV.\n")
