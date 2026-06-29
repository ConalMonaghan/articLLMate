# ==============================================================================
# STEP 0.2: CHECK LOCAL MODELS (OLLAMA)
# ==============================================================================
# PURPOSE:  Verify Ollama is installed and running, list available models,
#           and confirm the configured model_id is available locally.
#           Uses Ollama's REST API via httr2 (no R ollama package needed).
#
# EXPECTS FROM MASTER:  model_id
# ==============================================================================

cat("Checking local model setup (Ollama)...\n")

# ---- 0.2a. Check Ollama is installed ----
ollama_path <- Sys.which("ollama")
if (ollama_path == "") {
  stop(
    "\n\n",
    "=== OLLAMA NOT INSTALLED ===\n",
    "Ollama is required for local model execution.\n",
    "Install from: https://ollama.com/download\n"
  )
}
cat("  [OK] Ollama found at:", ollama_path, "\n")

# ---- 0.2b. Check Ollama server is running & list models ----
available_models <- tryCatch({
  resp <- httr2::request("http://localhost:11434/api/tags") |> httr2::req_perform()
  httr2::resp_body_json(resp)$models
}, error = function(e) {
  stop(
    "\n\n",
    "=== OLLAMA SERVER NOT RUNNING ===\n",
    "Could not connect to Ollama. Start the server first:\n",
    "  In terminal: ollama serve\n",
    "Error: ", e$message, "\n"
  )
})

# ---- 0.2c. Display available models ----
if (is.null(available_models) || length(available_models) == 0) {
  cat("\n  No models currently downloaded.\n")
  cat("  To download a model, run in terminal:\n")
  cat("    ollama pull deepseek-r1:32b\n")
  cat("    ollama pull qwen3-coder:30b\n")
  stop("No local models available. Download one first with: ollama pull <model_name>")
} else {
  cat("\n  Available local models:\n")
  cat("  ", paste(rep("-", 60), collapse = ""), "\n")
  model_names <- character(length(available_models))
  for (i in seq_along(available_models)) {
    m <- available_models[[i]]
    model_names[i] <- m$name
    model_size <- if (!is.null(m$size)) paste0(round(as.numeric(m$size) / 1e9, 1), " GB") else "?"
    cat(sprintf("    %-35s %s\n", m$name, model_size))
  }
  cat("  ", paste(rep("-", 60), collapse = ""), "\n")
  cat(sprintf("  Total: %d model(s)\n\n", length(available_models)))
}

# ---- 0.2d. Verify configured model is available ----
model_found <- model_id %in% model_names

if (!model_found) {
  # Try partial match
  partial_matches <- grep(model_id, model_names, value = TRUE, fixed = TRUE)
  if (length(partial_matches) > 0) {
    cat(sprintf("  [OK] Model '%s' found (matched: %s)\n", model_id, partial_matches[1]))
  } else {
    stop(
      "\n\n",
      "=== MODEL NOT FOUND ===\n",
      "Configured model '", model_id, "' is not available locally.\n",
      "Available models: ", paste(model_names, collapse = ", "), "\n\n",
      "To download it, run in terminal:\n",
      "  ollama pull ", model_id, "\n"
    )
  }
} else {
  cat(sprintf("  [OK] Configured model '%s' is available.\n", model_id))
}

cat("\n  To download additional models, run in terminal:\n")
cat("    ollama pull <model_name>\n")
cat("  Browse models at: https://ollama.com/library\n")

# ---- 0.2e. Set Ollama server-level environment variables ----
if (exists("ollama_num_parallel") && !is.na(ollama_num_parallel)) {
  Sys.setenv(OLLAMA_NUM_PARALLEL = as.integer(ollama_num_parallel))
  cat(sprintf("  [OK] OLLAMA_NUM_PARALLEL = %d\n", as.integer(ollama_num_parallel)))
}
if (exists("ollama_max_loaded") && !is.na(ollama_max_loaded)) {
  Sys.setenv(OLLAMA_MAX_LOADED_MODELS = as.integer(ollama_max_loaded))
  cat(sprintf("  [OK] OLLAMA_MAX_LOADED_MODELS = %d\n", as.integer(ollama_max_loaded)))
}
if (exists("ollama_num_ctx") && !is.na(ollama_num_ctx)) {
  cat(sprintf("  [OK] num_ctx = %d (will be passed per-request)\n", as.integer(ollama_num_ctx)))
}

cat("\nLocal model check passed.\n")
