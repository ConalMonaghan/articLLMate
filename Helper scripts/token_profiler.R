library(here)
library(reticulate)
library(tidyverse)


# This script counts tokens for all .rds files in a folder, producing summary
# statistics and density plots — one combined across all files, one per file.


# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

INPUT_PATH  <- here("input", "R_obs_short")   # Folder containing .rds files
OUTPUT_PATH <- here("output", "Token Count")                  # Where to save plots + CSV
encoding    <- "cl100k_base"                   # tiktoken encoding
save_csv    <- TRUE                            # Save per-article token counts as CSV?


# ==============================================================================
# SETUP
# ==============================================================================

cat("Token Profiler\n")
cat(paste(rep("=", 60), collapse = ""), "\n\n")

# Activate conda env and import tiktoken
use_condaenv("articLLMate", required = TRUE)
tiktoken <- import("tiktoken")
enc      <- tiktoken$get_encoding(encoding)
cat(sprintf("  [OK] Tokenizer: %s\n", encoding))

# Create output directory if it doesn't exist
if (!dir.exists(OUTPUT_PATH)) dir.create(OUTPUT_PATH, recursive = TRUE)


# ==============================================================================
# LOAD RDS FILES
# ==============================================================================

if (!dir.exists(INPUT_PATH)) stop("INPUT_PATH not found: ", INPUT_PATH)

rds_files <- list.files(INPUT_PATH, pattern = "\\.rds$", full.names = TRUE, ignore.case = TRUE)
cat(sprintf("  [OK] Found %d .rds file(s) in folder: %s\n\n", length(rds_files), INPUT_PATH))

if (length(rds_files) == 0) stop("No .rds files found in INPUT_PATH.")


# ==============================================================================
# HELPER: TOKENIZE ONE RDS OBJECT
# ==============================================================================

tokenize_articles <- function(articles_data, source_label) {

  n    <- length(articles_data)
  keys <- names(articles_data)

  results <- tibble(
    article_id   = character(n),
    rds_source   = character(n),
    n_characters = integer(n),
    n_tokens     = integer(n)
  )

  pb <- txtProgressBar(min = 0, max = n, style = 3)

  for (i in seq_len(n)) {
    key     <- keys[i]
    article <- articles_data[[key]]

    title_text <- if (!is.null(article$XML$Title) && !is.na(article$XML$Title)) article$XML$Title else ""
    body_text  <- if (!is.null(article$XML$Text)  && !is.na(article$XML$Text))  article$XML$Text  else ""
    full_text  <- paste0(title_text, "\n\n", body_text)

    tokens <- enc$encode(full_text)

    results$article_id[i]   <- key
    results$rds_source[i]   <- source_label
    results$n_characters[i] <- nchar(full_text)
    results$n_tokens[i]     <- length(tokens)

    setTxtProgressBar(pb, i)
  }

  close(pb)
  return(results)
}


# ==============================================================================
# HELPER: PRINT SUMMARY STATISTICS
# ==============================================================================

print_summary <- function(results, label) {

  ctx_sizes <- c(4096, 8192, 16384, 32768)

  cat(paste(rep("=", 60), collapse = ""), "\n")
  cat(sprintf("SUMMARY: %s\n", label))
  cat(paste(rep("=", 60), collapse = ""), "\n\n")

  cat(sprintf("  Articles:      %d\n",      nrow(results)))
  cat(sprintf("  Total tokens:  %s\n",      formatC(sum(results$n_tokens), format = "d", big.mark = ",")))
  cat(sprintf("  Mean:          %.0f tokens\n", mean(results$n_tokens)))
  cat(sprintf("  SD:            %.0f tokens\n", sd(results$n_tokens)))
  cat(sprintf("  Median:        %.0f tokens\n", median(results$n_tokens)))
  cat(sprintf("  Range:         %s – %s tokens\n",
              formatC(min(results$n_tokens), format = "d", big.mark = ","),
              formatC(max(results$n_tokens), format = "d", big.mark = ",")))

  quants <- quantile(results$n_tokens, probs = c(0.25, 0.75, 0.90, 0.95, 0.99))
  cat(sprintf("\n  25th %%ile:     %.0f tokens\n", quants[1]))
  cat(sprintf("  75th %%ile:     %.0f tokens\n",  quants[2]))
  cat(sprintf("  90th %%ile:     %.0f tokens\n",  quants[3]))
  cat(sprintf("  95th %%ile:     %.0f tokens\n",  quants[4]))
  cat(sprintf("  99th %%ile:     %.0f tokens\n",  quants[5]))

  cat("\n  Context window coverage:\n")
  for (ctx in ctx_sizes) {
    n_fit <- sum(results$n_tokens <= ctx)
    pct   <- round(n_fit / nrow(results) * 100, 1)
    cat(sprintf("    num_ctx = %5d  →  %d / %d articles fit  (%s%%)\n",
                ctx, n_fit, nrow(results), pct))
  }
  cat("\n")
}


