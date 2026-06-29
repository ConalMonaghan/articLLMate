# ==============================================================================
# DEBUG: Local Model Output Inspector
# ==============================================================================
# PURPOSE: Standalone script to inspect raw Ollama output across models and
#          thinking configurations. Tests each model with think=default,
#          think=TRUE, and think=FALSE to confirm:
#            1. Whether thinking goes to a separate $thinking field or is
#               embedded in $content (determines which cleanup is needed)
#            2. Whether the pipeline's cleanup logic handles each case
#            3. JSON parse success/failure for complex output
#
# HOW TO USE: Set MODELS below, then source this file in RStudio.
#             Ollama must be running with all listed models loaded.
#             Run: ollama list   -- to confirm what is available.
#
# Does NOT require the full articLLMate pipeline.
# ==============================================================================

library(httr2)
library(jsonlite)

# ---- Configuration ----
OLLAMA_URL <- "http://localhost:11434/api/chat"

# Models to test -- comment out any that aren't loaded
MODELS <- c(
  "gemma4:26b",
  "deepseek-r1:32b",
  "gpt-oss:120b"
)

# A more demanding prompt that exercises: negative numbers, string whitespace,
# nested fields, and arrays -- the kinds of things that trip up local models
SYSTEM_BASE <- "You are a JSON API. Return only valid JSON, no explanation."
TEST_PROMPT <- paste0(
  'Return ONLY valid JSON matching this exact schema -- no markdown, no explanation:\n',
  '{\n',
  '  "title": "string",\n',
  '  "year": integer,\n',
  '  "score": float (can be negative),\n',
  '  "tags": ["string", ...],\n',
  '  "notes": "string with some detail"\n',
  '}\n\n',
  'Use realistic values. The score should be -0.42.'
)

# ---- Pipeline cleanup (mirrors 03b_run_analysis_local.R) ----
pipeline_clean <- function(text) {
  # Gemma4 / channel-format thinking tokens
  text <- gsub("(?s)<\\|channel>thought\\n.*?<channel\\|>", "", text, perl = TRUE)
  # DeepSeek-R1 / generic <think> tags
  text <- gsub("(?s)<think(?:ing)?>.*?</think(?:ing)?>", "", text,
               ignore.case = TRUE, perl = TRUE)
  text <- trimws(text)
  # Extract first JSON object if non-JSON content precedes it
  if (!startsWith(text, "{") && !startsWith(text, "[")) {
    m <- regmatches(text, regexpr("(?s)\\{.*\\}", text, perl = TRUE))
    if (length(m) > 0) text <- m
  }
  # Sanitise unescaped control characters
  text <- gsub("\t", " ", text, fixed = TRUE)
  text <- gsub("\r", "",  text, fixed = TRUE)
  text
}

# ---- Core test function ----
run_test <- function(model, label, think_param = NULL) {
  cat("\n")
  cat(strrep("-", 70), "\n")
  cat(sprintf("MODEL: %-20s  TEST: %s\n", model, label))
  cat(strrep("-", 70), "\n")

  req_body <- list(
    model    = model,
    messages = list(
      list(role = "system", content = SYSTEM_BASE),
      list(role = "user",   content = TEST_PROMPT)
    ),
    stream = FALSE,
    format = "json"
  )
  if (!is.null(think_param)) req_body$think <- think_param

  cat(sprintf("  think param sent: %s\n\n",
              if (!is.null(think_param)) as.character(think_param) else "(not set)"))

  resp <- tryCatch({
    httr2::request(OLLAMA_URL) |>
      httr2::req_body_json(req_body) |>
      httr2::req_timeout(300) |>
      httr2::req_perform()
  }, error = function(e) {
    cat("  REQUEST FAILED:", e$message, "\n")
    return(NULL)
  })

  if (is.null(resp)) return(invisible(NULL))

  body <- httr2::resp_body_json(resp)
  raw  <- body$message$content

  # ---- Thinking field ----
  has_thinking_field <- !is.null(body$message$thinking)
  thinking_len <- if (has_thinking_field) nchar(body$message$thinking %||% "") else 0
  cat(sprintf("  message fields:   %s\n", paste(names(body$message), collapse = ", ")))
  cat(sprintf("  $thinking field:  %s\n",
              if (has_thinking_field && thinking_len > 0)
                sprintf("YES (%d chars)", thinking_len)
              else if (has_thinking_field)
                "present but empty"
              else
                "absent"))

  # ---- Raw content ----
  cat(sprintf("  $content length:  %d chars\n", nchar(raw)))

  # Detect embedded thinking tags in content
  has_channel_tags <- grepl("<\\|channel>", raw, perl = TRUE)
  has_think_tags   <- grepl("<think(?:ing)?>", raw, ignore.case = TRUE, perl = TRUE)
  if (has_channel_tags) cat("  ** <|channel> thinking tags FOUND in content\n")
  if (has_think_tags)   cat("  ** <think> thinking tags FOUND in content\n")
  if (!has_channel_tags && !has_think_tags) cat("  content: no embedded thinking tags\n")

  cat("\n  --- Raw content (first 400 chars) ---\n")
  cat(substr(raw, 1, 400), "\n")

  # ---- Cleanup + parse ----
  cleaned <- pipeline_clean(raw)
  was_modified <- !identical(cleaned, raw)

  cat("\n  --- After pipeline cleanup ---\n")
  if (was_modified) {
    cat("  (thinking stripped / content extracted)\n")
    cat(substr(cleaned, 1, 400), "\n")
  } else {
    cat("  (no change needed)\n")
  }

  parsed <- tryCatch(
    jsonlite::fromJSON(cleaned, simplifyDataFrame = FALSE),
    error = function(e) e
  )

  cat("\n  --- JSON parse ---\n")
  if (inherits(parsed, "error")) {
    cat("  FAILED:", parsed$message, "\n")
  } else {
    cat("  OK. Keys:", paste(names(parsed), collapse = ", "), "\n")
    if (!is.null(parsed$score))
      cat("  score value:", parsed$score, "(check: should be negative)\n")
  }
}

# Null-coalescing helper (base R doesn't have %||%)
`%||%` <- function(a, b) if (!is.null(a)) a else b


# ==============================================================================
# Run tests for each model x thinking config
# ==============================================================================

for (model in MODELS) {
  cat("\n")
  cat(strrep("#", 70), "\n")
  cat(sprintf("## TESTING MODEL: %s\n", model))
  cat(strrep("#", 70), "\n")

  run_test(model, "1 - default (no think param)")
  run_test(model, "2 - think=TRUE",  think_param = TRUE)
  run_test(model, "3 - think=FALSE", think_param = FALSE)
}

cat("\n\n")
cat(strrep("=", 70), "\n")
cat("Debug run complete.\n")
cat(strrep("=", 70), "\n")
