# ==============================================================================
# DC PROMPT — RESULTS ANALYSIS
# ==============================================================================
# PURPOSE:  Validate and explore results from the DC (dimensional/categorical)
#           prompt after a batch run. Accepts a folder of JSON files OR a
#           *_full_results.rds file as input.
#
# USAGE:
#   Set RESULTS_INPUT below, then source() or run section-by-section.
#
#   RESULTS_INPUT can be:
#     - Path to a folder containing individual .json output files
#     - Path to a *_full_results.rds file (from Step 6 of the pipeline)
#
# OUTPUT:
#   Printed tables/summaries in console + optional CSV saved to SAVE_DIR.
# ==============================================================================


# ==== USER INPUT ====

RESULTS_INPUT <- here::here("output", "YOUR_PROJECT_NAME")   # <-- set this
# RESULTS_INPUT <- here::here("output", "my_run_full_results.rds")

SAVE_DIR <- here::here("analysis", "output")   # where to save analysis CSVs


# ==== SETUP ====

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(tidyr)
  library(jsonlite)
  library(stringr)
  library(tibble)
  library(purrr)
})

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b

dir.create(SAVE_DIR, showWarnings = FALSE, recursive = TRUE)

cat("=============================================================\n")
cat(" DC PROMPT — RESULTS ANALYSIS\n")
cat(sprintf(" Input:  %s\n", RESULTS_INPUT))
cat(sprintf(" Saving: %s\n", SAVE_DIR))
cat("=============================================================\n\n")


# ==============================================================================
# SECTION 0: LOAD RESULTS
# ==============================================================================

cat("--- SECTION 0: LOADING DATA ---\n")

results_raw <- list()

if (!file.exists(RESULTS_INPUT)) {
  stop("RESULTS_INPUT not found: ", RESULTS_INPUT)
}

if (dir.exists(RESULTS_INPUT)) {
  # ---- Load from folder of JSON files ----
  json_files <- list.files(RESULTS_INPUT, pattern = "\\.json$",
                           full.names = TRUE, recursive = FALSE)
  # Exclude summary files
  json_files <- json_files[!grepl("_summary|_partial", basename(json_files))]

  cat(sprintf("  Found %d JSON files in: %s\n", length(json_files), RESULTS_INPUT))

  for (f in json_files) {
    tryCatch({
      r <- fromJSON(f, simplifyVector = FALSE)
      if (is.null(r$filename)) r$filename <- tools::file_path_sans_ext(basename(f))
      results_raw[[r$filename]] <- r
    }, error = function(e) {
      cat(sprintf("  [WARN] Could not parse: %s — %s\n", basename(f), e$message))
    })
  }

} else if (grepl("\\.rds$", RESULTS_INPUT, ignore.case = TRUE)) {
  # ---- Load from full_results.rds ----
  obj <- readRDS(RESULTS_INPUT)
  cat(sprintf("  Loaded RDS with %d entries.\n", length(obj)))

  # Handle two possible structures:
  # (a) results_obj$article_id$RESULTS  (from Step 6)
  # (b) flat list of result objects     (from Step 3 results_list)
  if (!is.null(obj[[1]]$RESULTS)) {
    for (key in names(obj)) {
      r <- obj[[key]]$RESULTS
      if (is.null(r$filename)) r$filename <- key
      results_raw[[key]] <- r
    }
  } else {
    results_raw <- obj
    for (key in names(results_raw)) {
      if (is.null(results_raw[[key]]$filename)) results_raw[[key]]$filename <- key
    }
  }

} else {
  stop("RESULTS_INPUT must be a folder of JSONs or a .rds file.")
}

n_total <- length(results_raw)
cat(sprintf("  Total articles loaded: %d\n\n", n_total))

if (n_total == 0) stop("No results loaded. Check RESULTS_INPUT path.")


# ==============================================================================
# SECTION 1: PIPELINE COMPLETION
# ==============================================================================

cat("--- SECTION 1: PIPELINE COMPLETION ---\n")

statuses <- sapply(results_raw, function(r) r$status %||% "UNKNOWN")

