# ==============================================================================
# STAGE 2a2: LLM DOI RESOLVER (Claude API via ellmer) — residue mop-up
# ==============================================================================
#
# PURPOSE:
# Resolve the DOIs that Stage 2a could not (needs_review): corrupted DOIs and
# blank GROBID headers. For each, Claude reads the article's body text (plus the
# filename and GROBID's garbled header as hints) and reconstructs the true title
# / first author / year. That cleaned metadata drives a Crossref bibliographic
# search, and every candidate is checked by the SAME verifier as Stage 2a —
# so Claude proposes, cr_verify disposes. Nothing unverified is accepted.
#
# EXPECTS (from the master environment):
#   ledger              - the audit ledger (tibble)
#   STAGE_DIRS$crossref - Stage 2a folder (articles.rds + doi_log.csv)
#   STAGE_DIRS$llm      - this stage's folder (02a2_LLM_Resolved)
#   STAGE_OBJECT        - object filename ("articles.rds")
#   PRE_DIR             - preprocess script folder
#   llm_model           - optional Claude model id (else ellmer default)
#
# PRODUCES:
#   ledger              - resolved rows updated (crossref_doi / verified /
#                         resolution_method = "llm_resolved" / needs_review)
#   STAGE_DIRS$crossref/articles.rds + doi_log.csv - updated in place
#   STAGE_DIRS$llm/llm_log.csv        - what Claude proposed + verification
#   STAGE_DIRS$crossref/resolution_summary.csv - per-step DOI counts
# ==============================================================================

library(ellmer)
library(xml2)
library(purrr)
library(readr)
library(dplyr)

source(file.path(PRE_DIR, "doi_resolver.R"))

# Robust .env loader (handles a missing final newline, unlike readRenviron).
if (file.exists(".env") && !nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) {
  for (ln in readLines(".env", warn = FALSE)) {
    if (!grepl("^\\s*[A-Za-z_]", ln)) next
    kv <- sub("^\\s*(export\\s+)?", "", ln)
    key <- trimws(sub("=.*$", "", kv))
    val <- gsub('^["\']|["\']$', "", trimws(sub("^[^=]*=", "", kv)))
    if (nzchar(key)) do.call(Sys.setenv, setNames(list(val), key))
  }
}
if (!nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) {
  stop("p2a2_llm_resolver: ANTHROPIC_API_KEY not set (check .env).")
}

cr_dir  <- STAGE_DIRS$crossref
db_path <- file.path(cr_dir, STAGE_OBJECT)
log_path <- file.path(cr_dir, "doi_log.csv")
if (!file.exists(db_path) || !file.exists(log_path)) {
  stop("p2a2_llm_resolver: run Stage 2a first (missing articles.rds / doi_log.csv).")
}
llm_dir <- STAGE_DIRS$llm
if (!dir.exists(llm_dir)) dir.create(llm_dir, recursive = TRUE)
llm_log_path <- file.path(llm_dir, "llm_log.csv")

temp_db <- readRDS(db_path)
log_df  <- read_csv(log_path, show_col_types = FALSE)
residue <- log_df$article_id[log_df$needs_review]
cat(sprintf("  [OK] %d article(s) need LLM resolution.\n", length(residue)))

