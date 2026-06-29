# Load required packages
library(xml2)

# ==============================================================================
# 1. USER CONFIGURATION
# ==============================================================================
# The exact path to the existing R object you want to slim down
input_rds_path <- "path/to/your/Publisher_Full.rds"

# Where you want the new, lightweight object to be saved
output_folder <- "path/to/your/output/folder"

# The name of the new R object that will be created
output_object_name <- "Wiley_Clean"

# Create output directory if it doesn't exist
if (!dir.exists(output_folder)) dir.create(output_folder, recursive = TRUE)
save_path <- file.path(output_folder, paste0(output_object_name, ".rds"))

# ==============================================================================
# 2. INITIALIZATION & DATA LOADING
# ==============================================================================
cat("Loading database from:", input_rds_path, "...\n")
db <- readRDS(input_rds_path)
article_keys <- names(db)
total_articles <- length(article_keys)

cat("Successfully loaded", total_articles, "articles. Starting extraction...\n")

# Tracking variables
error_count <- 0
error_log <- character()
pb <- txtProgressBar(min = 0, max = total_articles, style = 3)

# Start the stopwatch
start_time <- Sys.time()

# ==============================================================================
# 3. EXTRACTION LOOP
# ==============================================================================
for (i in seq_along(article_keys)) {
  key <- article_keys[i]
  raw_xml <- db[[key]]$XML
  
  # Initialize empty targets in case the XML is missing or fails
  ext_title <- NA_character_
  ext_doi <- NA_character_
  ext_body <- NA_character_
  
  # Only attempt extraction if we actually have XML text
  if (!is.na(raw_xml) && !is.null(raw_xml) && nchar(raw_xml) > 10) {
    
    # tryCatch prevents a single corrupt XML string from crashing the loop
    tryCatch({
      doc <- read_xml(raw_xml)
      xml_ns_strip(doc) # Strip namespace to make XPath work smoothly
      
      # Extract Title
      title_node <- xml_find_first(doc, "//titleStmt/title[@type='main']")
      if (!is.na(title_node)) ext_title <- xml_text(title_node)
      
      # Extract DOI (from the Grobid header)
      doi_node <- xml_find_first(doc, "//sourceDesc/biblStruct/idno[@type='DOI']")
      if (!is.na(doi_node)) ext_doi <- xml_text(doi_node)
      
      # Extract Body Text (grabs all paragraph nodes in the body and pastes them together)
      body_nodes <- xml_find_all(doc, "//text/body//p")
      if (length(body_nodes) > 0) {
        ext_body <- paste(xml_text(body_nodes), collapse = "\n\n")
      }
      
    }, error = function(e) {
      # If extraction fails, log it and move on
      error_count <<- error_count + 1
      error_log <<- c(error_log, paste("Error on key:", key, "-", e$message))
    })
  }
  
  # OVERWRITE the massive XML string with our clean, lightweight list
  db[[key]]$XML <- list(
    Title = ext_title,
    DOI = ext_doi,
    Text = ext_body
  )
  
  setTxtProgressBar(pb, i)
}

close(pb)

# Stop the stopwatch
end_time <- Sys.time()
total_duration <- as.numeric(difftime(end_time, start_time, units = "secs"))
time_per_article <- total_duration / total_articles

# ==============================================================================
# 4. FINALIZATION & STATS
# ==============================================================================
# Assign the slimmed database to the new name and save it
assign(output_object_name, db)
saveRDS(db, file = save_path)

cat("\n\n--- EXTRACTION STATISTICS ---\n")
cat("Total articles processed: ", total_articles, "\n")
cat("Total time elapsed:       ", round(total_duration, 2), "seconds\n")
cat("Average time per article: ", round(time_per_article, 4), "seconds\n")
cat("Total parsing errors:     ", error_count, "\n")

if (error_count > 0) {
  cat("\nFirst 5 errors:\n")
  print(head(error_log, 5))
}

cat("\nSuccess! Cleaned object saved to:", save_path, "\n")