status_tbl <- as.data.frame(table(Status = statuses)) %>%
  arrange(desc(Freq)) %>%
  mutate(Pct = sprintf("%.1f%%", Freq / n_total * 100))

print(status_tbl)
cat(sprintf("\n  Total:               %d\n", n_total))
cat(sprintf("  Processed:           %d\n", sum(statuses == "PROCESSED")))
cat(sprintf("  Skipped (irrelevant):%d\n", sum(statuses == "SKIPPED_IRRELEVANT")))
cat(sprintf("  Errors:              %d\n", sum(!statuses %in% c("PROCESSED", "SKIPPED_IRRELEVANT"))))

# Check for articles that returned an error field
n_error_field <- sum(sapply(results_raw, function(r) !is.null(r$error)))
if (n_error_field > 0) {
  cat(sprintf("  [WARN] %d articles contain an 'error' field — review these.\n", n_error_field))
}

# Work only on PROCESSED articles from here
processed <- results_raw[statuses == "PROCESSED"]
n_proc <- length(processed)
cat(sprintf("\n  Working with %d PROCESSED articles for the analyses below.\n\n", n_proc))

if (n_proc == 0) stop("No PROCESSED articles to analyse.")


# ==============================================================================
# SECTION 2: RELEVANCE & CONSTRUCT IDENTIFICATION
# ==============================================================================

cat("--- SECTION 2: RELEVANCE & CONSTRUCTS ---\n")

# 2a. Relevance check
n_relevant <- sum(sapply(processed, function(r) {
  isTRUE(r$relevance_check$examines_psychopathology)
}))
n_not_relevant <- n_proc - n_relevant
cat(sprintf("  examines_psychopathology = TRUE:  %d (%.1f%%)\n",
            n_relevant, n_relevant / n_proc * 100))
cat(sprintf("  examines_psychopathology = FALSE: %d (%.1f%%)\n",
            n_not_relevant, n_not_relevant / n_proc * 100))

# Note: some articles may have status=PROCESSED but relevance=FALSE (wasn't skipped early)
n_skipped_early <- sum(statuses == "SKIPPED_IRRELEVANT")
cat(sprintf("  Articles skipped at relevance gate (SKIPPED_IRRELEVANT): %d\n\n", n_skipped_early))

# 2b. Constructs — flatten all psychopathology entries
construct_rows <- list()
for (r in processed) {
  psychs <- r$relevance_check$psychopathologies
  if (!is.null(psychs) && length(psychs) > 0) {
    for (p in psychs) {
      construct_rows[[length(construct_rows) + 1]] <- list(
        filename              = r$filename,
        construct_label       = p$construct_label %||% NA_character_,
        construct_label_norm  = p$construct_label_normalised %||% NA_character_,
        construct_type        = p$construct_type %||% NA_character_,
        personality_disorder  = p$personality_disorder %||% NA,
        role_in_study         = p$role_in_study %||% NA_character_,
        op_direction          = p$operational_direction %||% NA_character_,
        th_direction          = p$theoretical_direction %||% NA_character_
      )
    }
  }
}
constructs_df <- bind_rows(construct_rows)

cat(sprintf("  Total construct instances (across all articles): %d\n", nrow(constructs_df)))
cat(sprintf("  Unique articles with ≥1 construct: %d\n",
            n_distinct(constructs_df$filename)))

# Constructs per article
constructs_per_art <- constructs_df %>%
  count(filename, name = "n_constructs") %>%
  summarise(
    mean   = mean(n_constructs),
    median = median(n_constructs),
    min    = min(n_constructs),
    max    = max(n_constructs),
    .groups = "drop"
  )
cat("\n  Constructs per article:\n")
print(constructs_per_art)

# Top 20 normalised labels
cat("\n  Top 20 normalised construct labels:\n")
top_labels <- constructs_df %>%
  filter(!is.na(construct_label_norm)) %>%
  count(construct_label_norm, sort = TRUE) %>%
  head(20)
print(top_labels)

