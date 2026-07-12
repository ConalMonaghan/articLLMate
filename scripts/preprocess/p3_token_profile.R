# ==============================================================================
# STAGE 3: TOKEN USAGE PREDICTION
# ==============================================================================
#
# PURPOSE:
# Count tokens per article to predict API cost / context-window fit. Logging-
# aware refactor of "Helper scripts/token_profiler.R" focused on ledger
# integration: it tokenizes each surviving article and writes n_tokens back to
# the audit ledger, then prints a compact distribution summary.
#
# EXPECTS (from the master environment):
#   ledger        - the audit ledger (tibble)
#   CURRENT_OBJECT- path to the latest stage object (baton); falls back to the
#                   length- then body-stage objects
#   STAGE_DIRS$tokens / STAGE_OBJECT - this stage's output folder
#   env_name      - conda env with tiktoken (default "articLLMate")
#   token_encoding- tiktoken encoding (default "cl100k_base")
#
# PRODUCES:
#   ledger        - n_tokens filled for surviving articles
#   STAGE_DIRS$tokens/token_counts.csv - per-article token counts
# ==============================================================================

library(reticulate)
library(readr)

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
  title_text <- article$XML$Title %||% ""
  body_text  <- article$XML$Text  %||% ""
  full_text  <- paste0(title_text, "\n\n", body_text)
  n_tokens[i] <- length(enc$encode(full_text))
  setTxtProgressBar(pb, i)
}
close(pb)

upd <- tibble(article_id = keys, n_tokens = as.integer(n_tokens))
ledger <- ledger_upsert(ledger, upd, stage = "p3_token_profile")

write_csv(upd, file.path(stage_dir, "token_counts.csv"))

ctx_sizes <- c(4096, 8192, 16384, 32768, 65536)
cat(sprintf("\n  [SUMMARY] Total tokens: %s  |  Mean: %.0f  |  Median: %.0f  |  Max: %s\n",
            formatC(sum(n_tokens), format = "d", big.mark = ","),
            mean(n_tokens), median(n_tokens),
            formatC(max(n_tokens), format = "d", big.mark = ",")))
cat("  Context-window fit:\n")
for (ctx in ctx_sizes) {
  pct <- round(sum(n_tokens <= ctx) / n * 100, 1)
  cat(sprintf("    num_ctx = %6d  ->  %5.1f%% of articles fit\n", ctx, pct))
}
