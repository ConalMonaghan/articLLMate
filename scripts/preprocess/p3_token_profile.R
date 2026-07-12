# ==============================================================================
# STAGE 3: TOKEN USAGE + COST ESTIMATION
# ==============================================================================
#
# PURPOSE:
# Count INPUT tokens per article (tiktoken), pair them with an assumed OUTPUT
# token count, and estimate API cost using per-million input/output prices.
# Writes an enriched per-article CSV, records input tokens in the ledger, prints
# a cost summary with a range, and renders a short Quarto report (token density
# distribution + estimated cost range).
#
# EXPECTS (from the master environment):
#   ledger                - the audit ledger (tibble)
#   CURRENT_OBJECT        - latest stage object (baton); falls back to length/body
#   STAGE_DIRS$tokens / STAGE_OBJECT - this stage's output folder
#   PRE_DIR               - preprocess script folder (holds token_report.qmd)
#   env_name              - conda env with tiktoken (default "articLLMate")
#   token_encoding        - tiktoken encoding (default "cl100k_base")
#   cost_in_per_million   - USD per 1e6 INPUT tokens
#   cost_out_per_million  - USD per 1e6 OUTPUT tokens
#   assumed_output_tokens - assumed OUTPUT tokens per article (default 7000)
#
# PRODUCES:
#   ledger                        - n_tokens (input) filled for surviving articles
#   STAGE_DIRS$tokens/token_counts.csv  - per-article tokens in/out + cost
#   STAGE_DIRS$tokens/token_report.html - rendered Quarto report (best-effort)
# ==============================================================================

library(reticulate)
library(readr)
library(dplyr)
library(ggplot2)
library(scales)

in_path <- if (!is.na(CURRENT_OBJECT) && file.exists(CURRENT_OBJECT)) {
  CURRENT_OBJECT
} else if (file.exists(file.path(STAGE_DIRS$length, STAGE_OBJECT))) {
  file.path(STAGE_DIRS$length, STAGE_OBJECT)
} else {
  file.path(STAGE_DIRS$body, STAGE_OBJECT)
}
if (!file.exists(in_path)) {
  stop("p3_token_profile: no input object found (run stages 2b/2c first).")
}
stage_dir <- STAGE_DIRS$tokens
if (!dir.exists(stage_dir)) dir.create(stage_dir, recursive = TRUE)

use_condaenv(env_name %||% "articLLMate", required = TRUE)
tiktoken <- import("tiktoken")
enc <- tiktoken$get_encoding(token_encoding %||% "cl100k_base")

obj <- readRDS(in_path)
keys <- names(obj)
n <- length(keys)
cat(sprintf("  Tokenizing %d article(s) from: %s\n", n, basename(in_path)))

pb <- txtProgressBar(min = 0, max = n, style = 3)
n_tokens <- integer(n)
for (i in seq_len(n)) {
  article <- obj[[keys[i]]]
  full_text <- paste0(article$XML$Title %||% "", "\n\n", article$XML$Text %||% "")
  n_tokens[i] <- length(enc$encode(full_text))
  setTxtProgressBar(pb, i)
}
close(pb)

# ---- Cost model ---------------------------------------------------------------
cost_in  <- cost_in_per_million   %||% 0
cost_out <- cost_out_per_million  %||% 0
out_tok  <- assumed_output_tokens %||% 7000

counts <- tibble(
  article_id     = keys,
  n_tokens_in    = as.integer(n_tokens),
  n_tokens_out   = as.integer(out_tok),
  cost_in_usd    = n_tokens_in  / 1e6 * cost_in,
  cost_out_usd   = n_tokens_out / 1e6 * cost_out,
  cost_total_usd = cost_in_usd + cost_out_usd
)
write_csv(counts, file.path(stage_dir, "token_counts.csv"))

# Ledger keeps INPUT token count.
ledger <- ledger_upsert(ledger, tibble(article_id = keys, n_tokens = as.integer(n_tokens)),
                        stage = "p3_token_profile")

# ---- Console summary ----------------------------------------------------------
total_in  <- sum(counts$n_tokens_in)
cost_in_t <- sum(counts$cost_in_usd)
# Range driven by the (uncertain) output-token assumption: 0.5x / 1x / 1.5x.
mults  <- c(low = 0.5, expected = 1.0, high = 1.5)
totals <- cost_in_t + (n * out_tok * mults) / 1e6 * cost_out
bd     <- batch_discount %||% 1                     # e.g. 0.5 = 50% off in batch mode
totals_batch <- totals * bd

cat(sprintf("\n  [SUMMARY] Input tokens: %s  |  Assumed output: %s/article\n",
            formatC(total_in, format = "d", big.mark = ","),
            formatC(out_tok,  format = "d", big.mark = ",")))
cat(sprintf("  Prices: $%.2f/M in, $%.2f/M out\n", cost_in, cost_out))
cat(sprintf("  Standard total: $%.2f  (range $%.2f – $%.2f at 0.5x–1.5x output)\n",
            totals[["expected"]], totals[["low"]], totals[["high"]]))
if (bd != 1) {
  cat(sprintf("  Batch total (%.0f%% off): $%.2f  (range $%.2f – $%.2f)\n",
              (1 - bd) * 100, totals_batch[["expected"]], totals_batch[["low"]], totals_batch[["high"]]))
}

