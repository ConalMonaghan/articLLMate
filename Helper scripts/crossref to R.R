# Load required packages
library(httr)
library(jsonlite)

# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================

# Your email for the Crossref "Polite Pool" (faster, fewer rate limits)
user_email <- Sys.getenv("CROSSREF_EMAIL", unset = "your.email@example.com")

# The relative location of your saved object
# We use this as both the input to load from, and the output to save over
file_path <- "input/R test/Elsevier Articles.rds"

# How often to save the object to disk (every N articles)
autosave_frequency <- 500

# ==============================================================================
# 2. INITIALIZATION
# ==============================================================================

# Load the object into the environment
Elsevier_Articles <- readRDS(file_path)

publisher_name <- "Elsevier"
article_keys <- names(Elsevier_Articles[[publisher_name]])
total_articles <- length(article_keys)

cat("Loaded", total_articles, "articles. Starting Crossref API pull...\n")

# Initialize progress bar
pb <- txtProgressBar(min = 0, max = total_articles, style = 3)

# ==============================================================================
# 3. API LOOP
# ==============================================================================

for (i in seq_along(article_keys)) {
  
  doi_key <- article_keys[i]
  
  # Check if metadata is already populated (useful if you need to pause/restart)
  if (!is.null(Elsevier_Articles[[publisher_name]][[doi_key]]$metadata)) {
    setTxtProgressBar(pb, i)
    next 
  }
  
  # Fix the DOI format for the API: replace ONLY the first underscore with a slash
  # "10.1016_j.chiabu..." becomes "10.1016/j.chiabu..."
  query_doi <- sub("_", "/", doi_key)
  
  # --- API Call ---
  metadata_result <- tryCatch({
    url <- paste0("https://api.crossref.org/works/", URLencode(query_doi, reserved = TRUE))
    response <- GET(url, user_agent(paste0("mailto:", user_email)))
    
    if (status_code(response) == 200) {
      content(response, as = "parsed", type = "application/json")$message
    } else {
      paste("API Error:", status_code(response))
    }
  }, error = function(e) {
    "Network Error/Timeout"
  })
  
  # Add the metadata into the object
  Elsevier_Articles[[publisher_name]][[doi_key]]$metadata <- metadata_result
  
  # Be polite to the servers (Crossref requests a polite delay)
  Sys.sleep(0.1)
  
  # Update progress bar
  setTxtProgressBar(pb, i)
  
  # --- Autosave ---
  if (i %% autosave_frequency == 0) {
    saveRDS(Elsevier_Articles, file = file_path)
  }
}

close(pb)

# Final Save
saveRDS(Elsevier_Articles, file = file_path)
cat("\nAPI pull complete! Fully updated object saved to:\n", file_path, "\n")