# Pre-Processing & Audit Guide

This guide covers the **data-input pipeline** (phases 0–3): turning a PDF corpus
into clean, analysis-ready article objects, with a single **audit ledger** that
follows every article from the original corpus through each stage.

It complements the main analysis run (`_MASTER_RUN_PIPELINE.R`). Where the main
run sends articles to an LLM, this pipeline prepares and audits the articles that
feed it.

## Quick start

1. **Run GROBID (pre-step).** Convert PDFs to XML with
   [`PDF XML pipeline/1_pdf to xml.py`](../PDF%20XML%20pipeline/1_pdf%20to%20xml.py).
   This needs a running GROBID Docker server and is the one step not orchestrated
   by the master (it is GPU- and server-dependent). The master *detects* the
   resulting XML.
2. **Edit the config block** at the top of
   [`_MASTER_PREPROCESS_PIPELINE.R`](../_MASTER_PREPROCESS_PIPELINE.R): set
   `source_batch`, `PDF_DIR`, `XML_DIR`, the stage toggles, and the levers.
3. **Source the whole file.** Each stage writes its status into the ledger, which
   is saved after every stage (crash-safe).

## The audit ledger (the "master sheet")

A single tidy table, one row per article, keyed by `article_id` (the filename
stem — the same key the existing scripts use). Written after every stage as:

- `output/<project>/audit_ledger.csv` — human-readable
- `output/<project>/audit_ledger.rds` — typed, pipeline-consumable

Columns accrue as articles pass through stages; a stage only fills its own
columns, and `ledger_upsert()` merges by `article_id` so **re-runs are
idempotent** (no duplicate rows, earlier values not blanked out).

| Group | Columns |
|-------|---------|
| Identity / provenance | `article_id`, `source_batch`, `ingest_route`, `pdf_path`, `xml_path` |
| Stage 1 (PDF→XML) | `xml_created`, `grobid_status` |
| Stage 2a (DOI/Crossref) | `extracted_doi`, `crossref_doi`, `doi_match`, `meta_found` |
| Stage 2b (body) | `parse_ok`, `has_title`, `has_body`, `parse_error` |
| Stage 2c (length) | `n_words`, `length_status` |
| Stage 2d (content — stub) | `content_flag` |
| Stage 2e (truncate — stub) | `truncated` |
| Stage 3 (tokens) | `n_tokens` |
| Rollup | `final_status`, `exclusion_reason`, `last_stage`, `updated_at` |

## Stages

| Toggle | Script | What it does |
|--------|--------|--------------|
| `run_seed_ledger` | `p0_seed_ledger.R` | Enumerates the original PDF folder to set the **true starting N**. |
| `run_pdf_to_xml` | `p1_pdf_to_xml.R` | Reconciles PDFs against GROBID XML; PDFs with no XML are flagged `grobid_status = "failed"`. |
| `run_crossref` | `p2a_crossref.R` | Extracts the DOI, enriches with Crossref metadata, records extracted-vs-returned DOI agreement. Needs network. |
| `run_body_extract` | `p2b_body_extract.R` | Extracts Title/DOI/body and slims the XML to a lightweight list. |
| `run_content_filter` | `p2d_content_filter.R` | **Stub.** Reserved for TOC/errata/editorial removal. |
| `run_truncate` | `p2e_truncate.R` | **Stub.** Reserved for main-text-only truncation. |
| `run_length_filter` | `p2c_length_filter.R` | Word-count screen (`MIN_WORDS`/`MAX_WORDS`); writes exclusion CSVs. |
| `run_token_profile` | `p3_token_profile.R` | Counts tokens per article (tiktoken via conda env). Needs the conda env. |

Intermediate objects are written to `output/<project>/`:
`<batch>_Full.rds` → `<batch>_Clean.rds` → `<batch>_Screened.rds`.

## Outputs

- `audit_ledger.csv` / `.rds` — the per-article master sheet.
- `preprocess_funnel.csv` — stage-by-stage counts (identification → included).
- `preprocess_summary.txt` — human-readable run report with the funnel and
  exclusion-reason breakdown.
- `run_manifest.json` — reproducibility metadata: R and package versions, the
  GROBID version (read from the TEI header), git commit / branch / dirty state,
  the config levers used, and headline article counts.
- `reports/<batch>_excluded_{short,long}.csv` — length-based exclusions.

## Extending the pipeline

- **Content filter (`p2d`)** and **truncation (`p2e`)** are documented stubs.
  Their ledger columns (`content_flag`, `truncated`) already exist and
  `ledger_finalize()` already treats a non-NA `content_flag` as an exclusion, so
  implementing them is mostly filling in the detection logic.
- **PDF → image route (future branch).** The `ingest_route` lever is reserved for
  sending PDFs straight to a vision model. The ledger is route-agnostic, so an
  image path can populate the same schema and appear in the same funnel. Only
  `"extraction"` is wired up today; any other value stops the pipeline with a
  clear message.

## Not yet handled (flagged during the audit)

- **Deduplication** across publisher batches / duplicate DOIs.
- **PRISMA flow diagram** (the funnel table provides the numbers).