ctx_sizes <- c(4096, 8192, 16384, 32768, 65536)
cat("  Context-window fit:\n")
for (ctx in ctx_sizes) {
  cat(sprintf("    num_ctx = %6d  ->  %5.1f%% of articles fit\n",
              ctx, round(sum(n_tokens <= ctx) / n * 100, 1)))
}

# ---- Report: density distribution + cost range --------------------------------
# Generated natively in R (ggplot PNG + markdown) so it always works, with no
# dependency on the Quarto/deno toolchain. The parameterised token_report.qmd is
# also copied in for a richer render when `render_quarto = TRUE` and a working
# Quarto is available.

# Density of input tokens with context-window markers.
ctx <- c(4096, 8192, 16384, 32768, 65536)
p <- ggplot(counts, aes(x = n_tokens_in)) +
  geom_density(fill = "#4A90D9", alpha = 0.6, colour = "#2C5F8A") +
  geom_vline(xintercept = ctx, linetype = "dashed", colour = "red", alpha = 0.5) +
  annotate("text", x = ctx, y = Inf, label = paste0(ctx / 1024, "K"),
           vjust = 1.5, hjust = -0.15, size = 3, colour = "red") +
  scale_x_continuous(labels = comma) +
  labs(x = "Input tokens per article", y = "Density") +
  theme_minimal(base_size = 12)
ggsave(file.path(stage_dir, "token_density.png"), p, width = 9, height = 5, dpi = 150)

# Markdown report.
qs <- quantile(counts$n_tokens_in, c(0.5, 0.95, 0.99))
usd <- function(x) sprintf("$%s", formatC(x, format = "f", digits = 2, big.mark = ","))
md <- c(
  sprintf("# Token Usage & Cost Estimate%s",
          if (nzchar(project_name %||% "")) paste0(" — ", project_name) else ""),
  "",
  sprintf("**Articles:** %s  |  **Encoding:** %s  |  **Prices:** $%.2f/M in, $%.2f/M out  |  **Assumed output:** %s tokens/article",
          comma(n), token_encoding %||% "cl100k_base", cost_in, cost_out, comma(out_tok)),
  "", "## Token distribution", "", "![Input-token density](token_density.png)", "",
  "| Metric | Value |", "|---|---|",
  sprintf("| Total input tokens | %s |", comma(total_in)),
  sprintf("| Mean | %s |", comma(round(mean(counts$n_tokens_in)))),
  sprintf("| Median | %s |", comma(round(qs[1]))),
  sprintf("| 95th percentile | %s |", comma(round(qs[2]))),
  sprintf("| 99th percentile | %s |", comma(round(qs[3]))),
  sprintf("| Max | %s |", comma(max(counts$n_tokens_in))),
  "", "## Estimated cost", "",
  sprintf("Input tokens are measured (input cost is fixed); output tokens are assumed, so the range flexes the assumption from 0.5x to 1.5x. Batch total = %.0f%% off standard.",
          (1 - bd) * 100),
  "", "| Scenario | Output/article | Output cost | Input cost | Standard total | Batch total |",
  "|---|---|---|---|---|---|",
  sprintf("| Low (0.5x) | %s | %s | %s | %s | %s |", comma(round(out_tok*0.5)), usd((n*out_tok*0.5)/1e6*cost_out), usd(cost_in_t), usd(totals[["low"]]),      usd(totals_batch[["low"]])),
  sprintf("| Expected | %s | %s | %s | %s | %s |",   comma(out_tok),           usd((n*out_tok)/1e6*cost_out),     usd(cost_in_t), usd(totals[["expected"]]), usd(totals_batch[["expected"]])),
  sprintf("| High (1.5x) | %s | %s | %s | %s | %s |", comma(round(out_tok*1.5)), usd((n*out_tok*1.5)/1e6*cost_out), usd(cost_in_t), usd(totals[["high"]]),     usd(totals_batch[["high"]])),
  "",
  sprintf("**Expected total: %s standard / %s batch** (standard range %s – %s). Per-article median %s, max %s.",
          usd(totals[["expected"]]), usd(totals_batch[["expected"]]), usd(totals[["low"]]), usd(totals[["high"]]),
          usd(median(counts$cost_total_usd)), usd(max(counts$cost_total_usd)))
)
writeLines(md, file.path(stage_dir, "token_report.md"))
cat(sprintf("  [OK] Report: %s (+ token_density.png)\n", file.path(stage_dir, "token_report.md")))

# Optional richer Quarto render (off by default; needs a working Quarto/deno).
if (isTRUE(get0("render_quarto", ifnotfound = FALSE))) {
  report_src <- file.path(PRE_DIR, "token_report.qmd")
  if (requireNamespace("quarto", quietly = TRUE) && file.exists(report_src)) {
    file.copy(report_src, file.path(stage_dir, "token_report.qmd"), overwrite = TRUE)
    tryCatch(quarto::quarto_render(
      input = file.path(stage_dir, "token_report.qmd"),
      execute_params = list(token_csv = "token_counts.csv", encoding = token_encoding %||% "cl100k_base",
                            project = project_name %||% "", cost_in_per_million = cost_in,
                            cost_out_per_million = cost_out, assumed_output_tokens = out_tok,
                            batch_discount = bd),
      quiet = TRUE),
      error = function(e) message("  [WARN] Quarto render skipped: ", conditionMessage(e)))
  }
}