# ==============================================================================
# HELPER: MAKE DENSITY PLOT (single source)
# ==============================================================================

make_density_plot <- function(results, title_label) {

  ctx_sizes <- c(4096, 8192, 16384, 32768)

  subtitle <- sprintf("n = %d  |  total tokens = %s  |  median = %.0f  |  range = %s – %s",
                      nrow(results),
                      formatC(sum(results$n_tokens),  format = "d", big.mark = ","),
                      median(results$n_tokens),
                      formatC(min(results$n_tokens),  format = "d", big.mark = ","),
                      formatC(max(results$n_tokens),  format = "d", big.mark = ","))

  ggplot(results, aes(x = n_tokens)) +
    geom_density(fill = "#4A90D9", alpha = 0.6, colour = "#2C5F8A") +
    geom_vline(xintercept = ctx_sizes, linetype = "dashed", colour = "red", alpha = 0.6) +
    annotate("text", x = ctx_sizes, y = Inf,
             label = paste0(ctx_sizes / 1024, "K"),
             vjust = 2, hjust = -0.2, size = 3, colour = "red") +
    labs(title = title_label, subtitle = subtitle, x = "Token count", y = "Density") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
}


# ==============================================================================
# TOKENIZE EACH FILE INDIVIDUALLY
# ==============================================================================

all_results <- list()

for (rds_path in rds_files) {

  file_label <- tools::file_path_sans_ext(basename(rds_path))
  cat(sprintf("\nLoading: %s ...\n", basename(rds_path)))

  rds_obj <- readRDS(rds_path)

  if (!is.list(rds_obj) || length(rds_obj) == 0) {
    cat(sprintf("  [WARN] Skipping empty or non-list object: %s\n", basename(rds_path)))
    next
  }

  cat(sprintf("  Articles in this file: %d\n", length(rds_obj)))
  cat("  Counting tokens...\n")

  file_results <- tokenize_articles(rds_obj, source_label = file_label)

  print_summary(file_results, label = file_label)

  p_file    <- make_density_plot(file_results, title_label = file_label)
  plot_path <- file.path(OUTPUT_PATH, paste0("token_profile_", file_label, ".png"))
  ggsave(plot_path, p_file, width = 10, height = 6, dpi = 150)
  cat(sprintf("  [OK] Plot saved: %s\n", plot_path))

  all_results[[file_label]] <- file_results
}


# ==============================================================================
# COMBINED ANALYSIS ACROSS ALL FILES
# ==============================================================================

combined_results <- bind_rows(all_results)

cat("\n")
print_summary(combined_results, label = "ALL FILES COMBINED")

# Per-file breakdown table within combined summary
cat("  Per-file breakdown:\n")
combined_results %>%
  group_by(rds_source) %>%
  summarise(
    n             = n(),
    total_tokens  = sum(n_tokens),
    mean_tokens   = round(mean(n_tokens)),
    median_tokens = round(median(n_tokens)),
    min_tokens    = min(n_tokens),
    max_tokens    = max(n_tokens),
    .groups = "drop"
  ) %>%
  { for (r in seq_len(nrow(.)))
      cat(sprintf("    %-35s  n=%-6d  total=%s  median=%-6d  range=%d–%d\n",
                  .$rds_source[r],
                  .$n[r],
                  formatC(.$total_tokens[r], format = "d", big.mark = ","),
                  .$median_tokens[r],
                  .$min_tokens[r],
                  .$max_tokens[r])) }
