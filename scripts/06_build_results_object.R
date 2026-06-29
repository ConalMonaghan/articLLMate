# ==============================================================================
# STEP 6: BUILD RESULTS R OBJECT
# ==============================================================================
# PURPOSE:  Create an output R object that mirrors the input structure but
#           includes the LLM results for each processed article.
#           Only includes articles that were successfully processed.
#
#           Output structure per article:
#             results_obj$`DOI`$XML$Title
#             results_obj$`DOI`$XML$DOI
#             results_obj$`DOI`$XML$Text
#             results_obj$`DOI`$EXTRACTED_DOI
#             results_obj$`DOI`$META
#             results_obj$`DOI`$RESULTS       <- LLM output (parsed JSON)
#
# EXPECTS FROM MASTER:
#   input_type = "rds" → articles_data, article_keys
#   Always: project_results (from Step 3), OUTPUT_DIR, project_name
#
# CREATES: {project_name}_full_results.rds
# ==============================================================================

cat("Building results R object...\n")

if (input_type != "rds") {
  cat("  [SKIP] Results object only built for RDS input. Skipping.\n")
} else {

  # Build output object: only include articles that were processed
  output_obj <- list()
  n_attached <- 0

  for (key in names(project_results)) {

    result <- project_results[[key]]

    # Only include articles that were actually processed (not errors/empty)
    if (!is.null(result$status) && result$status %in% c("PROCESSED", "SKIPPED_IRRELEVANT")) {

      # Copy original article data if available
      if (!is.null(articles_data[[key]])) {
        output_obj[[key]] <- articles_data[[key]]
      } else {
        # Fallback: create a minimal entry
        output_obj[[key]] <- list()
      }

      # Attach LLM results
      output_obj[[key]]$RESULTS <- result
      n_attached <- n_attached + 1
    }
  }

  # Save
  output_path <- file.path(OUTPUT_DIR, paste0(project_name, "_full_results.rds"))
  saveRDS(output_obj, output_path)

  cat(sprintf("  [OK] Results object: %d articles with LLM results attached.\n", n_attached))
  cat(sprintf("  [OK] Saved to: %s\n", output_path))
  cat(sprintf("  Access example: obj$`%s`$RESULTS\n", names(output_obj)[1]))
}

cat("Results object complete.\n")
