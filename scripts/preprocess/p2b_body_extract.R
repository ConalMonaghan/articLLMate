# ==============================================================================
# STAGE 2b: EXTRACT BODY TEXT (SLIM DOWN THE XML)
# ==============================================================================
#
# PURPOSE:
# Replace each article's bulky raw XML string with a lightweight list holding
# Title / DOI / Text (main-body paragraphs). Logging-aware refactor of
# "PDF XML pipeline/3a. Keep XML Body Only.R": same parsing, but reads levers
# from the master environment and records per-article parse status in the ledger.
#
# EXPECTS (from the master environment):
#   ledger        - the audit ledger (tibble)
#   OUTPUT_DIR    - folder holding <source_batch>_Full.rds (from stage 2a)
#   source_batch  - used to locate the input object and name the output
#
# PRODUCES:
#   ledger        - parse_ok / has_title / has_body / parse_error filled
#   <OUTPUT_DIR>/<source_batch>_Clean.rds - slimmed list keyed by article_id
# ==============================================================================

library(xml2)

in_path  <- file.path(OUTPUT_DIR, paste0(source_batch, "_Full.rds"))
out_path <- file.path(OUTPUT_DIR, paste0(source_batch, "_Clean.rds"))

if (!file.exists(in_path)) {
  stop("p2b_body_extract: expected input not found (run stage 2a first): ", in_path)
}

cat(sprintf("  [OK] Loading metadata object: %s\n", in_path))
db <- readRDS(in_path)
article_keys <- names(db)
total_articles <- length(article_keys)
cat(sprintf("  Extracting body text from %d article(s)...\n", total_articles))

pb <- txtProgressBar(min = 0, max = total_articles, style = 3)
upd <- vector("list", total_articles)
start_time <- Sys.time()

for (i in seq_along(article_keys)) {
  key <- article_keys[i]
  raw_xml <- db[[key]]$XML

  ext_title <- NA_character_
  ext_doi   <- NA_character_
  ext_body  <- NA_character_
  parse_ok  <- FALSE
  parse_err <- NA_character_

  # $XML may already be a slimmed list from a prior run — re-extract only if raw.
  raw_is_string <- is.character(raw_xml) && length(raw_xml) == 1 &&
    !is.na(raw_xml) && nchar(raw_xml) > 10

  if (raw_is_string) {
    tryCatch({
      doc <- read_xml(raw_xml)
      xml_ns_strip(doc)

      title_node <- xml_find_first(doc, "//titleStmt/title[@type='main']")
      if (!is.na(title_node)) ext_title <- xml_text(title_node)

      doi_node <- xml_find_first(doc, "//sourceDesc/biblStruct/idno[@type='DOI']")
      if (!is.na(doi_node)) ext_doi <- xml_text(doi_node)

      body_nodes <- xml_find_all(doc, "//text/body//p")
      if (length(body_nodes) > 0) {
        ext_body <- paste(xml_text(body_nodes), collapse = "\n\n")
      }
      parse_ok <- TRUE
    }, error = function(e) {
      parse_err <<- e$message
    })
  } else if (is.list(raw_xml)) {
    # Already slimmed — carry forward existing fields.
    ext_title <- raw_xml$Title %||% NA_character_
    ext_doi   <- raw_xml$DOI %||% NA_character_
    ext_body  <- raw_xml$Text %||% NA_character_
    parse_ok  <- TRUE
  } else {
    parse_err <- "No usable XML string"
  }

  db[[key]]$XML <- list(Title = ext_title, DOI = ext_doi, Text = ext_body)

  upd[[i]] <- tibble(
    article_id  = key,
    parse_ok    = parse_ok,
    has_title   = !is.na(ext_title),
    has_body    = !is.na(ext_body),
    parse_error = parse_err
  )

  setTxtProgressBar(pb, i)
}

close(pb)
total_duration <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))

saveRDS(db, out_path)
ledger <- ledger_upsert(ledger, bind_rows(upd), stage = "p2b_body_extract")

n_ok   <- sum(isTRUE_vec(ledger$parse_ok))
n_fail <- sum(ledger$parse_ok == FALSE, na.rm = TRUE)
cat(sprintf("\n  [OK] Slimmed object saved: %s\n", out_path))
cat(sprintf("  [SUMMARY] Parsed OK: %d  |  Parse failures: %d  |  Elapsed: %.1fs\n",
            n_ok, n_fail, total_duration))
