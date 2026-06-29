# So You Want to Batch

A step-by-step guide for using batch mode to process large numbers of articles at **50% off** the standard API price.

---

## Why Batch?

| | Standard API (03a) | Batch API (03c → 03d → 03e) |
|--|---------------------|------------------------------|
| **Cost** | Full price | **50% cheaper** |
| **Speed per article** | ~2-10 seconds | Queued, up to 24 hours |
| **Rate limits** | RPM/RPD quotas apply | Separate quota (enqueued tokens) |
| **Crash recovery** | Per-article JSON saves | Entire chunk retried as one unit |
| **Best for** | Small runs, testing | Large runs (100+ articles) |

Batch mode is ideal when you don't need results immediately and want to save money on large corpora.

---

## Prerequisites

### API Keys

Add your key to the `.env` file in the project root:

```
# For Gemini batch:
GEMINI_API_KEY=your-key-here

# For OpenAI batch:
OPENAI_API_KEY=sk-your-key-here
```

### Python Packages

The conda environment needs the right SDK installed:

- **Gemini**: `google-genai` (NOT `google-generativeai` — that's the older SDK)
- **OpenAI**: `openai`

Install if missing:
```bash
conda activate articLLMate
pip install google-genai    # For Gemini batch
pip install openai          # For OpenAI batch
```

### API Tier Requirements

Batch is NOT available on free tiers. You need a paid account.

**Gemini Tiers:**

| Tier | Access | Enqueued Token Limit | How to Qualify |
|------|--------|---------------------|----------------|
| Free | No batch access | 0 | — |
| Tier 1 | Basic batch | 3–10 million tokens | Enable billing |
| Tier 2 | Production batch | 400M–1 billion tokens | $250 cumulative spend + 30 days |
| Tier 3 | Enterprise batch | 1–5 billion tokens | $1,000 cumulative spend + 30 days |

For a typical run of 1,000 articles (~5,000 tokens each), you need ~5 million enqueued tokens — Tier 1 can handle this but just barely. Tier 2 is recommended for larger corpora.

**OpenAI Tiers:**

| Tier | Enqueued Tokens | How to Qualify |
|------|----------------|----------------|
| Tier 1 | 2.5 million | $5 spend |
| Tier 2 | 10 million | $50 spend + 7 days |
| Tier 3 | 100 million | $100 spend + 7 days |
| Tier 4 | 500 million | $250 spend + 14 days |
| Tier 5 | 5 billion | $1,000 spend + 30 days |

---

## File Size and Request Limits

### Gemini

| Limit | Value |
|-------|-------|
| Max JSONL file size | **2 GB** |
| Max inline request size | 20 MB (we use file upload, so N/A) |
| Max concurrent batch jobs | **100** per project |
| Job expiration | **48 hours** (job fails with no results if exceeded) |
| Processing SLO | 24 hours (most jobs finish faster) |

### OpenAI

| Limit | Value |
|-------|-------|
| Max JSONL file size | **100 MB** |
| Max requests per batch | **50,000** |
| Max concurrent batches | **100** |
| Completion window | **24 hours** |

### How the Scripts Handle This

`03c_build_batch_jsonl.R` automatically chunks your articles into multiple JSONL files based on:
- **Max file size**: 1.5 GB (safety margin under the 2 GB Gemini limit)
- **Max requests per file**: 30,000

For OpenAI's stricter 100 MB limit, you may want to reduce these in the script:
```r
BATCH_MAX_FILE_SIZE <- 90e6    # 90 MB (safety margin under 100 MB)
BATCH_MAX_REQUESTS  <- 30000   # Well under OpenAI's 50,000 cap
```

---

## The Workflow

### Step 1: Build JSONL Files (03c)

Configure and run the master pipeline with `batch_mode <- TRUE`:

```r
# In _MASTER_RUN_PIPELINE.R:
execution_mode <- "api"
batch_mode     <- TRUE
api_provider   <- "gemini"       # or "openai"
model_id       <- "gemini-2.5-flash"  # or "gpt-4.1-mini"
```

Source the master script. It will:
1. Discover articles (Step 1)
2. Load the prompt (Step 2)
3. Build JSONL files (Step 3c) — then **stop**

Output:
```
output/my_project/
├── batch_input/
│   ├── batch_input_001.jsonl    # First chunk
│   ├── batch_input_002.jsonl    # Second chunk (if needed)
│   └── ...
└── batch_manifest.rds           # Metadata for 03d and 03e
```

**Inspect the JSONL** before spending money. Open `batch_input_001.jsonl` in a text editor and spot-check a few lines. Each line is a self-contained API request in JSON format.

### Step 2: Submit Batch Jobs (03d)

Submit one chunk at a time. Open a new R script (or the console) and run:

```r
library(here)
library(reticulate)
library(jsonlite)
library(tictoc)

# Point to your conda env
use_condaenv("articLLMate", required = TRUE)

# Set the chunk to submit
JSONL_FILE <- here("output", "my_project", "batch_input", "batch_input_001.jsonl")
OUTPUT_DIR <- here("output", "my_project")

# Run
source(here("scripts", "03d_submit_batch.R"))
```

The script will:
1. Upload the JSONL file to the API
2. Create a batch job
3. Poll for completion (printing status updates)
4. Download the result JSONL to `batch_output/`

**You can close RStudio while the job runs.** The batch job lives on the API's servers. If you need to check on it later, you can use the job metadata saved in `batch_job_meta_001.rds`.

### Step 3: Wait and Submit More Chunks

If you have multiple chunks:

1. Wait for chunk 001 to complete (or at least for your enqueued token quota to free up)
2. Change `JSONL_FILE` to `batch_input_002.jsonl` and re-run 03d
3. Repeat for all chunks

**Pacing tips:**
- Gemini: You can submit multiple jobs concurrently (up to 100), but your enqueued token quota is the real bottleneck. If you get a `429 RESOURCE_EXHAUSTED` error, wait for running jobs to finish.
- OpenAI: Same idea — concurrent batches allowed, but token quota limits apply.
- If a job expires (48h for Gemini, 24h for OpenAI), just resubmit the same JSONL file.

### Step 4: Parse Results (03e)

Once ALL chunks are downloaded, combine them:

```r
library(here)
library(jsonlite)

OUTPUT_DIR <- here("output", "my_project")
source(here("scripts", "03e_parse_batch_results.R"))
```

This creates:
- Individual `.json` files per article (same as 03a)
- `{project_name}_results.rds` — the standard results list
- `results_list`, `errors_log`, etc. in your R environment

### Step 5: Post-Processing (Steps 4–6)

Now run the normal post-processing scripts:

```r
# Load the table config (if not already loaded)
table_config_file <- "prompts/prompt Valid.yml"

source(here("scripts", "04_generate_summary.R"))
source(here("scripts", "05_post_processing.R"))
source(here("scripts", "06_build_results_object.R"))
```

These work identically whether results came from 03a (one-by-one), 03b (local), or 03e (batch).

---

## JSONL Format Reference

The JSONL format is different for each provider. You **cannot** use a Gemini JSONL with OpenAI or vice versa.

### Gemini JSONL

Each line:
```json
{
  "key": "article_identifier",
  "request": {
    "contents": [{"parts": [{"text": "Analyze this paper..."}]}],
    "systemInstruction": {"parts": [{"text": "You are an expert..."}]},
    "generationConfig": {"responseMimeType": "application/json", "temperature": 0.1}
  }
}
```

### OpenAI JSONL

Each line:
```json
{
  "custom_id": "article_identifier",
  "method": "POST",
  "url": "/v1/chat/completions",
  "body": {
    "model": "gpt-4.1-mini",
    "messages": [
      {"role": "system", "content": "You are an expert..."},
      {"role": "user", "content": "Analyze this paper..."}
    ],
    "response_format": {"type": "json_object"},
    "temperature": 0.1
  }
}
```

---

## Troubleshooting

### "GEMINI_API_KEY not set"

Add it to your `.env` file. Make sure there are no spaces around the `=`:
```
GEMINI_API_KEY=AIzaSy...
```

### "429 RESOURCE_EXHAUSTED" (Gemini)

You've hit your enqueued token quota. Wait for running batch jobs to complete before submitting more. Check your tier limits in the [Gemini rate limits page](https://ai.google.dev/gemini-api/docs/rate-limits).

### Job expired (48h Gemini / 24h OpenAI)

The job took too long and was killed with no results. This can happen during high-traffic periods. Just resubmit the same JSONL file — it's idempotent.

### "batch_manifest.rds not found"

You need to run `03c_build_batch_jsonl.R` (via the master pipeline with `batch_mode <- TRUE`) before running 03d or 03e.

### "No batch_output_*.jsonl files found"

You haven't submitted and downloaded any batch jobs yet. Run `03d_submit_batch.R` for each chunk first.

### Some articles missing from results

Check:
- Did you submit ALL chunks? The manifest tells you how many chunks were created (`manifest$n_chunks`).
- Did any jobs fail? Check the `batch_job_meta_NNN.rds` files for status.
- Did any individual requests fail within a successful job? The 03e parser logs these as `API_ERROR` in `errors_log`.

### Gemini systemInstruction not working

There's a known bug ([googleapis/python-genai#1190](https://github.com/googleapis/python-genai/issues/1190)) where `systemInstruction` may be ignored in batch requests. If your results look like the model didn't receive the system prompt:

1. Open `03c_build_batch_jsonl.R`
2. Set `BATCH_SYSTEM_PROMPT_INLINE <- TRUE`
3. Re-run 03c to rebuild the JSONL files

This inlines the system prompt directly into the user message as a workaround.

### OpenAI batch validation errors

OpenAI validates each line of the JSONL before starting the batch. Common issues:
- Invalid model name — double-check `model_id` matches an available model
- Message format errors — usually means the JSONL was corrupted; rebuild with 03c

---

## Cost Comparison

Rough estimates for processing 1,000 articles (~5,000 tokens input + ~2,000 tokens output each):

| Provider | Model | Standard (03a) | Batch (03c-e) | Savings |
|----------|-------|---------------|---------------|---------|
| Gemini | gemini-2.5-flash | ~$1.00 | ~$0.50 | 50% |
| Gemini | gemini-2.5-pro | ~$12.50 | ~$6.25 | 50% |
| OpenAI | gpt-4.1-mini | ~$2.80 | ~$1.40 | 50% |
| OpenAI | gpt-4.1 | ~$25.00 | ~$12.50 | 50% |

Gemini also offers implicit caching on repeated content (like your system prompt), which can reduce input token costs by up to 75% on top of the batch discount.

---

## Quick Reference

```
┌─────────────────────────────────────────────────┐
│  BATCH WORKFLOW                                 │
│                                                 │
│  1. Set batch_mode <- TRUE in master script     │
│  2. Source master script                        │
│     └─→ Creates batch_input/*.jsonl             │
│                                                 │
│  3. For each chunk:                             │
│     JSONL_FILE <- "...batch_input_001.jsonl"    │
│     source("scripts/03d_submit_batch.R")        │
│     └─→ Uploads, submits, polls, downloads      │
│     └─→ Creates batch_output/batch_output_001   │
│     (wait for quota, then do next chunk)        │
│                                                 │
│  4. When all chunks done:                       │
│     source("scripts/03e_parse_batch_results.R") │
│     └─→ Creates results_list + RDS              │
│                                                 │
│  5. Run Steps 4-6 as normal                     │
│     source("scripts/04_generate_summary.R")     │
│     source("scripts/05_post_processing.R")      │
│     source("scripts/06_build_results_object.R") │
└─────────────────────────────────────────────────┘
```