cat("\n")

# ------------------------------------------------------------------------------
# Combined plot A: overlaid density curves, one per source
# ------------------------------------------------------------------------------
ctx_sizes <- c(4096, 8192, 16384, 32768)

p_combined_overlay <- ggplot(combined_results, aes(x = n_tokens, fill = rds_source, colour = rds_source)) +
  geom_density(alpha = 0.35) +
  geom_vline(xintercept = ctx_sizes, linetype = "dashed", colour = "red", alpha = 0.6) +
  annotate("text", x = ctx_sizes, y = Inf,
           label = paste0(ctx_sizes / 1024, "K"),
           vjust = 2, hjust = -0.2, size = 3, colour = "red") +
  labs(
    title    = "Token Distribution — All Sources Overlaid",
    subtitle = sprintf("n = %d articles  |  total tokens = %s  |  median = %.0f  |  range = %s – %s",
                       nrow(combined_results),
                       formatC(sum(combined_results$n_tokens),  format = "d", big.mark = ","),
                       median(combined_results$n_tokens),
                       formatC(min(combined_results$n_tokens),  format = "d", big.mark = ","),
                       formatC(max(combined_results$n_tokens),  format = "d", big.mark = ",")),
    x      = "Token count",
    y      = "Density",
    fill   = "Source",
    colour = "Source"
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold"))

ggsave(file.path(OUTPUT_PATH, "token_profile_COMBINED_overlay.png"),
       p_combined_overlay, width = 12, height = 6, dpi = 150)
cat("  [OK] Combined overlay plot saved.\n")

# ------------------------------------------------------------------------------
# Combined plot B: faceted — one panel per source, consistent x-axis
# ------------------------------------------------------------------------------

# Build per-source annotation labels for facet subtitles
facet_labels <- combined_results %>%
  group_by(rds_source) %>%
  summarise(
    label = sprintf("n=%d  |  total=%s  |  median=%d  |  range=%d–%d",
                    n(),
                    formatC(sum(n_tokens), format = "d", big.mark = ","),
                    round(median(n_tokens)),
                    min(n_tokens),
                    max(n_tokens)),
    .groups = "drop"
  )

combined_results <- combined_results %>%
  left_join(facet_labels, by = "rds_source") %>%
  mutate(facet_title = paste0(rds_source, "\n", label))

p_combined_facet <- ggplot(combined_results, aes(x = n_tokens, fill = rds_source)) +
  geom_density(alpha = 0.6, colour = NA) +
  geom_vline(xintercept = ctx_sizes, linetype = "dashed", colour = "red", alpha = 0.5) +
  facet_wrap(~ facet_title, scales = "free_y") +
  labs(
    title    = "Token Distribution — Per Source",
    subtitle = sprintf("Combined: n = %d  |  total tokens = %s  |  encoding: %s",
                       nrow(combined_results),
                       formatC(sum(combined_results$n_tokens), format = "d", big.mark = ","),
                       encoding),
    x = "Token count",
    y = "Density"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title   = element_text(face = "bold"),
    legend.position = "none"   # Colour is redundant with facet labels
  )

ggsave(file.path(OUTPUT_PATH, "token_profile_COMBINED_facet.png"),
       p_combined_facet, width = 14, height = 8, dpi = 150)
cat("  [OK] Combined facet plot saved.\n")


# ==============================================================================
# SAVE CSV (optional)
# ==============================================================================

if (save_csv) {
  csv_path <- file.path(OUTPUT_PATH, "token_profile.csv")
  # Drop the facet_title helper column before saving
  write_csv(select(combined_results, -facet_title, -label), csv_path)
  cat(sprintf("  [OK] Per-article CSV saved: %s\n", csv_path))
}

cat("\nDone.\n")