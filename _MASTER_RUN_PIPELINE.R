# ==============================================================================
# MASTER PIPELINE: articLLMate
# ==============================================================================
#
# PURPOSE:
# This script orchestrates the automated analysis of academic manuscripts
# to determine their theoretical and operational stance on psychopathology.
# Point it at a folder of .xml files or an .rds R object, pick a prompt, and run.
#
# HOW TO USE:
# 1. Run "Reticulate Setup.R" once to create the conda environment (first time only).
# 2. Create a .env file in the project root with your API key:
#       OPENAI_API_KEY=sk-...
# 3. Set the USER CONFIGURATION below.
# 4. Source this entire script (Ctrl+Shift+S in RStudio, or source("_MASTER_RUN_PIPELINE.R")).
#
# AUTHOR: Dr Conal Monaghan
# DATE:   January 2026
# VERSION: 2.0
# ==============================================================================

library(here)
library(reticulate)
library(tidyverse)
library(jsonlite)
library(tictoc)
library(yaml)
library(httr2)  # for Ollama REST API calls in local mode

# ==============================================================================
# USER CONFIGURATION - Edit these before each run
# ==============================================================================

project_name      <- "my_project"                       # Name for the output subfolder
env_name          <- "articLLMate"                       # Conda environment name
execution_mode    <- "api"                               # "api" = send to provider's servers | "local" = run model on this machine via Ollama
api_provider      <- "openai"                            # API provider: "openai", "gemini"
model_id          <- "gpt-4.1-mini"                      # Which model to use (e.g., "gpt-5-mini", [cheaper than 5.4] "gemini-3.5-flash", "deepseek-r1:32b", "gpt-oss:20b", "gemma4:26b", "gemma4:31b")
# Find current models using ollama list
batch_mode        <- FALSE                               # TRUE = build JSONL for batch API (Gemini/OpenAI, 50% cheaper) | FALSE = one-by-one
prompt_file       <- "prompts/prompt Valid"               # Path to the prompt file (relative to project root)
table_config_file <- "prompts/prompt Valid.yml"           # YAML file that maps JSON fields to output tables (main/metadata/detail). Skip Logic etc

# ---- Input Configuration ----
input_type        <- "xml"                               # "xml" = folder of .xml files | "rds" = R object(s) with articles
INPUT_DIR         <- here("input", "Test xml files")     # Folder containing .xml articles (used when input_type = "xml")
INPUT_FILE        <- here("input", "your_data")          # Path to .rds file OR folder of .rds files (used when input_type = "rds")
OUTPUT_DIR        <- here("output", project_name)        # Output folder (auto-created)
save_interval     <- 10                                  # Backup RDS every N articles
run_mode          <- "all"                               # "all" = process every article | number = process that many (e.g., 5, 300)

# ---- Ollama Configuration (local mode only) ----
ollama_num_ctx     <- 65536                          # Context window size (tokens). Lower = faster + less RAM. Set NA to use model default
ollama_max_loaded  <- 1                              # Max models loaded in VRAM simultaneously. Set NA to skip. Should essentially always be 1!
ollama_temperature    <- 0                           # LLM temperature (0 = deterministic). Set NA to use model default
ollama_think          <- FALSE                       # FALSE = disable thinking (recommended for Gemma4). TRUE = enable. NA = don't set (model default)
strip_thinking_tokens <- TRUE                        # TRUE = strip any embedded <think> tags from content before JSON parsing (safety net)

# ---- Dashboard Configuration (local mode only) ----
dashboard         <- F                          # TRUE = log each article to Google Sheets | FALSE = skip
dashboard_sheet   <- "articLLMate Dashboard"         # Google Sheet name (or URL / sheet ID)
dashboard_tab     <- "Sheet1"                            # Tab/worksheet name within the sheet
machine_id        <- "my_machine"                        # Machine identifier for dashboard logging (e.g. "mac", "rtx")

