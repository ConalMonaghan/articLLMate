# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================


# This takes xml files and changes them to R object. Puts in placeholder for metadata


# Set the publisher name dynamically
publisher_name <- "Elsevier"

# Absolute path to your XML folder on Mac
input_folder <- "path/to/your/xml/folder"

# Absolute path for where you want to save the final R object (.rds file)
output_file <- "path/to/your/output/Articles.rds"

# Autosave frequency
autosave_frequency <- 1000

# ==============================================================================
# 2. INITIALIZATION
# ==============================================================================

# Create the blank object and initialize the publisher list
articles_obj <- list()
articles_obj[[publisher_name]] <- list()

# Find all XML files in the directory
xml_files <- list.files(path = input_folder, pattern = "\\.xml$", full.names = TRUE, recursive = TRUE)

cat("Found", length(xml_files), "XML files in the", publisher_name, "folder. Starting extraction...\n")

# Initialize progress bar
pb <- txtProgressBar(min = 0, max = length(xml_files), style = 3)

# ==============================================================================
# 3. EXTRACTION LOOP
# ==============================================================================

for (i in seq_along(xml_files)) {
  
  file_path <- xml_files[i]
  
  # --- Step A: Reconstruct the DOI from the filename/path ---
  # This extracts just the filename or relative folder structure after your base input_folder
  relative_path <- sub(paste0("^", input_folder, "/?"), "", file_path)
  
  # Remove the .xml extension
  doi <- sub("\\.xml$", "", relative_path)
  
  # If the DOIs were saved with underscores instead of slashes (e.g., 10.1016_j.chiabu...), 
  # uncomment the line below to convert them back to standard DOI format:
  # doi <- gsub("_", "/", doi)
  
  # --- Step B: Read the XML Text Locally ---
  xml_text <- tryCatch({
    paste(readLines(file_path, warn = FALSE), collapse = "\n")
  }, error = function(e) NA)
  
  # --- Step C: Add to Object ---
  # Structure: articles_obj$Elsevier$`10.1016/...`$XML$Text etc.
  # Matches the pipeline's expected format (same as "Clean" objects)
  articles_obj[[publisher_name]][[doi]] <- list(
    XML = list(
      Title = NA_character_,
      DOI   = doi,
      Text  = xml_text
    ),
    EXTRACTED_DOI = doi,
    META = NULL
  )
  
  # Update progress bar
  setTxtProgressBar(pb, i)
  
  # --- Step D: Autosave ---
  if (i %% autosave_frequency == 0) {
    saveRDS(articles_obj, file = output_file)
  }
}

close(pb)

# Final Save
saveRDS(articles_obj, file = output_file)
cat("\nProcess complete! Object saved to:\n", output_file, "\n")