# Construct type distribution
cat("\n  Construct type distribution:\n")
type_tbl <- constructs_df %>%
  count(construct_type, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(type_tbl)

# Personality disorder flag
n_pd <- sum(constructs_df$personality_disorder == TRUE, na.rm = TRUE)
cat(sprintf("\n  Personality disorder constructs: %d (%.1f%% of all constructs)\n\n",
            n_pd, n_pd / nrow(constructs_df) * 100))

# Save constructs
write.csv(constructs_df,
          file.path(SAVE_DIR, "constructs.csv"), row.names = FALSE)
cat("  [SAVED] constructs.csv\n\n")


# ==============================================================================
# SECTION 3: OVERALL CLASSIFICATION DISTRIBUTION
# ==============================================================================

cat("--- SECTION 3: OVERALL CLASSIFICATION ---\n")

# Extract overall classification for each article
class_rows <- lapply(processed, function(r) {
  oc <- r$overall_classification
  list(
    filename       = r$filename,
    classification = if (is.list(oc)) oc$classification else oc,
    confidence     = if (is.list(oc)) oc$confidence else NA_real_,
    study_design   = r$study_design %||% NA_character_,
    sample_type    = r$sample_type %||% NA_character_
  )
})
class_df <- bind_rows(class_rows)

# Classification counts
cat("  Overall classification breakdown:\n")
class_summary <- class_df %>%
  count(classification, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(class_summary)

# Confidence distribution
cat("\n  Classification confidence (0–1 scale):\n")
conf_stats <- class_df %>%
  filter(!is.na(confidence)) %>%
  summarise(
    n      = n(),
    mean   = round(mean(confidence), 3),
    median = round(median(confidence), 3),
    sd     = round(sd(confidence), 3),
    min    = round(min(confidence), 3),
    max    = round(max(confidence), 3),
    pct_below_0.5 = sprintf("%.1f%%", mean(confidence < 0.5) * 100),
    pct_above_0.8 = sprintf("%.1f%%", mean(confidence >= 0.8) * 100)
  )
print(conf_stats)

# Cross-tab: study design vs classification
cat("\n  Study design × classification:\n")
design_x_class <- class_df %>%
  filter(!is.na(study_design), !is.na(classification)) %>%
  count(study_design, classification) %>%
  pivot_wider(names_from = classification, values_from = n, values_fill = 0)
print(design_x_class)

# Cross-tab: sample type vs classification
cat("\n  Sample type × classification:\n")
sample_x_class <- class_df %>%
  filter(!is.na(sample_type), !is.na(classification)) %>%
  count(sample_type, classification) %>%
  pivot_wider(names_from = classification, values_from = n, values_fill = 0)
print(sample_x_class)

# Save
write.csv(class_df,
          file.path(SAVE_DIR, "classifications.csv"), row.names = FALSE)
cat("\n  [SAVED] classifications.csv\n\n")


# ==============================================================================
# SECTION 4: OPERATIONAL STANCE ANALYSIS
# ==============================================================================

cat("--- SECTION 4: OPERATIONAL STANCE ---\n")

op_rows <- lapply(processed, function(r) {
  me <- r$methods_extraction
  if (is.null(me)) return(NULL)
  list(
    filename              = r$filename,
    sampling_technique    = me$sampling$technique %||% NA_character_,
    sampling_cat_rating   = me$sampling$categorical_rating %||% NA_real_,
    sampling_dim_rating   = me$sampling$dimensional_rating %||% NA_real_,
    sampling_confidence   = me$sampling$confidence %||% NA_real_,
    handling_technique    = me$data_handling$technique %||% NA_character_,
    handling_cat_rating   = me$data_handling$categorical_rating %||% NA_real_,
    handling_dim_rating   = me$data_handling$dimensional_rating %||% NA_real_,
    handling_confidence   = me$data_handling$confidence %||% NA_real_,
    analysis_technique    = me$primary_analysis$technique %||% NA_character_,
    analysis_cat_rating   = me$primary_analysis$categorical_rating %||% NA_real_,
    analysis_dim_rating   = me$primary_analysis$dimensional_rating %||% NA_real_,
    analysis_confidence   = me$primary_analysis$confidence %||% NA_real_,
    op_dim_rating         = r$operational_stance$dimensional$rating %||% NA_real_,
    op_cat_rating         = r$operational_stance$categorical$rating %||% NA_real_,
    op_dim_confidence     = r$operational_stance$dimensional$confidence %||% NA_real_,
    op_cat_confidence     = r$operational_stance$categorical$confidence %||% NA_real_
  )
})
op_df <- bind_rows(op_rows)

# Sampling technique distribution
cat("  Sampling technique distribution:\n")
sampling_tbl <- op_df %>%
  count(sampling_technique, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(sampling_tbl)

# Data handling technique distribution
cat("\n  Data handling technique distribution:\n")
handling_tbl <- op_df %>%
  count(handling_technique, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(handling_tbl)

# Primary analysis technique distribution
cat("\n  Primary analysis technique distribution:\n")
analysis_tbl <- op_df %>%
  count(analysis_technique, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(analysis_tbl)

# Operational rating distributions
cat("\n  Operational stance ratings (0–10 scale):\n")
op_ratings <- op_df %>%
  summarise(
    op_dim_mean   = round(mean(op_dim_rating, na.rm = TRUE), 2),
    op_dim_sd     = round(sd(op_dim_rating, na.rm = TRUE), 2),
    op_cat_mean   = round(mean(op_cat_rating, na.rm = TRUE), 2),
    op_cat_sd     = round(sd(op_cat_rating, na.rm = TRUE), 2),
    n_na_dim      = sum(is.na(op_dim_rating)),
    n_na_cat      = sum(is.na(op_cat_rating))
  )
print(op_ratings)

# Check for articles with both high dim and cat ratings (hybrid indicators)
n_high_both <- sum(op_df$op_dim_rating >= 6 & op_df$op_cat_rating >= 6, na.rm = TRUE)
cat(sprintf("\n  Articles with both op_dim ≥ 6 AND op_cat ≥ 6 (hybrid): %d\n", n_high_both))

# Save
write.csv(op_df,
          file.path(SAVE_DIR, "operational_stance.csv"), row.names = FALSE)
cat("  [SAVED] operational_stance.csv\n\n")


# ==============================================================================
# SECTION 5: THEORETICAL STANCE ANALYSIS
# ==============================================================================

cat("--- SECTION 5: THEORETICAL STANCE ---\n")

th_rows <- lapply(processed, function(r) {
  te <- r$theoretical_extraction
  list(
    filename              = r$filename,
    specific_reference    = if (!is.null(te)) te$specific_reference_to_categorical_or_dimensional %||% NA_character_ else NA_character_,
    n_positive_cites      = if (!is.null(te)) length(te$positive_framework_citations) else 0L,
    n_negative_cites      = if (!is.null(te)) length(te$negative_framework_citations) else 0L,
    n_neutral_cites       = if (!is.null(te)) length(te$neutral_framework_citations) else 0L,
    th_dim_rating         = r$theoretical_stance$dimensional$rating %||% NA_real_,
    th_cat_rating         = r$theoretical_stance$categorical$rating %||% NA_real_,
    th_dim_confidence     = r$theoretical_stance$dimensional$confidence %||% NA_real_,
    th_cat_confidence     = r$theoretical_stance$categorical$confidence %||% NA_real_
  )
})
th_df <- bind_rows(th_rows)

# Specific reference
cat("  Explicit mention of categorical/dimensional debate:\n")
spec_ref_tbl <- th_df %>%
  count(specific_reference, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(spec_ref_tbl)

# Framework citations
cat("\n  Framework citation counts (per article, mean):\n")
cite_stats <- th_df %>%
  summarise(
    mean_positive = round(mean(n_positive_cites, na.rm = TRUE), 2),
    mean_negative = round(mean(n_negative_cites, na.rm = TRUE), 2),
    mean_neutral  = round(mean(n_neutral_cites, na.rm = TRUE), 2),
    pct_no_cites  = sprintf("%.1f%%",
                            mean(n_positive_cites + n_negative_cites + n_neutral_cites == 0) * 100)
  )
print(cite_stats)

# Theoretical ratings
cat("\n  Theoretical stance ratings:\n")
th_ratings <- th_df %>%
  summarise(
    th_dim_mean = round(mean(th_dim_rating, na.rm = TRUE), 2),
    th_dim_sd   = round(sd(th_dim_rating, na.rm = TRUE), 2),
    th_cat_mean = round(mean(th_cat_rating, na.rm = TRUE), 2),
    th_cat_sd   = round(sd(th_cat_rating, na.rm = TRUE), 2)
  )
print(th_ratings)

# Top framework names cited positively
positive_frames <- unlist(lapply(processed, function(r) {
  te <- r$theoretical_extraction
  if (!is.null(te) && !is.null(te$positive_framework_citations)) {
    v <- unlist(te$positive_framework_citations)
    v[v != "N/A" & nchar(v) > 0]
  }
}))
if (length(positive_frames) > 0) {
  cat("\n  Top positively-cited frameworks:\n")
  print(head(sort(table(positive_frames), decreasing = TRUE), 15))
}

# Save
write.csv(th_df,
          file.path(SAVE_DIR, "theoretical_stance.csv"), row.names = FALSE)
cat("\n  [SAVED] theoretical_stance.csv\n\n")


# ==============================================================================
# SECTION 6: OPERATIONAL vs THEORETICAL STANCE AGREEMENT
# ==============================================================================

cat("--- SECTION 6: STANCE AGREEMENT ---\n")

# Build a per-article dominant stance from ratings
# Label as "dimensional" if dim_rating > cat_rating, "categorical" if reversed,
# "hybrid" if within 1 point, "indeterminate" if both NA
dominant_stance <- function(dim_r, cat_r) {
  if (is.na(dim_r) | is.na(cat_r)) return("indeterminate")
  diff <- dim_r - cat_r
  if (abs(diff) <= 1) return("hybrid")
  if (diff > 1)  return("dimensional")
  return("categorical")
}

agreement_df <- tibble(filename = names(processed)) %>%
  left_join(
    op_df %>% select(filename, op_dim_rating, op_cat_rating),
    by = "filename"
  ) %>%
  left_join(
    th_df %>% select(filename, th_dim_rating, th_cat_rating),
    by = "filename"
  ) %>%
  mutate(
    op_dominant = mapply(dominant_stance, op_dim_rating, op_cat_rating),
    th_dominant = mapply(dominant_stance, th_dim_rating, th_cat_rating),
    agree       = op_dominant == th_dominant
  )

cat("  Operational dominant stance:\n")
print(table(agreement_df$op_dominant))

cat("\n  Theoretical dominant stance:\n")
print(table(agreement_df$th_dominant))

n_agree <- sum(agreement_df$agree, na.rm = TRUE)
cat(sprintf("\n  Operational–theoretical agreement: %d / %d (%.1f%%)\n",
            n_agree, n_proc, n_agree / n_proc * 100))

cat("\n  Cross-tab (operational × theoretical dominant stance):\n")
cross_tbl <- table(Op = agreement_df$op_dominant, Th = agreement_df$th_dominant)
print(cross_tbl)

# Save
write.csv(agreement_df,
          file.path(SAVE_DIR, "stance_agreement.csv"), row.names = FALSE)
cat("\n  [SAVED] stance_agreement.csv\n\n")


# ==============================================================================
# SECTION 7: QUALITY & COMPLETENESS CHECKS
# ==============================================================================

cat("--- SECTION 7: QUALITY & COMPLETENESS CHECKS ---\n")

count_words <- function(s) {
  if (is.null(s) || is.na(s) || !is.character(s) || nchar(s) == 0) return(0L)
  length(strsplit(trimws(s), "\\s+")[[1]])
}

quality_rows <- lapply(processed, function(r) {
  cot_words     <- count_words(r$thinking$chain_of_thought)
  rationale_wds <- count_words(r$rationale)
  n_evidence    <- length(r$evidence %||% list())
  n_discourse   <- length(r$discourse %||% list())

  # Check required top-level fields are present
  required_fields <- c("relevance_check", "thinking", "evidence", "methods_extraction",
                       "theoretical_extraction", "discourse", "theoretical_stance",
                       "operational_stance", "overall_classification",
                       "study_design", "sample_type", "rationale")
  missing_fields <- required_fields[!required_fields %in% names(r)]

  list(
    filename         = r$filename,
    cot_words        = cot_words,
    rationale_words  = rationale_wds,
    n_evidence       = n_evidence,
    n_discourse      = n_discourse,
    missing_fields   = if (length(missing_fields) > 0)
                         paste(missing_fields, collapse = "; ")
                       else "",
    cot_ok           = cot_words >= 150,
    rationale_ok     = rationale_wds >= 150,
    evidence_ok      = n_evidence >= 3 & n_evidence <= 6,
    discourse_ok     = n_discourse == 2,
    all_fields_ok    = length(missing_fields) == 0
  )
})
quality_df <- bind_rows(quality_rows)

# Chain of thought length
cat("  Chain of thought word count (min 150 words required):\n")
cot_stats <- quality_df %>%
  summarise(
    n_ok      = sum(cot_ok),
    n_fail    = sum(!cot_ok),
    pct_ok    = sprintf("%.1f%%", mean(cot_ok) * 100),
    mean_wds  = round(mean(cot_words), 0),
    median    = round(median(cot_words), 0),
    min       = min(cot_words),
    max       = max(cot_words)
  )
print(cot_stats)

# Rationale length
cat("\n  Rationale word count (min 150 words required):\n")
rat_stats <- quality_df %>%
  summarise(
    n_ok      = sum(rationale_ok),
    n_fail    = sum(!rationale_ok),
    pct_ok    = sprintf("%.1f%%", mean(rationale_ok) * 100),
    mean_wds  = round(mean(rationale_words), 0),
    median    = round(median(rationale_words), 0),
    min       = min(rationale_words),
    max       = max(rationale_words)
  )
print(rat_stats)

# Evidence count (expected 3–6 per article)
cat("\n  Evidence count per article (expected 3–6):\n")
ev_stats <- quality_df %>%
  summarise(
    n_ok      = sum(evidence_ok),
    n_fail    = sum(!evidence_ok),
    pct_ok    = sprintf("%.1f%%", mean(evidence_ok) * 100),
    mean      = round(mean(n_evidence), 2),
    median    = round(median(n_evidence), 1),
    min       = min(n_evidence),
    max       = max(n_evidence)
  )
print(ev_stats)

# Discourse count (expected exactly 2)
cat("\n  Discourse count per article (expected exactly 2):\n")
disc_stats <- quality_df %>%
  summarise(
    n_ok      = sum(discourse_ok),
    n_fail    = sum(!discourse_ok),
    pct_ok    = sprintf("%.1f%%", mean(discourse_ok) * 100),
    mean      = round(mean(n_discourse), 2),
    median    = round(median(n_discourse), 1),
    min       = min(n_discourse),
    max       = max(n_discourse)
  )
print(disc_stats)

# Missing fields
n_missing <- sum(quality_df$missing_fields != "")
cat(sprintf("\n  Articles with missing top-level fields: %d", n_missing))
if (n_missing > 0) {
  missing_summary <- quality_df %>%
    filter(missing_fields != "") %>%
    count(missing_fields, sort = TRUE)
  cat("\n  Missing field patterns:\n")
  print(missing_summary)
}

# Overall pass/fail summary
n_perfect <- sum(
  quality_df$cot_ok & quality_df$rationale_ok &
  quality_df$evidence_ok & quality_df$discourse_ok &
  quality_df$all_fields_ok
)
cat(sprintf("\n  Articles passing ALL quality checks: %d / %d (%.1f%%)\n",
            n_perfect, n_proc, n_perfect / n_proc * 100))

# Flag articles needing review
flagged <- quality_df %>%
  filter(!(cot_ok & rationale_ok & evidence_ok & discourse_ok & all_fields_ok)) %>%
  select(filename, cot_words, rationale_words, n_evidence, n_discourse, missing_fields)

if (nrow(flagged) > 0) {
  cat(sprintf("\n  [REVIEW] %d articles flagged for quality review:\n", nrow(flagged)))
  print(head(flagged, 20))
  if (nrow(flagged) > 20) cat("  ... (truncated, see flagged_articles.csv)\n")
}

# Save
write.csv(quality_df,
          file.path(SAVE_DIR, "quality_checks.csv"), row.names = FALSE)
write.csv(flagged,
          file.path(SAVE_DIR, "flagged_articles.csv"), row.names = FALSE)
cat("\n  [SAVED] quality_checks.csv\n")
cat("  [SAVED] flagged_articles.csv\n\n")


# ==============================================================================
# SECTION 8: DISCOURSE ANALYSIS
# ==============================================================================

cat("--- SECTION 8: DISCOURSE ANALYSIS ---\n")

discourse_rows <- list()
for (r in processed) {
  disc <- r$discourse %||% list()
  for (i in seq_along(disc)) {
    d <- disc[[i]]
    discourse_rows[[length(discourse_rows) + 1]] <- list(
      filename     = r$filename,
      index        = i,
      type         = d$type %||% NA_character_,
      target_stance = d$target_stance %||% NA_character_,
      location     = d$location %||% NA_character_
    )
  }
}
discourse_df <- bind_rows(discourse_rows)

cat("  Discourse type distribution:\n")
disc_type_tbl <- discourse_df %>%
  count(type, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(disc_type_tbl)

cat("\n  Target stance distribution:\n")
disc_target_tbl <- discourse_df %>%
  count(target_stance, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(disc_target_tbl)

cat("\n  Location distribution:\n")
disc_loc_tbl <- discourse_df %>%
  count(location, sort = TRUE) %>%
  mutate(pct = sprintf("%.1f%%", n / sum(n) * 100))
print(disc_loc_tbl)

write.csv(discourse_df,
          file.path(SAVE_DIR, "discourse.csv"), row.names = FALSE)
cat("\n  [SAVED] discourse.csv\n\n")


# ==============================================================================
# SECTION 9: SUMMARY REPORT
# ==============================================================================

cat("=============================================================\n")
cat(" SUMMARY REPORT\n")
cat("=============================================================\n")

n_processed_pct  <- sprintf("%.1f%%", n_proc / n_total * 100)
n_relevant_pct   <- sprintf("%.1f%%", n_relevant / n_proc * 100)
n_perfect_pct    <- sprintf("%.1f%%", n_perfect / n_proc * 100)

cat(sprintf(
"  Run date:            %s
  Total loaded:        %d
  Processed:           %d (%s)
  Relevant to DC:      %d (%s of processed)

  Classification breakdown:
%s
  Quality (all checks): %d / %d (%s)
  Flagged for review:   %d

  Output files saved to: %s
",
  format(Sys.time(), "%Y-%m-%d %H:%M"),
  n_total,
  n_proc, n_processed_pct,
  n_relevant, n_relevant_pct,
  paste0("    ", capture.output(print(class_summary)), collapse = "\n"),
  n_perfect, n_proc, n_perfect_pct,
  nrow(flagged),
  SAVE_DIR
))

# Write summary text file
summary_lines <- c(
  "DC PROMPT — ANALYSIS SUMMARY",
  paste0("Date: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  paste0("Input: ", RESULTS_INPUT),
  "",
  paste0("Total loaded:           ", n_total),
  paste0("Processed:              ", n_proc, " (", n_processed_pct, ")"),
  paste0("Relevant (DC):          ", n_relevant, " (", n_relevant_pct, " of processed)"),
  "",
  "Classification breakdown:",
  capture.output(print(class_summary)),
  "",
  paste0("Quality pass rate:      ", n_perfect, "/", n_proc, " (", n_perfect_pct, ")"),
  paste0("Flagged for review:     ", nrow(flagged))
)

writeLines(summary_lines,
           file.path(SAVE_DIR, "dc_analysis_summary.txt"))
cat("  [SAVED] dc_analysis_summary.txt\n")
cat("\nDone.\n")
