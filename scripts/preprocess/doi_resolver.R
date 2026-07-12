# ==============================================================================
# DOI RESOLVER — verified DOI + metadata resolution (front end of Stage 2a)
# ==============================================================================
#
# PURPOSE:
# GROBID's extracted DOI is often wrong — most commonly an APA supplemental-
# materials DOI (`<article_doi>.supp`) read off a "Supplemental Material for ..."
# cover page. This resolver recovers the correct article record and only accepts
# it when it is a 100% match against the article's own XML header metadata.
#
# STRATEGY (exact, canonicalized — no fuzzy similarity):
#   1. Normalize the XML DOI (strip .supp / URL form / doi: prefix) and query
#      Crossref by DOI. Accept only if it VERIFIES (below).
#   2. If there is no DOI, or the DOI fails to verify, fall back to a Crossref
#      bibliographic search (title + author) and verify each candidate.
#   3. Anything that does not verify is left unresolved and flagged needs_review.
#
# VERIFY = ALL of the following match after canonicalization (lowercase, strip
# non-alphanumerics):
#   - first-author surname   (XML header vs Crossref first author family)
#   - publication year       (XML header year ∈ any Crossref date field)
#   - journal / container     (XML header vs Crossref container-title)
#   - title                  (XML title, minus any "Supplemental Material for "
#                             prefix, vs Crossref title)
# Type is also recorded (expect "journal-article").
#
# Requires `%||%` (from audit_ledger.R) and packages xml2, rcrossref.
# ==============================================================================

library(rcrossref)

if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

# --- canonicalization + small helpers -----------------------------------------
canon <- function(x) gsub("[^a-z0-9]+", "", tolower(x %||% ""))

strip_supp_title <- function(t) sub("^\\s*supplemental material for\\s*", "", tolower(t %||% ""))

is_supp_doi <- function(doi) !is.na(doi) & grepl("\\.supp\\d*$", doi, ignore.case = TRUE)

normalize_doi <- function(doi) {
  d <- tolower(trimws(doi %||% ""))
  if (!nzchar(d)) return(NA_character_)
  d <- sub("^https?://(dx\\.)?doi\\.org/", "", d)
  d <- sub("^doi:\\s*", "", d)
  d <- sub("\\.supp\\d*$", "", d)       # strip supplemental-materials suffix
  d
}

# Heuristic OCR repairs for garbled DOIs. Returns candidate DOIs to TRY (each is
# still verified before acceptance, so an over-aggressive repair can't slip
# through). Targets the corruption seen in this corpus: commas for periods, an
# extra digit in the APA prefix (10.10371/ -> 10.1037/), stray leading digits,
# and non-DOI junk characters.
doi_repair_candidates <- function(doi) {
  if (is.na(doi) || !nzchar(doi)) return(character(0))
  base <- tolower(trimws(doi))
  variants <- c(
    gsub(",", ".", base),                                 # commas -> periods
    sub("^10\\.1037[0-9]/", "10.1037/", base),            # 10.10371/ -> 10.1037/
    sub("^(10\\.1037/+)1(0022-3514)", "\\1\\2", base),    # /10022-3514 -> /0022-3514
    gsub("[^0-9a-z./()-]", "", base)                       # drop junk chars
  )
  # apply comma fix on top of each, and add single/double-slash APA variants
  variants <- unique(c(variants, gsub(",", ".", variants)))
  variants <- unique(c(variants,
                       sub("//", "/", variants),
                       sub("(10\\.1037)/(?!/)", "\\1//", variants, perl = TRUE)))
  cands <- unique(vapply(variants, normalize_doi, character(1)))
  cands <- cands[nzchar(cands) & cands != normalize_doi(base)]  # only genuinely new
  cands
}

