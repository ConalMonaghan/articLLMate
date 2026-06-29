# Set BEFORE loading reticulate
# Sys.setenv(RETICULATE_PYTHON = "path/to/your/python")  # Set if not using conda

library(usethis)
library(reticulate)
library(here)
library(readr)
library(dotenv) # to read system key

# Check Python is available
if (!py_available(initialize = TRUE)) {
  stop("Python not available - check RETICULATE_PYTHON path")
}
# OpenAI Configuration
load_dot_env()
openai <- import("openai")
client <- openai$OpenAI(api_key = Sys.getenv("OPENAI_API_KEY"))

py_config()

# If not installed. 
#reticulate::py_install(c("numpy", "openai"),
#                       pip = TRUE,
#                       python = "path/to/your/python")

# 5. Create Output Directories
dir.create(here("output"), showWarnings = FALSE)

# 6. List Files
files <- list.files(here("Test xml files"), pattern = "\\.xml$", full.names = TRUE)

# Display files found
cat("\n=== INITIALIZATION ===\n")
cat(sprintf("Found %d XML files to process:\n", length(files)))
for (f in files) {
  cat(sprintf("  - %s\n", basename(f)))
}
cat("\n")

## This should list all of the files to analyse 

#-------Define Inputs-----------------# 

# A. Define Models 
# (You decide the specific model IDs here. Ensure they match OpenAI API names)
models <- list(
  "Model_High"   = "gpt-5.1",      # Replace with your desired high-end model
  "Model_Medium" = "gpt-5-mini",    # Replace with your desired mid-range model
  "Model_Mini"   = "gpt-4.1-nano"       # Replace with your desired mini model
)

# Load single prompt
prompt_file <- here("prompts", "prompt")
prompt_text <- readChar(prompt_file, file.info(prompt_file)$size)

# Initialize results
all_results <- data.frame()

# Loop through Models and Files only
for (m_name in names(models)) {
  current_model_id <- models[[m_name]]
  
  for (f in files) {
    file_name <- basename(f)
    cat(sprintf("Processing: [%s] | Model: [%s]\n", file_name, m_name))
    
    # Read file
    txt <- readChar(f, file.info(f)$size)
    
    # Construct prompt
    final_user_message <- sprintf(
      paste0(
        "%s\n",
        "-------------------------\n\n",
        "Here is the paper you will analyse: %s"
      ),
      prompt_text,
      txt
    )
    
    # Call API
    output_text <- tryCatch({
      resp <- client$chat$completions$create(
        model = current_model_id,
        messages = list(list(role = "user", content = final_user_message))
      )
      resp$choices[[1]]$message$content
    }, error = function(e) {
      message(paste("Error processing", file_name, ":", e$message))
      "ERROR_API_FAILURE"
    })
    
    # Print output to console
    cat("\n--- Output ---\n")
    cat(output_text)
    cat("\n--------------\n\n")
    
    # Save individual file
    out_name <- paste0(m_name, "_", tools::file_path_sans_ext(file_name), ".txt")
    writeLines(output_text, here("output", out_name))
    
    # Append to results
    all_results <- rbind(all_results, data.frame(
      File_Name = file_name,
      Model_Label = m_name,
      Model_ID = current_model_id,
      Output = output_text,
      Timestamp = Sys.time(),
      stringsAsFactors = FALSE
    ))
    
    Sys.sleep(0.5)
  }
}

# Save CSV
write_csv(all_results, here("output", "full_benchmark_results.csv"))

# Summary
cat("\n=== COMPLETE ===\n")
cat(sprintf("Files processed: %d\n", length(files)))
cat(sprintf("Models used: %d\n", length(models)))
cat(sprintf("Total outputs: %d\n", nrow(all_results)))