# ==============================================================================
# PIPELINE
# ==============================================================================
#
# Script                           | Purpose                          | Key Inputs                   | Key Outputs
# ---------------------------------|----------------------------------|------------------------------|-------------------------------------------
# 00_2_check_environment.R         | Validate conda, Python, API key  | env_name, api_provider       | gpu_status (variable)
# 00_3_Check_Local_Models.R        | Check Ollama & local models      | model_id                     | (validation only)
# 00_4_setup_dashboard.R           | Google Sheets auth & logging     | dashboard_sheet, dashboard_tab| log_to_dashboard() function
# 01_1_discover_XML_articles.R     | Find .xml files in input folder  | INPUT_DIR                    | xml_files (vector), n_articles
# 01_2_discover_R_Articles.R       | Load articles from .rds objects  | INPUT_FILE                   | article_keys, articles_data, n_articles
# 02_select_prompt.R               | Load & preview the prompt file   | prompt_file                  | prompt_text (character string)
# 03a_run_analysis_api.R           | Send each paper to API LLM       | article data, prompt_text    | results_list, .json files, errors_log
# 03b_run_analysis_local.R         | Run each paper through Ollama    | article data, prompt_text    | results_list, .json files, errors_log
# 03c_build_batch_jsonl.R          | Build JSONL for batch submission  | article data, prompt_text    | JSONL files, batch_manifest.rds
# 03d_submit_batch.R               | Submit one JSONL chunk to batch API| JSONL file, batch_manifest   | batch_output JSONL, job metadata
# 03e_parse_batch_results.R        | Parse batch outputs into RDS      | batch_output JSONLs, manifest| results_list, .json files, errors_log
# 04_generate_summary.R            | Write a human-readable report    | results_list, project_name   | {project_name}_summary.txt
# 05_post_processing.R             | Flatten nested JSON to CSV       | results_list, table_config   | 3 CSV files (main/metadata/detail)
#
# ==============================================================================


# ==============================================================================
# LOAD TABLE / PROMPT CONFIG (YAML)
# ==============================================================================
# The YAML config drives table routing (post-processing) AND prompt-specific
# logic like relevance gating and dashboard fields. Load it once here so every
# downstream script can use it without re-reading.
# ==============================================================================

config_path <- here(table_config_file)
if (file.exists(config_path)) {
  table_config <- yaml::read_yaml(config_path)
  cat(sprintf("  [OK] Loaded prompt config: %s\n", table_config_file))
} else {
  cat(sprintf("  [WARN] Config file not found: %s — using defaults.\n", table_config_file))
  table_config <- list(main = character(0), metadata = character(0), detail = character(0),
                        skip_if_false = character(0), dashboard_critique_fields = character(0))
}

# Ensure all expected sections exist (backwards-compatible with old YAML files)
if (is.null(table_config$skip_if_false))            table_config$skip_if_false            <- character(0)
if (is.null(table_config$dashboard_critique_fields)) table_config$dashboard_critique_fields <- character(0)

# ---- Helper: resolve a dot-separated path in a nested list ----
# e.g., resolve_field(result, "relevance_check.examines_psychopathology")
# Returns NULL if any part of the path is missing or not a list.
resolve_field <- function(obj, path) {
  parts <- strsplit(path, ".", fixed = TRUE)[[1]]
  current <- obj
  for (p in parts) {
    if (!is.list(current) || is.null(current[[p]])) return(NULL)
    current <- current[[p]]
  }
  current
}

# ---- Helper: determine article status from LLM response ----
# Uses skip_if_false from the YAML config instead of hardcoded field names.
determine_status <- function(api_result, skip_fields) {
  tryCatch({
    # Check for API error first
    if (!is.null(api_result$error)) return("API_ERROR")

    # Check relevance gates from config
    if (is.list(api_result) && length(skip_fields) > 0) {
      for (field_path in skip_fields) {
        val <- resolve_field(api_result, field_path)
        if (isFALSE(val)) return("SKIPPED_IRRELEVANT")
      }
    }

    "PROCESSED"
  }, error = function(e) {
    "PROCESSED"
  })
}

########################################################################
########################### Setup ####################################
########################################################################

# ---- Validate batch_mode ----
if (isTRUE(batch_mode) && !api_provider %in% c("gemini", "openai")) {
  stop("batch_mode is currently supported with api_provider = 'gemini' or 'openai'.")
}
if (isTRUE(batch_mode) && execution_mode != "api") {
  stop("batch_mode requires execution_mode = 'api'.")
}

# Step 0.1: Environment check (conda, Python, API key, GPU)
cat("\n========== STEP 0.1: Environment Check ==========\n")
source(here("scripts", "00_2_check_environment.R"))