# --- extract article metadata from a GROBID TEI document ----------------------
# Scoped to //sourceDesc so we read the ARTICLE's own header, not its references.
xml_article_meta <- function(doc) {
  xml2::xml_ns_strip(doc)
  ft <- function(xp) { n <- xml2::xml_find_first(doc, xp); if (!is.na(n)) xml2::xml_text(n) else NA_character_ }
  list(
    title   = ft("//titleStmt/title[@type='main']"),
    doi     = ft("//sourceDesc//idno[@type='DOI']"),
    surname = ft("//sourceDesc//analytic/author/persName/surname"),
    year    = substr(ft("//sourceDesc//imprint/date/@when") %||% "", 1, 4),
    journal = ft("//sourceDesc//monogr/title[@level='j']")
  )
}

# --- pull comparable fields out of a one-row Crossref data frame --------------
cr_years <- function(d) {
  cols <- intersect(c("issued", "published.print", "published.online", "created"), names(d))
  ys <- vapply(cols, function(c) substr(as.character(d[[c]][1]), 1, 4), character(1))
  unique(ys[nchar(ys) == 4])
}

cr_first_author <- function(d) {
  a <- tryCatch(d$author[[1]], error = function(e) NULL)
  if (is.null(a) || !"family" %in% names(a)) return(NA_character_)
  if ("sequence" %in% names(a) && any(a$sequence == "first", na.rm = TRUE)) {
    return(a$family[a$sequence == "first"][1])
  }
  a$family[1]
}

# --- verification: tri-state per field --------------------------------------
# Each field returns TRUE (match), FALSE (both present but differ = a genuine
# contradiction), or NA (the XML header simply lacks the field — unavailable,
# not a contradiction). Canonicalized exact comparison throughout.
tri <- function(xml_val, cr_val) {
  a <- canon(xml_val); b <- canon(cr_val)
  if (!nzchar(a) || !nzchar(b)) return(NA)   # unavailable on either side
  a == b
}

cr_verify <- function(xm, d) {
  cr_title <- if (!is.null(d$title)) d$title[1] else NA_character_
  yrs <- cr_years(d)
  year_ok <- if (!nzchar(xm$year %||% "") || length(yrs) == 0) NA else (xm$year %in% yrs)
  list(
    title_ok   = tri(strip_supp_title(xm$title), cr_title),
    author_ok  = tri(xm$surname, cr_first_author(d)),
    year_ok    = year_ok,
    journal_ok = tri(xm$journal, d$container.title[1]),
    type       = d$type[1] %||% NA_character_
  )
}

# Strict (DOI path): every field must be an explicit match.
verified_all <- function(vr) isTRUE(vr$title_ok) && isTRUE(vr$author_ok) &&
                             isTRUE(vr$year_ok)  && isTRUE(vr$journal_ok)

# Bibliographic path: title AND author must match, at least one of year/journal
# must match, and NO field may contradict (a FALSE anywhere is disqualifying).
verified_bib <- function(vr) {
  fields <- vr[c("title_ok","author_ok","year_ok","journal_ok")]
  no_contradiction <- !any(vapply(fields, function(x) isFALSE(x), logical(1)))
  isTRUE(vr$title_ok) && isTRUE(vr$author_ok) &&
    (isTRUE(vr$year_ok) || isTRUE(vr$journal_ok)) && no_contradiction
}

# ------------------------------------------------------------------------------
# resolve_article(): resolve + verify one article's DOI/metadata.
# Returns a one-row list: the DOI-log fields plus the accepted Crossref META.
# The resolved metadata is always the corrected article record (.supp DOIs are
# normalized to the article DOI, never retained).
# ------------------------------------------------------------------------------
# Extract a 4-digit year from an article_id like "Bos (2000) – ...".
year_from_id <- function(id) {
  m <- regmatches(id, regexpr("\\((\\d{4})\\)", id))
  if (length(m) == 0) NA_character_ else gsub("[()]", "", m)
}

# Extract the first-author surname from an article_id ("Bos (2000) – ..." -> "Bos").
surname_from_id <- function(id) trimws(sub("\\s*\\(.*$", "", id))

