# Load required packages
library(xml2)
library(purrr)
library(rcrossref)


# Done
# APA
# T and F
# Springer
# Sage
# WILEY_Clean

# ==============================================================================
# 1. USER CONFIGURATION
# ==============================================================================
input_folder <- "path/to/your/xml/folder"
output_folder <- "path/to/your/output/robj/folder"
output_object_name <- "Elsevier_Full"
user_email <- Sys.getenv("CROSSREF_EMAIL", unset = "your.email@example.com")
autosave_frequency <- 100

# Attach your email to the environment for rcrossref
Sys.setenv(crossref_email = user_email)

# Setup output paths
if (!dir.exists(output_folder)) dir.create(output_folder, recursive = TRUE)
file_path <- file.path(output_folder, paste0(output_object_name, ".rds"))

# ==============================================================================
# 2. INITIALIZATION
# ==============================================================================
xml_files <- list.files(input_folder, pattern = "\\.tei(\\.xml)?$", full.names = TRUE)
total_articles <- length(xml_files)

if (total_articles == 0) stop("No XML files found! Check the input_folder path.")

if (file.exists(file_path)) {
  temp_db <- readRDS(file_path)
  cat("Loaded existing database with", length(temp_db), "records.\n")
} else {
  temp_db <- list()
  cat("Starting fresh database.\n")
}

cat("Processing", total_articles, "files using XML DOI extraction...\n")
pb <- txtProgressBar(min = 0, max = total_articles, style = 3)

# ==============================================================================
# 3. EXTRACTION LOOP
# ==============================================================================
for (i in seq_along(xml_files)) {
  current_file <- xml_files[i]
  
  # We still use the filename as the main list KEY so we don't lose files without DOIs
  list_key <- sub("\\.grobid\\.tei(\\.xml)?$", "", basename(current_file))
  
  # Checkpoint: Skip if we already successfully pulled this file's data
  if (!is.null(temp_db[[list_key]]$META) && !is.null(temp_db[[list_key]]$XML)) {
    setTxtProgressBar(pb, i)
    next
  }
  
  # Initialize variables for this iteration
  doc <- tryCatch(read_xml(current_file), error = function(e) NULL)
  xml_string <- if (!is.null(doc)) as.character(doc) else NA
  meta <- list()
  extracted_doi <- NA_character_
  
  # If XML is valid, hunt for the DOI
  if (!is.null(doc)) {
    xml_ns_strip(doc)
    doi_node <- xml_find_first(doc, "//idno[@type='DOI']")
    extracted_doi <- if (!is.na(doi_node)) xml_text(doi_node) else NA_character_
    
    # If a DOI is found, hit Crossref
    if (!is.na(extracted_doi) && extracted_doi != "") {
      safe_cr <- safely(cr_works)(extracted_doi)
      if (!is.null(safe_cr$result)) {
        meta <- safe_cr$result$data
      }
    }
  }
  
  # Store in the database
  temp_db[[list_key]] <- list(
    XML = xml_string,
    EXTRACTED_DOI = extracted_doi, # Saving this so you can verify Grobid's work
    META = meta
  )
  
  Sys.sleep(0.1)
  setTxtProgressBar(pb, i)
  
  if (i %% autosave_frequency == 0) saveRDS(temp_db, file = file_path)
}

close(pb)

# Final Save
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
cat("Missing Metadata (No DOI in XML or Crossref failed):", error_count, "\n\n")

cat("--- PREVIEW OF FIRST 5 SUCCESSFUL METADATA ENTRIES ---\n")
# Filter list to only successful entries to avoid printing NULLs
successful_entries <- temp_db[sapply(temp_db, function(x) length(x$META) > 0)]

if (length(successful_entries) > 0) {
  preview_count <- min(5, length(successful_entries))
  for (j in 1:preview_count) {
    entry_name <- names(successful_entries)[j]
    cat("\nFile Key (Accession ID):", entry_name, "\n")
    cat("Grobid Extracted DOI:", successful_entries[[j]]$EXTRACTED_DOI, "\n")
    
    # Print the tibble (rcrossref formats this nicely automatically)
    print(successful_entries[[j]]$META[, intersect(names(successful_entries[[j]]$META), c("title", "publisher", "container.title", "published.print"))])
  }
} else {
  cat("No successful metadata to preview.\n")
}


# about 2.5second per doc. For PDF - xml

###
# APA RUN
# You just successfully rescued 6,547 / 7,642 articles!~85% s
###
# SAGE RUN
# 7,120
# 
# Successful API pulls (Metadata Found): 6155 
# Missing Metadata (No DOI in XML or Crossref failed): 965 

# SPRINGER -- EXTRACTION RESULTS ---
#Total files processed: 3271
#Successful API pulls (Metadata Found): 3262
#Missing Metadata (No DOI in XML or Crossref failed): 9 

### TandF -- EXTRACTION RESULTS ---
#EXTRACTION RESULTS ---
# Total files processed: 6454
# Successful API pulls (Metadata Found): 5899
# Missing Metadata (No DOI in XML or Crossref failed): 555 