# Step 0.2: If using local models, check Ollama and model availability
if (execution_mode == "local") {
  cat("\n========== STEP 0.2: Check Local Models ==========\n")
  source(here("scripts", "00_3_Check_Local_Models.R"))
}

# Step 0.3: Dashboard setup (Google Sheets logging, local mode only)
if (dashboard && execution_mode == "local") {
  cat("\n========== STEP 0.3: Dashboard Setup (Google Sheets) ==========\n")
  source(here("scripts", "00_4_setup_dashboard.R"))
}

########################################################################
########################### File setup #################################
########################################################################

# Step 1: Discover articles (XML files or RDS objects)
cat("\n========== STEP 1: Discover Articles ==========\n")
if (input_type == "xml") {
  source(here("scripts", "01_1_discover_XML_articles.R"))
} else if (input_type == "rds") {
  source(here("scripts", "01_2_discover_R_Articles.R"))
} else {
  stop("Unknown input_type: '", input_type, "'. Use 'xml' or 'rds'.")
}

# ---- Apply run_mode subset ----
if (is.numeric(run_mode)) {
  n_subset <- min(as.integer(run_mode), n_articles)
  cat(sprintf("  [RUN MODE] Processing first %d of %d articles.\n", n_subset, n_articles))
  if (input_type == "xml") {
    xml_files  <- xml_files[1:n_subset]
  } else if (input_type == "rds") {
    article_keys  <- article_keys[1:n_subset]
    articles_data <- articles_data[article_keys]
  }
  n_articles <- n_subset
} else if (run_mode == "all") {
  cat(sprintf("  [RUN MODE] Processing all %d articles.\n", n_articles))
} else {
  stop("run_mode must be a number (e.g., 5, 300) or \"all\".")
}

########################################################################
############################ Check Prompt  #############################
########################################################################

# Step 2: Load and validate the prompt
cat("\n========== STEP 2: Select Prompt ==========\n")
source(here("scripts", "02_select_prompt.R"))

########################################################################
#########################    RUN ArticLLMate   #########################
########################################################################

if (execution_mode == "api" && isTRUE(batch_mode)) {
  # Batch mode: build JSONL files only. Student submits manually via 03d, then parses via 03e.
  # See docs/batch_guide.md for the full walkthrough.
  cat("\n========== STEP 3: Build Batch JSONL ==========\n")
  source(here("scripts", "03c_build_batch_jsonl.R"))
  message("\n============================================================")
  message("[BATCH MODE] Pipeline stops here. JSONL files are ready.")
  message("Next steps:")
  message("  1. Run 03d_submit_batch.R for each JSONL chunk")
  message("  2. Run 03e_parse_batch_results.R to combine results")
  message("  3. Then run Steps 4-6 as normal")
  message("See docs/batch_guide.md for the full walkthrough.")
  message("============================================================")
} else if (execution_mode == "api") {
  cat("\n========== STEP 3: API Analysis Loop ==========\n")
  source(here("scripts", "03a_run_analysis_api.R"))
} else if (execution_mode == "local") {
  cat("\n========== STEP 3: Local Analysis Loop (Ollama) ==========\n")
  source(here("scripts", "03b_run_analysis_local.R"))
} else {
  stop("Unknown execution_mode: '", execution_mode, "'. Use 'api' or 'local'.")
}

########################################################################
#######################    Post  Production   ##########################
########################################################################
# Batch JSONL build stops here — Steps 4-6 require completed analysis results.
# Run 03d → 03e first, then source Steps 4-6 manually (or re-run the pipeline).
if (!(execution_mode == "api" && isTRUE(batch_mode))) {

  # Step 4: Generate summary report
  cat("\n========== STEP 4: Summary Report ==========\n")
  source(here("scripts", "04_generate_summary.R"))

  # Step 5: Post-processing (flatten results to CSV)
  cat("\n========== STEP 5: Post-Processing ==========\n")
  source(here("scripts", "05_post_processing.R"))

  # Step 6: Build results R object (RDS input only)
  cat("\n========== STEP 6: Build Results Object ==========\n")
  source(here("scripts", "06_build_results_object.R"))

  # ==============================================================================
  # DONE
  # ==============================================================================
  cat("\n========================================\n")
  cat("Pipeline complete. Results in:", OUTPUT_DIR, "\n")
  cat("========================================\n")
}