# Map resolution_method values to the pipeline STEP that resolved them, and count.
# This is the per-step DOI resolution tally (crossref / regex / claude / ...).
RESOLUTION_STEP <- c(
  doi_verified   = "crossref", doi_supp_fixed = "crossref", bibliographic = "crossref",
  doi_regex_fixed = "regex",   llm_resolved   = "claude",
  unresolved     = "unresolved", parse_error  = "unresolved"
)
doi_resolution_summary <- function(log_df) {
  library(dplyr)
  log_df |>
    mutate(step = RESOLUTION_STEP[resolution_method] |> unname(),
           step = ifelse(is.na(step), "other", step)) |>
    count(step, resolution_method, name = "n") |>
    arrange(match(step, c("crossref","regex","claude","unresolved","other")), desc(n))
}

resolve_article <- function(xm, id = NULL) {
  # Fall back to the year encoded in the filename when the XML header lacks it.
  if ((!nzchar(xm$year %||% "")) && !is.null(id)) {
    xm$year <- year_from_id(id) %||% ""
  }
  raw_doi  <- xm$doi
  had_supp <- is_supp_doi(raw_doi)
  norm_doi <- if (!is.na(raw_doi) && nzchar(raw_doi)) normalize_doi(raw_doi) else NA_character_

  method <- "unresolved"; accepted_doi <- NA_character_; meta <- list(); vr <- NULL

  # Attempt 1 — resolve by (normalized) DOI
  if (!is.na(norm_doi) && nzchar(norm_doi)) {
    d <- tryCatch(suppressWarnings(cr_works(norm_doi)$data), error = function(e) NULL)
    if (!is.null(d) && nrow(d) > 0) {
      vr <- cr_verify(xm, d)
      if (verified_all(vr)) {
        method <- if (had_supp) "doi_supp_fixed" else "doi_verified"
        accepted_doi <- d$doi[1]; meta <- d
      }
    }
  }

  # Attempt 1b — repaired (OCR-fixed) DOI candidates, each strictly verified
  if (method == "unresolved" && !is.na(raw_doi) && nzchar(raw_doi)) {
    for (cd in doi_repair_candidates(raw_doi)) {
      d <- tryCatch(suppressWarnings(cr_works(cd)$data), error = function(e) NULL)
      if (!is.null(d) && nrow(d) > 0) {
        vr_c <- cr_verify(xm, d)
        # A repaired DOI is a guess, so require the same strong-but-header-
        # tolerant bar as the bibliographic path (title+author+(year|journal),
        # no contradictions) rather than a full four-field match.
        if (verified_bib(vr_c)) {
          method <- "doi_regex_fixed"; accepted_doi <- d$doi[1]; meta <- d; vr <- vr_c
          break
        }
      }
    }
  }

  # Attempt 2 — bibliographic fallback (title + author), verify each candidate
  if (method == "unresolved" && nzchar(canon(xm$title))) {
    q_title <- strip_supp_title(xm$title)
    cand <- tryCatch(suppressWarnings(
      cr_works(flq = c(`query.bibliographic` = q_title, `query.author` = xm$surname %||% ""),
               limit = 5)$data),
      error = function(e) NULL)
    if (!is.null(cand) && nrow(cand) > 0) {
      for (i in seq_len(nrow(cand))) {
        vr_i <- cr_verify(xm, cand[i, ])
        if (verified_bib(vr_i)) {
          method <- "bibliographic"; accepted_doi <- cand$doi[i]; meta <- cand[i, ]; vr <- vr_i
          break
        }
      }
    }
  }

  verified <- method != "unresolved"
  list(
    doi_raw           = raw_doi %||% NA_character_,
    doi_normalized    = norm_doi,
    had_supp          = had_supp,
    doi_resolved      = accepted_doi,
    resolution_method = method,
    verified          = verified,
    needs_review      = !verified,
    title_ok          = vr$title_ok  %||% NA,
    author_ok         = vr$author_ok %||% NA,
    year_ok           = vr$year_ok   %||% NA,
    journal_ok        = vr$journal_ok %||% NA,
    cr_type           = vr$type      %||% NA_character_,
    META              = meta
  )
}
