# ==============================================================================
# SCRIPT 01: PHASE 1 HARVESTER (PILOT RUN)
# ==============================================================================
# PURPOSE:  Run "Guided Open Coding" on a random sample of papers.
#           It extracts WHY authors use specific approaches, tagged by type.
# AUTHOR:   [Your Name]
# ==============================================================================

# 1. SETUP & CONFIGURATION
# ------------------------------------------------------------------------------
library(here)
library(tidyverse)
library(reticulate)
library(jsonlite)
library(tictoc) # For easy timing

# --- USER INPUTS ---
N_PILOT_SIZE <- 100   # How many articles to analyze?
SAVE_INTERVAL <- 10    # Save backup every X papers
MODEL_ID <- "gpt-4.1-mini"   # Cost-efficient but smart enough for extraction


# --- PYTHON SETUP ---
# Ensure Python is loaded (assuming _MASTER_RUN_PIPELINE.R set the path)
if (!py_available()) {
  stop("Python not initialized. Run this from the Master Pipeline or set RETICULATE_PYTHON.")
}

# Import Python libraries
openai <- import("openai")
client <- openai$OpenAI(api_key = Sys.getenv("OPENAI_API_KEY"))

# 2. DEFINITIONS & PROMPT CONSTRUCTION
# ------------------------------------------------------------------------------
# We define the taxonomy strictly here so the model knows exactly what to look for.

HARVESTER_SYSTEM_PROMPT <- "
You are an expert academic auditor specializing in Psychopathology (DSM, ICD, HiTOP, RDoC).

### PART 1: TAXONOMY DEFINITIONS (What to look for)
Use these strict definitions to identify approaches. 
**CRITICAL:** Only flag these indicators if they refer to the **nature of the psychopathology itself**, not study conditions (e.g., comparing 'Treatment A vs. Treatment B' is NOT a categorical view of disorder).

#### CATEGORICAL INDICATORS
* **Methodological:** Dichotomization of continuous variables; Extreme-group sampling (Cases vs Controls); Inclusion based on strict diagnostic criteria. (Implies one cannot understand clinical groups by studying non-clinical groups, or vice versa).
* **Statistical:** Group comparison (ANOVA, t-test); Latent Class Analysis interpreted as 'natural kinds'; Odds ratios. (Note: These must be applied between subgroups of the same psychopathology—e.g., 'Depressed vs. Non-Depressed'—not between intervention arms).
* **Conceptual:** Group essentialism (qualitatively distinct types); Discrete terminology ('taxon', 'caseness'); Etiological discreteness. (Implies that factors influencing one range of theta/severity are completely different from those influencing another range).

#### DIMENSIONAL INDICATORS
* **Methodological:** Continuous measurement without cutoffs; Full-range/Community sampling; Gradient analysis.
* **Statistical:** Correlation/Regression; SEM/CFA; Item Response Theory (IRT); Bifactor models (p-factor).
* **Conceptual:** Spectrum/Continuum terminology ('degree', 'severity'); Comorbidity as shared variance. (Noting that all ranges on theta differ only by degree, not by kind).

### PART 2: THEME TYPES (How to classify the rationale)
When an author explains WHY they chose an approach, classify the reason as:
  
  * **CONCEPTUAL (Truth):** Reasons based on scientific validity or the nature of reality.
* *Example:* 'Depression is taxometrically dimensional,' 'Biomarkers show discrete clustering.'
* **PRAGMATIC (Utility):** Reasons based on practical constraints, tools, or clinical needs.
* *Example:* 'Required for insurance coding,' 'Easier to communicate with patients,' 'Easier to analyze statistically when categorized.'
* **INERTIA (Tradition):** Reasons based on consistency or habit.
* *Example:* 'To ensure comparability with previous studies,' 'Standard practice in this field,' 'No justification provided.'

### YOUR TASK
1. **Relevance Check:** Does this paper examine psychopathology? If NO, return relevance=false.
2. **Scan for Rationales:** Read the entire text. Look for **every distinct instance** where authors justify their choice of framework.
- **Distinguish Reason from Method:** Do not just list *that* they used ANOVA (Method). Explain *why* they said they used it (Rationale). If they give no reason, classify as 'Inertia' with label 'Implicit/No Justification', however, you can look past direct statements to the context of the whole article as to why they made or chose particular decisions.
3. **Extraction:** Return an array of **ALL** distinct themes found. Do not stop after the first one.
- **Label:** Create a concise, specific label (3-7 words).
- **Type:** Tag as Conceptual, Pragmatic, or Inertia.
- **Quote:** Extract the supporting fragment.

### OUTPUT FORMAT
Return valid JSON only.

{
  \"relevance_check\": {
    \"is_relevant\": true,
    \"reason\": \"...\"
  },
  \"extracted_themes\": [
    {
      \"framework\": \"categorical | dimensional\",
      \"theme_label\": \"string (e.g. 'Required for billing')\",
      \"theme_type\": \"conceptual | pragmatic | inertia\",
      \"quote\": \"string\"
    },
    {
      \"framework\": \"dimensional\",
      \"theme_label\": \"string (e.g. 'Captures subthreshold variance')\",
      \"theme_type\": \"conceptual\",
      \"quote\": \"string\"
    }
  ]
}
"  

