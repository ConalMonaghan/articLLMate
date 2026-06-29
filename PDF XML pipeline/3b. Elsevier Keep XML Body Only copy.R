library(xml2)


# ==============================================================================
# 1. USER CONFIGURATION
# ==============================================================================

input_rds_path     <- "path/to/your/Publisher_Full.rds"
output_folder      <- "path/to/your/output/folder"
output_object_name <- "Elsevier_Clean"

if (!dir.exists(output_folder)) dir.create(output_folder, recursive = TRUE)
save_path <- file.path(output_folder, paste0(output_object_name, ".rds"))


# ==============================================================================
# 2. INITIALISATION & DATA LOADING
# ==============================================================================

cat("Loading database from:", input_rds_path, "...\n")
db             <- readRDS(input_rds_path)
article_keys   <- names(db)
total_articles <- length(article_keys)
cat("Successfully loaded", total_articles, "articles. Starting extraction...\n")

error_count <- 0
error_log   <- character()
pb          <- txtProgressBar(min = 0, max = total_articles, style = 3)
start_time  <- Sys.time()


# ==============================================================================
# 3. EXTRACTION LOOP
# ==============================================================================

for (i in seq_along(article_keys)) {
  key     <- article_keys[i]
  raw_xml <- db[[key]]$XML

  # Initialise empty targets in case the XML is missing or fails
  ext_title    <- NA_character_
  ext_doi      <- NA_character_
  ext_abstract <- NA_character_
  ext_body     <- NA_character_

  # ------------------------------------------------------------------------------
  # DOI: already stored from the filename-based extraction step — no need to
  # re-parse the XML for it. Pull directly from the stored field.
  # ------------------------------------------------------------------------------
  ext_doi <- db[[key]]$EXTRACTED_DOI

  # Only attempt XML extraction if we actually have XML text
  if (!is.null(raw_xml) && !is.na(raw_xml) && nchar(raw_xml) > 10) {

    tryCatch({
      doc <- read_xml(raw_xml)

      # ------------------------------------------------------------------------------
      # Extract the namespace map from the document itself.
      # xml_ns_strip() fails on these Elsevier files — they have 170+ namespace
      # declarations that libxml2 cannot reliably collapse. We pass ns explicitly
      # to every xml_find_* call instead.
      # ------------------------------------------------------------------------------
      ns <- xml_ns(doc)

      # ------------------------------------------------------------------------------
      # Extract Title
      # Elsevier stores the title in <dc:title> (Dublin Core namespace)
      # ------------------------------------------------------------------------------
      title_node <- xml_find_first(doc, "//dc:title", ns)
      if (!is.na(title_node)) ext_title <- trimws(xml_text(title_node))

      # ------------------------------------------------------------------------------
      # Extract Abstract
      # Elsevier stores the abstract in <dc:description> (Dublin Core namespace)
      # ------------------------------------------------------------------------------
      abstract_node <- xml_find_first(doc, "//dc:description", ns)
      if (!is.na(abstract_node)) ext_abstract <- trimws(xml_text(abstract_node))

      # ------------------------------------------------------------------------------
      # Extract Body Text
      # Body paragraphs use the <ce:para> element (Elsevier common DTD namespace).
      # This naturally excludes reference entries (<sb:*>) and table cells,
      # targeting only paragraph-level prose.
      # ------------------------------------------------------------------------------
      body_nodes <- xml_find_all(doc, "//ce:para", ns)
      if (length(body_nodes) > 0) {
        ext_body <- paste(trimws(xml_text(body_nodes)), collapse = "\n\n")
      }

    }, error = function(e) {
      error_count <<- error_count + 1
      error_log   <<- c(error_log, paste("Error on key:", key, "-", e$message))
    })
  }

  # Overwrite the massive raw XML string with our clean, lightweight list
  db[[key]]$XML <- list(
    Title    = ext_title,
    DOI      = ext_doi,
    Abstract = ext_abstract,
    Text     = ext_body
  )

  setTxtProgressBar(pb, i)
}

close(pb)

end_time         <- Sys.time()
total_duration   <- as.numeric(difftime(end_time, start_time, units = "secs"))
time_per_article <- total_duration / total_articles


# ==============================================================================
# 4. FINALISATION & STATS
# ==============================================================================

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