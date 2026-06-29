# ==============================================================================
# STEP 4: GENERATE SUMMARY REPORT
# ==============================================================================
# PURPOSE:  Create a human-readable summary of the analysis run, including:
#           - Article counts (processed, errors, skipped)
#           - Timing (total and average per article)
#           - System specifications
#           - Error log
#
# EXPECTS FROM MASTER:  results_list, errors_log, timings, total_elapsed_secs,
#                        n_articles, project_name, model_id, api_provider,
#                        prompt_file, OUTPUT_DIR, gpu_status
# ==============================================================================

cat("Generating summary report...\n")

# ---- Compute stats ----
statuses <- sapply(results_list, function(x) if (is.null(x)) "NULL" else x$status)
n_processed  <- sum(statuses == "PROCESSED")
n_errors     <- sum(statuses %in% c("API_ERROR", "READ_ERROR"))
n_skipped    <- sum(statuses == "SKIPPED_IRRELEVANT")
n_null       <- sum(statuses == "NULL")
avg_time     <- if (n_articles > 0) total_elapsed_secs / n_articles else 0

# System info
sys_info  <- Sys.info()
r_version <- R.version$version.string
py_version <- tryCatch(py_config()$version, error = function(e) "unknown")

# ---- Build the report ----
report <- paste0(
  "=== articLLMate Analysis Summary ===\n",
  "Project:        ", project_name, "\n",
  "Date:           ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n",
  "Model:          ", model_id, "\n",
  "Prompt:         ", prompt_file, "\n",
  "API Provider:   ", api_provider, "\n",
  "\n",
  "--- Articles ---\n",
  "Total:          ", n_articles, "\n",
  "Processed:      ", n_processed, "\n",
  "Errors:         ", n_errors, "\n",
  "Skipped:        ", n_skipped, " (not relevant to psychopathology)\n",
  "\n",
  "--- Timing ---\n",
  sprintf("Total Time:     %.1f seconds (%.1f minutes)\n", total_elapsed_secs, total_elapsed_secs / 60),
  sprintf("Avg per Article: %.1f seconds\n", avg_time),
  "\n",
  "--- System ---\n",
  "OS:             ", sys_info["sysname"], " ", sys_info["release"], " (", sys_info["machine"], ")\n",
  "R Version:      ", r_version, "\n",
  "Python:         ", py_version, "\n",
  "GPU:            ", gpu_status, "\n",
  "Node:           ", sys_info["nodename"], "\n",
  "\n",
  "--- Output Files ---\n",
  "Individual JSONs: ", OUTPUT_DIR, "/*.json\n",
  "Results RDS:      ", file.path(OUTPUT_DIR, paste0(project_name, "_results.rds")), "\n",
  "Results CSV:      ", file.path(OUTPUT_DIR, paste0(project_name, "_main.csv")), " (+ _metadata.csv, _detail.csv)\n",
  "This summary:     ", file.path(OUTPUT_DIR, paste0(project_name, "_summary.txt")), "\n"
)

# ---- Error log ----
if (length(errors_log) > 0) {
  report <- paste0(report, "\n--- Errors (", length(errors_log), ") ---\n")
  max_errors_shown <- min(length(errors_log), 20)
  for (j in seq_len(max_errors_shown)) {
    err <- errors_log[[j]]
    report <- paste0(report,
      sprintf("%d. [Article %d] %s: %s\n", j, err$index, err$file, err$error)
    )
  }
  if (length(errors_log) > max_errors_shown) {
    report <- paste0(report,
      sprintf("... and %d more errors (see individual .json files for details)\n",
              length(errors_log) - max_errors_shown))
  }
} else {
  report <- paste0(report, "\n--- Errors ---\nNone. All articles processed successfully.\n")
}

report <- paste0(report, "\n=== End of Summary ===\n")

# ---- Save and display ----
summary_path <- file.path(OUTPUT_DIR, paste0(project_name, "_summary.txt"))
writeLines(report, summary_path)

cat("\n", report, "\n")
cat(sprintf("Summary saved to: %s\n", summary_path))