# 3. PYTHON API FUNCTION
# ------------------------------------------------------------------------------
# Define the function to handle the API call safely
py_run_string("
import json
from openai import OpenAI

def analyze_paper_pilot(text_content, system_prompt, model_id):
    client = OpenAI()
    try:
        response = client.chat.completions.create(
            model=model_id,
            messages=[
                {'role': 'system', 'content': system_prompt},
                {'role': 'user', 'content': f'Analyze this text: {text_content}'} # no truncation for now
            ],
            response_format={'type': 'json_object'},
            temperature=0.1 # Low temp for consistency
        )
        return json.loads(response.choices[0].message.content)
    except Exception as e:
        return {'error': str(e)}
")

# 4. FILE SELECTION & LOOP
# ------------------------------------------------------------------------------
# Get all files
all_files <- list.files(INPUT_DIR, pattern = "\\.xml$|\\.txt$", full.names = TRUE)

# Randomly sample N files
set.seed(42) # For reproducibility
if (length(all_files) > N_PILOT_SIZE) {
  pilot_files <- sample(all_files, N_PILOT_SIZE)
} else {
  pilot_files <- all_files
}

cat(sprintf("\nStarting Pilot Run on %d files using %s...\n", length(pilot_files), MODEL_ID))

results_list <- list()
tic("Total Pilot Run") # Start global timer

# Progress Bar
pb <- txtProgressBar(min = 0, max = length(pilot_files), style = 3)

for (i in seq_along(pilot_files)) {
  
  file_path <- pilot_files[i]
  file_name <- basename(file_path)
  start_time <- Sys.time()
  
  # A. Read Text
  # -------------------------------------------------
  text_content <- tryCatch({
    readChar(file_path, file.info(file_path)$size)
  }, error = function(e) NA)
  
  # B. Call API (If text is valid)
  # -------------------------------------------------
  if (!is.na(text_content)) {
    api_result <- py$analyze_paper_pilot(text_content, HARVESTER_SYSTEM_PROMPT, MODEL_ID)
    
    # Check for API Error
    if (!is.null(api_result$error)) {
      status <- "API_ERROR"
    } 
    # Check Relevance
    else if (isFALSE(api_result$relevance_check$is_relevant)) {
      status <- "SKIPPED_IRRELEVANT"
    } 
    # Success
    else {
      status <- "PROCESSED"
    }
    
    # Append Metadata
    api_result$filename <- file_name
    api_result$status <- status
    results_list[[i]] <- api_result
    
  } else {
    status <- "READ_ERROR"
    results_list[[i]] <- list(filename = file_name, status = "READ_ERROR")
  }
  
  # C. Timing & Logging
  # -------------------------------------------------
  end_time <- Sys.time()
  duration <- round(difftime(end_time, start_time, units = "secs"), 2)
  
  # Update progress bar
  setTxtProgressBar(pb, i)
  
  # D. Periodic Save (Safety Net)
  # -------------------------------------------------
  if (i %% SAVE_INTERVAL == 0) {
    save_path <- file.path(OUTPUT_DIR, paste0("partial_results_", i, ".json"))
    write_json(results_list, save_path, auto_unbox = TRUE, pretty = TRUE)
    
    # Print a mini status update
    cat(sprintf("\n[Batch %d] Last file: %s (%s sec) | Status: %s", 
                i, file_name, duration, status))
  }
}

close(pb)
toc() # End global timer


# 5. FINAL DATA PROCESSING (FLATTEN TO CSV)
# ------------------------------------------------------------------------------
cat("\nRun Complete. Flattening data for Analysis...\n")

# Convert the complex list into a tidy dataframe for Phase 1.2
# We only want the extracted themes from RELEVANT papers! so we can remove the null ones from psychopathology earlier. 

final_df <- map_df(results_list, function(item) {
  
  # Skip if irrelevant or error
  if (is.null(item$status) || item$status != "PROCESSED") return(NULL)
  if (is.null(item$extracted_themes) || length(item$extracted_themes) == 0) return(NULL)
  
  # Extract themes
  themes <- item$extracted_themes
  
  # Bind into a dataframe
  map_df(themes, function(t) {
    data.frame(
      filename    = item$filename,
      framework   = t$framework,
      theme_label = t$theme_label,
      theme_type  = t$theme_type,
      quote       = t$quote,
      stringsAsFactors = FALSE
    )
  })
})

# Save the master CSV
csv_path <- file.path(OUTPUT_DIR, "phase1_raw_themes.csv")
write_csv(final_df, csv_path)

cat(sprintf("\nSUCCESS: Extracted %d themes from %d relevant papers.\nSaved to: %s\n", 
            nrow(final_df), length(unique(final_df$filename)), csv_path))