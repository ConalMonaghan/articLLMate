# ==============================================================================
# FUNNEL + SUMMARY WRITER
# ==============================================================================
#
# PURPOSE:
# Turn the finalized audit ledger into (a) a stage-by-stage funnel table showing
# how many articles survive each gate and why they drop out (PRISMA-style counts
# without drawing the diagram), and (b) a human-readable run summary in the
# style of the main pipeline's 04_generate_summary.R.
#
# EXPECTS (from the master environment):
#   ledger        - the FINALIZED audit ledger (run ledger_finalize() first)
#   OUTPUT_DIR    - where to write funnel + summary
#   source_batch, run_started_at (optional)
#
# PRODUCES:
#   <OUTPUT_DIR>/preprocess_funnel.csv
#   <OUTPUT_DIR>/preprocess_summary.txt
# ==============================================================================

library(readr)
library(tibble)

# The funnel contains only SEQUENTIAL GATES — stages that actually exclude
# articles — so each step's drop is a genuine loss. DOI detection and Crossref
# metadata are informational (a missing DOI does not by itself exclude an
# article), so they are reported separately below rather than as funnel steps.
build_funnel <- function(ledger) {
  # Cumulative gates. A gate that did not run leaves its column all-NA; we treat
  # NA as "not excluded" so a skipped stage passes everyone through rather than
  # appearing to drop the whole corpus.
  in_xml    <- isTRUE_vec(ledger$xml_created)
  in_parse  <- in_xml   & !(ledger$parse_ok %in% FALSE)
  in_length <- in_parse & !(ledger$length_status %in% c("too_short", "too_long"))
  n_incl    <- sum(ledger$final_status == "included", na.rm = TRUE)

  stages <- c(
    "0. Articles in corpus (starting N)",
    "1. XML produced (GROBID ok)",
    "2. Body parsed OK",
    "3. Within length bounds",
    "4. Final included"
  )
  counts <- c(nrow(ledger), sum(in_xml), sum(in_parse), sum(in_length), n_incl)

  tibble(
    stage   = stages,
    n       = counts,
    dropped = c(NA_integer_, head(counts, -1) - tail(counts, -1))
  )
}

funnel <- build_funnel(ledger)

# ---- Informational metadata counts (not funnel gates) ------------------------
has_doi   <- !is.na(ledger$extracted_doi) & nzchar(ledger$extracted_doi)
info_lines <- c(
  sprintf("  DOI detected:            %6d", sum(has_doi)),
  sprintf("  Crossref metadata found: %6d", sum(isTRUE_vec(ledger$meta_found))),
  sprintf("  DOI corrected (raw!=final):%5d", sum(ledger$doi_match == FALSE, na.rm = TRUE))
)

if (!dir.exists(OUTPUT_DIR)) dir.create(OUTPUT_DIR, recursive = TRUE)
funnel_path  <- file.path(OUTPUT_DIR, "preprocess_funnel.csv")
summary_path <- file.path(OUTPUT_DIR, "preprocess_summary.txt")
write_csv(funnel, funnel_path)

# ---- Exclusion-reason breakdown ----------------------------------------------
excl <- ledger[!is.na(ledger$final_status) & ledger$final_status == "excluded", ]
reason_tbl <- sort(table(excl$exclusion_reason), decreasing = TRUE)

# ---- Write summary text ------------------------------------------------------
lines <- c(
  "=== articLLMate Pre-Processing Audit Summary ===",
  sprintf("Source batch:   %s", source_batch %||% "(unnamed)"),
  sprintf("Date:           %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  if (!is.null(run_started_at)) sprintf("Run started:    %s", run_started_at) else NULL,
  "",
  "--- Funnel ---"
)
for (r in seq_len(nrow(funnel))) {
  drop_str <- if (is.na(funnel$dropped[r])) "" else sprintf("   (-%d)", funnel$dropped[r])
  lines <- c(lines, sprintf("  %-38s %6d%s", funnel$stage[r], funnel$n[r], drop_str))
}
# Flag gates that did not run, so a pass-through count isn't mistaken for a pass.
skipped <- c()
if (all(is.na(ledger$length_status)))  skipped <- c(skipped, "length filter")
if (all(is.na(ledger$parse_ok)))       skipped <- c(skipped, "body extraction")
if (length(skipped) > 0) {
  lines <- c(lines, sprintf("  (note: %s did not run — its gate passes all through)",
                            paste(skipped, collapse = ", ")))
}

lines <- c(lines, "", "--- Metadata (informational) ---", info_lines)

# ---- DOI resolution per step (crossref / regex / claude / unresolved) --------
if ("resolution_method" %in% names(ledger) && any(!is.na(ledger$resolution_method))) {
  step_of <- c(doi_verified = "crossref", doi_supp_fixed = "crossref",
               bibliographic = "crossref", doi_regex_fixed = "regex",
               llm_resolved = "claude", llm_web_search = "claude",
               manual_resolve = "manual_resolve", unresolved = "manual_resolve",
               parse_error = "manual_resolve")
  rstep <- step_of[ledger$resolution_method]
  rstep[is.na(rstep) & !is.na(ledger$resolution_method)] <- "other"
  rtab <- sort(table(rstep[!is.na(rstep)]), decreasing = TRUE)
  lines <- c(lines, "", "--- DOI resolution (per step) ---")
  for (nm in names(rtab)) lines <- c(lines, sprintf("  %-20s %6d", nm, rtab[[nm]]))
}

lines <- c(lines, "", "--- Exclusion reasons ---")
if (length(reason_tbl) > 0) {
  for (nm in names(reason_tbl)) {
    lines <- c(lines, sprintf("  %-30s %6d", nm, reason_tbl[[nm]]))
  }
} else {
  lines <- c(lines, "  (none)")
}
lines <- c(lines, "",
           sprintf("Ledger: %s", file.path(OUTPUT_DIR, "audit_ledger.csv")),
           sprintf("Funnel: %s", funnel_path))

writeLines(lines, summary_path)

cat(paste(lines, collapse = "\n"), "\n")
cat(sprintf("\n  [OK] Funnel written:  %s\n", funnel_path))
cat(sprintf("  [OK] Summary written: %s\n", summary_path))
