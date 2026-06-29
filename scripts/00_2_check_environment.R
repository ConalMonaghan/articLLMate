# ==============================================================================
# STEP 0: CHECK ENVIRONMENT
# ==============================================================================
# PURPOSE:  Validate that the conda environment, Python packages, API key,
#           and GPU accelerator are all present before we start processing.
#           This script does NOT install anything - it just checks.
#           If something is missing, it tells you what to do.
#
# EXPECTS FROM MASTER:  env_name, api_provider, execution_mode
# ==============================================================================

cat("Checking environment...\n")

# ---- 0a. Conda environment ----
tryCatch({
  use_condaenv(env_name, required = TRUE)
}, error = function(e) {
  stop(
    "\n\n",
    "=== CONDA ENVIRONMENT NOT FOUND ===\n",
    "Could not find conda environment '", env_name, "'.\n",
    "Please run 'Reticulate Setup.R' first to create it.\n",
    "Error: ", e$message, "\n"
  )
})

cat("  [OK] Conda environment '", env_name, "' is active.\n", sep = "")

# ---- 0b. Check required Python packages (API mode only) ----
if (execution_mode == "api") {

  required_packages <- switch(api_provider,
    "openai"    = c("openai", "json"),
    "gemini"    = c("google.generativeai", "json"),
    stop("Unknown api_provider: '", api_provider, "'. Supported: 'openai', 'gemini'.")
  )

  # Batch mode requires the google-genai SDK (separate from google-generativeai)
  if (isTRUE(batch_mode) && api_provider == "gemini") {
    required_packages <- c(required_packages, "google.genai")
  }

  for (pkg in required_packages) {
    if (!py_module_available(pkg)) {
      stop(
        "\n\n",
        "=== MISSING PYTHON PACKAGE ===\n",
        "Python package '", pkg, "' is not installed in the '", env_name, "' environment.\n",
        "Please run 'Reticulate Setup.R' to install required packages.\n"
      )
    }
  }
  cat("  [OK] Required Python packages available:", paste(required_packages, collapse = ", "), "\n")

} else {
  cat("  [OK] Local mode — skipping Python package check.\n")
}

# ---- 0c. API key check (API mode only) ----
if (execution_mode == "api") {

  # Load .env file from project root
  env_file <- here(".env")
  if (file.exists(env_file)) {
    dotenv::load_dot_env(env_file)
  } else {
    cat("  [NOTE] No .env file found at:", env_file, "\n")
    cat("         Checking system environment variables instead.\n")
  }

  # Map provider to expected env var name
  api_key_name <- switch(api_provider,
    "openai"    = "OPENAI_API_KEY",
    "gemini"    = "GEMINI_API_KEY"
  )

  api_key_value <- Sys.getenv(api_key_name)
  if (api_key_value == "") {
    stop(
      "\n\n",
      "=== API KEY NOT FOUND ===\n",
      "Environment variable '", api_key_name, "' is empty.\n",
      "Create a .env file in the project root with:\n",
      "  ", api_key_name, "=your-key-here\n"
    )
  }

  # Push the key into Python's os.environ so the API client can find it
  py_run_string(paste0("import os; os.environ[", deparse(api_key_name), "] = ", deparse(api_key_value)))

  # Show first/last few chars so user can verify it's the right key
  key_preview <- paste0(substr(api_key_value, 1, 7), "...", substr(api_key_value, nchar(api_key_value) - 3, nchar(api_key_value)))
  cat("  [OK] API key found:", api_key_name, "(", key_preview, ")\n")

} else {
  cat("  [OK] Local mode — skipping API key check.\n")
}

# ---- 0d. GPU / Accelerator detection ----
tryCatch({
  py_run_string("
import torch
if torch.backends.mps.is_available():
    _accelerator = 'MPS (Apple Silicon GPU)'
elif torch.cuda.is_available():
    _accelerator = f'CUDA ({torch.cuda.get_device_name(0)})'
else:
    _accelerator = 'CPU only'
")
  gpu_status <<- py$`_accelerator`
}, error = function(e) {
  gpu_status <<- "Unknown (torch not installed)"
})
cat("  [OK] Accelerator:", gpu_status, "\n")

# ---- 0e. System summary ----
sys_info <- Sys.info()
cat("\n  System Summary:\n")
cat("    OS:        ", sys_info["sysname"], sys_info["release"], "(", sys_info["machine"], ")\n")
cat("    R:         ", R.version$version.string, "\n")
cat("    Python:    ", as.character(py_config()$version), "\n")
cat("    GPU:       ", gpu_status, "\n")
cat("    Mode:      ", execution_mode, "\n")
if (execution_mode == "api") {
  cat("    Provider:  ", api_provider, "\n")
}
cat("    Model:     ", model_id, "\n")

cat("\nEnvironment check passed.\n")
