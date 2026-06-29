# Load required packages
library(xml2)
library(purrr)
library(rcrossref)

## For Mac, I installed CRoss-ref via remotes. 

# First, install the 'remotes' package if you don't have it
#install.packages("remotes")

# Then install rcrossref from GitHub
#remotes::install_github("ropensci/rcrossref")

# ==============================================================================
# 1. USER CONFIGURATION
# ==============================================================================

input_folder        <- "path/to/your/xml/folder"
output_folder       <- "path/to/your/output/robj/folder"
output_object_name  <- "Elsevier_Full"
user_email          <- Sys.getenv("CROSSREF_EMAIL", unset = "your.email@example.com")
autosave_frequency  <- 100

# Attach your email to the environment for rcrossref
Sys.setenv(crossref_email = user_email)

# Setup output paths
if (!dir.exists(output_folder)) dir.create(output_folder, recursive = TRUE)
file_path <- file.path(output_folder, paste0(output_object_name, ".rds"))


# ==============================================================================
# 2. INITIALISATION
# ==============================================================================

# Elsevier files use plain .xml (not .tei.xml)
xml_files      <- list.files(input_folder, pattern = "\\.xml$", full.names = TRUE)
total_articles <- length(xml_files)

if (total_articles == 0) stop("No XML files found! Check the input_folder path.")

if (file.exists(file_path)) {
  temp_db <- readRDS(file_path)
  cat("Loaded existing database with", length(temp_db), "records.\n")
} else {
  temp_db <- list()
  cat("Starting fresh database.\n")
}

cat("Processing", total_articles, "files using filename-based DOI extraction...\n")
pb <- txtProgressBar(min = 0, max = total_articles, style = 3)


# ==============================================================================
# 3. EXTRACTION LOOP
# ==============================================================================

for (i in seq_along(xml_files)) {
  current_file <- xml_files[i]
  
  # Use the bare filename (minus .xml) as the list key
  list_key <- sub("\\.xml$", "", basename(current_file))
  
  # Checkpoint: skip if already successfully processed
  if (!is.null(temp_db[[list_key]]$META) && !is.null(temp_db[[list_key]]$XML)) {
    setTxtProgressBar(pb, i)
    next
  }
  
  # Derive DOI from filename:
  # e.g. 10.1016_j.chiabu.2014.03.006.xml -> 10.1016/j.chiabu.2014.03.006
  # Only the first underscore (separating registrant from suffix) becomes a /
  extracted_doi <- sub("^(\\d+\\.\\d+)_", "\\1/", list_key)
  
  # Read and store XML content
  doc        <- tryCatch(read_xml(current_file), error = function(e) NULL)
  xml_string <- if (!is.null(doc)) as.character(doc) else NA
  meta       <- list()
  
  # Hit Crossref with the filename-derived DOI
  if (!is.na(extracted_doi) && extracted_doi != "") {
    safe_cr <- safely(cr_works)(extracted_doi)
    if (!is.null(safe_cr$result)) {
      meta <- safe_cr$result$data
    }
  }
  
  # Store in the database
  temp_db[[list_key]] <- list(
    XML           = xml_string,
    EXTRACTED_DOI = extracted_doi,  # Filename-derived DOI for verification
    META          = meta
  )
  
  Sys.sleep(0.1)
  setTxtProgressBar(pb, i)
  
  if (i %% autosave_frequency == 0) saveRDS(temp_db, file = file_path)
}

close(pb)

# Final save
assign(output_object_name, temp_db)
saveRDS(temp_db, file = file_path)


# ==============================================================================
# 4. DIAGNOSTICS & COUNTING
# ==============================================================================

cat("\n\n--- EXTRACTION RESULTS ---\n")
cat("Total files processed:", length(temp_db), "\n")

success_count <- sum(sapply(temp_db, function(x) length(x$META) > 0))
cat("Successful API pulls (Metadata Found):", success_count, "\n")

error_count <- sum(sapply(temp_db, function(x) length(x$META) == 0))
cat("Missing Metadata (No DOI or Crossref failed):", error_count, "\n\n")

cat("--- PREVIEW OF FIRST 5 SUCCESSFUL METADATA ENTRIES ---\n")

# Filter to successful entries only
successful_entries <- temp_db[sapply(temp_db, function(x) length(x$META) > 0)]

if (length(successful_entries) > 0) {
  preview_count <- min(5, length(successful_entries))
  for (j in 1:preview_count) {
    entry_name <- names(successful_entries)[j]
    cat("\nFile Key:", entry_name, "\n")
    cat("Filename-derived DOI:", successful_entries[[j]]$EXTRACTED_DOI, "\n")
    print(successful_entries[[j]]$META[, intersect(
      names(successful_entries[[j]]$META),
      c("title", "publisher", "container.title", "published.print")
    )])
  }
} else {
  cat("No successful metadata to preview.\n")
}