if (length(residue) == 0) {
  cat("  Nothing to do.\n")
} else {
  sys_prompt <- paste(
    "You extract bibliographic metadata from the raw text of a single academic",
    "article that may contain OCR errors. Use the filename, the (possibly garbled)",
    "GROBID header, and the article body to determine the article's OWN metadata.",
    "Ignore reference lists. Do not fabricate: if a field is genuinely unknown,",
    "return an empty string.")
  spec <- type_object(
    title        = type_string("The article's full title"),
    first_author = type_string("Surname of the first author only"),
    year         = type_string("Four-digit publication year"),
    journal      = type_string("Journal / container name")
  )

  llm_rows <- list()
  pb <- txtProgressBar(min = 0, max = length(residue), style = 3)

  for (j in seq_along(residue)) {
    id <- residue[j]
    raw <- temp_db[[id]]$XML
    if (is.null(raw) || is.na(raw)) { setTxtProgressBar(pb, j); next }

    doc <- tryCatch(read_xml(raw), error = function(e) NULL)
    if (is.null(doc)) { setTxtProgressBar(pb, j); next }
    xml_ns_strip(doc)
    xm0  <- xml_article_meta(doc)
    body <- paste(xml_text(xml_find_all(doc, "//text/body//p")), collapse = " ")

    # Filename gives reliable anchors (surname + year) for verifying the residue.
    xm_anchor <- list(title = strip_supp_title(xm0$title %||% ""),
                      surname = surname_from_id(id), year = year_from_id(id),
                      journal = xm0$journal %||% NA_character_)

    resolved_doi <- NA_character_; meta <- list(); ok <- FALSE
    method_used <- NA_character_; out <- NULL

    # --- Attempt A: repair the corrupted DOI and anchor-verify (NO LLM call) ---
    raw_doi <- xm0$doi
    if (!is.na(raw_doi) && nzchar(raw_doi)) {
      for (cd in unique(c(normalize_doi(raw_doi), doi_repair_candidates(raw_doi)))) {
        d <- tryCatch(suppressWarnings(cr_works(cd)$data), error = function(e) NULL)
        if (!is.null(d) && nrow(d) > 0 && verified_anchor(cr_verify(xm_anchor, d))) {
          resolved_doi <- d$doi[1]; meta <- d; ok <- TRUE; method_used <- "doi_regex_fixed"; break
        }
      }
    }

    # --- Attempt B: Claude reconstructs metadata -> Crossref search (only if A failed) ---
    if (!ok) {
      prompt <- paste0(
        "Filename (author surname, year, title fragment):\n  ", id, "\n\n",
        "GROBID header (may be empty/garbled):\n  title: ", xm0$title %||% "",
        "\n  author: ", xm0$surname %||% "", "\n\n",
        "Article body opening:\n", substr(body, 1, 4000), "\n\n",
        "Give the article's true full title, first-author surname, four-digit year, and journal.")
      out <- tryCatch(chat_anthropic(system_prompt = sys_prompt,
                                     model = if (exists("llm_model")) llm_model else NULL
                      )$chat_structured(prompt, type = spec),
                      error = function(e) NULL)
      xm_llm <- list(
        title   = if (!is.null(out) && nzchar(out$title)) out$title else xm_anchor$title,
        surname = if (!is.null(out) && nzchar(out$first_author)) out$first_author else xm_anchor$surname,
        year    = if (!is.null(out) && nzchar(out$year)) out$year else xm_anchor$year,
        journal = if (!is.null(out) && nzchar(out$journal)) out$journal else NA_character_
      )
      if (!nzchar(xm_llm$surname %||% "")) xm_llm$surname <- xm_anchor$surname
      if (!nzchar(xm_llm$year %||% ""))    xm_llm$year <- xm_anchor$year

      if (nzchar(canon(xm_llm$title))) {
        cand <- tryCatch(suppressWarnings(
          cr_works(flq = c(`query.bibliographic` = xm_llm$title,
                           `query.author` = xm_llm$surname %||% ""), limit = 5)$data),
          error = function(e) NULL)
        if (!is.null(cand) && nrow(cand) > 0) {
          for (i in seq_len(nrow(cand))) {
            if (verified_bib(cr_verify(xm_llm, cand[i, ]))) {
              resolved_doi <- cand$doi[i]; meta <- cand[i, ]; ok <- TRUE; method_used <- "llm_resolved"; break
            }
          }
        }
      }
    }

    # --- Attempt C: Claude web search (opt-in) — only if A & B failed ---------
    if (!ok && exists("llm_web_search") && isTRUE(llm_web_search)) {
      ws <- chat_anthropic(
        system_prompt = paste("Find the DOI of the described journal article using web search.",
                              "Reply with ONLY the DOI (format 10.xxxx/...) or the word NONE."),
        model = if (exists("llm_model")) llm_model else NULL)
      ws$register_tool(claude_tool_web_search())
      qtext <- paste0(
        "Filename: ", id,
        "\nBest-known title: ", (if (exists("xm_llm")) xm_llm$title else xm_anchor$title) %||% "",
        "\nFirst author: ", xm_anchor$surname, " | Year: ", xm_anchor$year,
        "\nOpening text: ", substr(body, 1, 1200),
        "\n\nSearch the web and reply with ONLY the article's DOI, or NONE.")
      resp <- tryCatch(ws$chat(qtext, echo = "none"), error = function(e) NULL)
      if (!is.null(resp)) {
        hits <- regmatches(resp, gregexpr("10\\.\\d{4,9}/[^\\s\"'<>)\\]]+", resp, perl = TRUE))[[1]]
        hits <- unique(sub("[.,;]+$", "", hits))
        for (dg in hits) {
          d <- tryCatch(suppressWarnings(cr_works(dg)$data), error = function(e) NULL)
          if (!is.null(d) && nrow(d) > 0 && verified_anchor(cr_verify(xm_anchor, d))) {
            resolved_doi <- d$doi[1]; meta <- d; ok <- TRUE; method_used <- "llm_web_search"; break
          }
        }
      }
    }

    if (ok) {
      temp_db[[id]]$META <- meta
      temp_db[[id]]$RESOLVED_DOI <- resolved_doi
      log_df$doi_resolved[log_df$article_id == id]      <- resolved_doi
      log_df$resolution_method[log_df$article_id == id] <- method_used
      log_df$verified[log_df$article_id == id]          <- TRUE
      log_df$needs_review[log_df$article_id == id]       <- FALSE
    }
    llm_rows[[id]] <- tibble(
      article_id = id, method = method_used %||% "unresolved",
      used_llm = !is.null(out),
      llm_title = out$title %||% NA, llm_author = out$first_author %||% NA,
      llm_year = out$year %||% NA, llm_journal = out$journal %||% NA,
      resolved_doi = resolved_doi, verified = ok)
    setTxtProgressBar(pb, j)
  }
  close(pb)

  saveRDS(temp_db, db_path)
  write_csv(log_df, log_path)
  write_csv(bind_rows(llm_rows), llm_log_path)

  # Fold rows resolved in this stage (regex-anchored or LLM) into the ledger.
  newly <- log_df |> filter(resolution_method %in% c("llm_resolved", "doi_regex_fixed"),
                            article_id %in% residue) |>
    transmute(article_id, crossref_doi = doi_resolved, meta_found = TRUE,
              resolution_method, verified = TRUE, needs_review = FALSE)
  if (nrow(newly) > 0) ledger <- ledger_upsert(ledger, newly, stage = "p2a2_llm_resolver")

  llm_tbl <- bind_rows(llm_rows)
  n_ok    <- sum(llm_tbl$verified)
  n_llm   <- sum(llm_tbl$verified & llm_tbl$method == "llm_resolved")
  n_regex <- sum(llm_tbl$verified & llm_tbl$method == "doi_regex_fixed")
  cat(sprintf("\n  [OK] Residue resolved: %d / %d  (regex %d, claude %d; LLM calls made: %d)\n",
              n_ok, length(residue), n_regex, n_llm, sum(llm_tbl$used_llm)))
  cat(sprintf("  [OK] LLM log: %s\n", llm_log_path))
}

# ---- Per-step DOI resolution summary (crossref / regex / claude / ...) --------
summary_tbl <- doi_resolution_summary(log_df)
write_csv(summary_tbl, file.path(cr_dir, "resolution_summary.csv"))
cat("\n  [SUMMARY] DOIs resolved per step:\n")
print(summary_tbl |> count(step, wt = n, name = "resolved"))
cat(sprintf("  Remaining needs_review: %d\n", sum(log_df$needs_review)))
