# ==============================================================================
# STEP 2: SELECT AND VALIDATE PROMPT
# ==============================================================================
# PURPOSE:  Load the prompt file and verify it exists and is readable.
#
# EXPECTS FROM MASTER:  prompt_file
# CREATES:              prompt_text (string)
# ==============================================================================

cat("Loading prompt...\n")

# ---- 2a. Check prompt file exists ----
prompt_path <- here(prompt_file)

if (!file.exists(prompt_path)) {
  available <- list.files(here("prompts"), full.names = FALSE)
  stop(
    "\n\n",
    "=== PROMPT FILE NOT FOUND ===\n",
    "Cannot find: ", prompt_path, "\n",
    "Available prompts in prompts/ folder:\n",
    paste("  -", available, collapse = "\n"), "\n",
    "Update 'prompt_file' in _MASTER_RUN_PIPELINE.R\n"
  )
}

# ---- 2b. Read the prompt ----
prompt_text <- readChar(prompt_path, file.info(prompt_path)$size)
prompt_text <- gsub("\r\n", "\n", prompt_text, fixed = TRUE)  # normalise Windows line endings

cat(sprintf("  [OK] Prompt loaded: %s (%d characters)\n", prompt_file, nchar(prompt_text)))
cat(paste0("  Preview: ", substr(prompt_text, 1, 200), "...\n"))

cat("\nPrompt loaded and validated.\n")
