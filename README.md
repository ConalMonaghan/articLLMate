# articLLMate

## Overview

articLLMate analyses academic research papers using an LLM to audit how authors handle response-validity threats in self-report data. Point it at a folder of `.xml` articles, choose a prompt, and run `_MASTER_RUN_PIPELINE.R`.

---

## Quick Start

1. **First-time setup** - run `Reticulate Setup.R` to create the conda environment.
2. **API key** - create a `.env` file in the project root:
   ```
   OPENAI_API_KEY=sk-your-key-here
   ```
   (Git-ignored. Get your key from <https://platform.openai.com/api-keys>.)
3. **Configure** - edit the USER CONFIGURATION block in `_MASTER_RUN_PIPELINE.R`.
4. **Run** - source the master script (`Ctrl+Shift+S` in RStudio).

---

## File Structure

```
articLLMate/
├── _MASTER_RUN_PIPELINE.R        # Single entry point - run this
├── Reticulate Setup.R            # One-time conda environment creation
├── use_existing_python.R         # Alternative: use an existing Python install
│
├── prompts/
│   ├── prompt Valid              # Current prompt (response-validity audit)
│   └── prompt DC                 # Legacy prompt (dimensional/categorical)
│
├── scripts/                      # Modular pipeline steps (sourced by master)
│   ├── 00_check_environment.R
│   ├── 01_discover_articles.R
│   ├── 02_select_prompt.R
│   ├── 03a_run_analysis_api.R    # One-by-one API calls (OpenAI/Anthropic/Gemini)
│   ├── 03b_run_analysis_local.R  # Local Ollama inference
│   ├── 03c_build_batch_jsonl.R   # Build JSONL for batch API (no API calls)
│   ├── 03d_submit_batch.R        # Submit one JSONL chunk → poll → download
│   ├── 03e_parse_batch_results.R # Combine batch outputs into standard RDS
│   ├── 04_generate_summary.R
│   ├── 05_post_processing.R
│   └── _legacy/                  # Archived earlier scripts
│
├── docs/
│   └── batch_guide.md            # "So You Want to Batch" — full walkthrough
│
├── input/
│   ├── Test xml files/           # Small set of test XMLs
│   └── pilot_sample/             # Full corpus (~1,000 XMLs)
│
├── output/                       # Created automatically per run
│   └── {project_name}/
│       ├── *.json                # One JSON per paper (crash-safe)
│       ├── batch_input/          # JSONL chunks (batch mode only)
│       ├── batch_output/         # Results from batch API (batch mode only)
│       ├── {project_name}_results.rds
│       ├── {project_name}_summary.txt
│       └── {project_name}_results.csv
│
├── Loop.R                        # Legacy (superseded by master pipeline)
└── Thematic_Analysis_Loop.R      # Legacy (superseded by master pipeline)
```

---

## Pipeline Steps

The master script sources each step in order. Every step lives in `scripts/` and communicates through R variables set in the shared environment.

| Step | Script | Purpose | Key Inputs | Key Outputs |
|------|--------|---------|------------|-------------|
| 0 | `00_check_environment.R` | Validate conda env, Python packages, API key, GPU | `env_name`, `api_provider` | `gpu_status` |
| 1 | `01_discover_articles.R` | Find all `.xml` files in the input folder | `INPUT_DIR` | `xml_files`, `n_articles` |
| 2 | `02_select_prompt.R` | Read the prompt file and preview it | `prompt_file` | `prompt_text` |
| 3a | `03a_run_analysis_api.R` | One-by-one API calls | articles, `prompt_text`, `model_id` | `results_list`, `.json` files |
| 3b | `03b_run_analysis_local.R` | Local Ollama inference | articles, `prompt_text`, `model_id` | `results_list`, `.json` files |
| 3c | `03c_build_batch_jsonl.R` | Build JSONL for batch API (no API calls) | articles, `prompt_text`, `model_id` | JSONL files, `batch_manifest.rds` |
| 3d | `03d_submit_batch.R` | Submit one JSONL chunk, poll, download result | JSONL file, manifest | `batch_output_NNN.jsonl` |
| 3e | `03e_parse_batch_results.R` | Combine batch outputs into standard RDS | batch outputs, manifest | `results_list`, `.json` files |
| 4 | `04_generate_summary.R` | Write a human-readable run report | `results_list`, `project_name` | `{project_name}_summary.txt` |
| 5 | `05_post_processing.R` | Flatten nested JSON results into three CSVs using the table mapping | `results_list`, `table_config_file` | `{project_name}_main.csv`, `_metadata.csv`, `_detail.csv` |

---

## User Configuration

All settings live at the top of `_MASTER_RUN_PIPELINE.R`:

| Variable | Example | Description |
|----------|---------|-------------|
| `project_name` | `"short_test"` | Name for the output subfolder |
| `env_name` | `"articLLMate"` | Conda environment name |
| `execution_mode` | `"api"` | `"api"` (remote) or `"local"` (Ollama) |
| `api_provider` | `"openai"` | `"openai"`, `"anthropic"`, or `"gemini"` |
| `batch_mode` | `FALSE` | `TRUE` = build JSONL for batch API (Gemini/OpenAI, 50% cheaper) |
| `model_id` | `"gpt-4.1-mini"` | Model to use |
| `prompt_file` | `"prompts/prompt Valid"` | Path to prompt file (relative to project root) |
| `table_config_file` | `"prompts/prompt Valid.yml"` | YAML file mapping JSON fields to output tables (main/metadata/detail) |
| `INPUT_DIR` | `here("input", "Test xml files")` | Folder containing `.xml` articles |
| `OUTPUT_DIR` | `here("output", project_name)` | Output folder (auto-created) |
| `save_interval` | `10` | Back up RDS every N articles |

---

## Crash Safety & Recovery

- Each paper's result is saved as an **individual `.json` file immediately** after the API call, so partial progress survives crashes.
- A partial `.rds` backup is written every `save_interval` articles.
- The final `.rds` contains the full `results_list` as a named R list.

---

## Output Format

### Per-paper status values

| Status | Meaning |
|--------|---------|
| `PROCESSED` | Analysis completed successfully |
| `SKIPPED_IRRELEVANT` | LLM judged the paper not relevant |
| `API_ERROR` | API call failed |
| `READ_ERROR` | Could not read the XML file |

### Table mapping (YAML config)

The `table_config_file` is a YAML file that controls how JSON fields are split across three output CSVs. Each prompt has its own mapping file because different prompts return different JSON schemas.

| Table | File suffix | Contents |
|-------|-------------|----------|
| **main** | `_main.csv` | One row per article — scalar fields (booleans, categories, counts) |
| **metadata** | `_metadata.csv` | One row per article — long-text fields (chain-of-thought, summaries) |
| **detail** | `_detail.csv` | Long-format — one row per array element (e.g. each validity method or discourse entry) |

Any JSON field **not listed** in the YAML defaults to the main table.

Example YAML (`prompts/prompt Valid.yml`):
```yaml
main:
  - content_category
  - profile_careless
  - ...
metadata:
  - thinking_chain_of_thought
  - summary_final
detail:
  - validity_methods
  - discourse_entries
```

### Flattening rules

Within each table, nested JSON is flattened recursively:

- **Scalar values** become direct columns (e.g. `content_category`).
- **Nested objects** are flattened with an underscore prefix (e.g. `relevance_check_is_relevant`).
- **Arrays** in the main/metadata tables are collapsed to strings; in the detail table each element becomes its own row.

---

## Batch Mode

For large runs (hundreds or thousands of articles), batch mode is **50% cheaper** and avoids rate limits. It supports both Gemini and OpenAI.

Set `batch_mode <- TRUE` in the master script. The pipeline will build JSONL files and stop — you then submit and parse manually:

1. **Build JSONL** — master pipeline runs `03c`, creates `batch_input/` folder with chunked JSONL files
2. **Submit chunks** — run `03d_submit_batch.R` once per JSONL file (you control pacing)
3. **Parse results** — run `03e_parse_batch_results.R` once all chunks are done
4. **Post-process** — run Steps 4-6 as normal

For the full walkthrough (including API tier requirements, file size limits, and troubleshooting), see **[docs/batch_guide.md](docs/batch_guide.md)**.

---

## API Key

Create a `.env` file in the project root (git-ignored):

```
OPENAI_API_KEY=sk-...
```

If using Anthropic in the future, set `api_provider <- "anthropic"` and add `ANTHROPIC_API_KEY=...` to `.env` instead.

---

## R Dependencies

```r
library(here)          # Path management
library(reticulate)    # R-Python bridge
library(tidyverse)     # dplyr, readr, etc.
library(jsonlite)      # JSON parsing
library(tictoc)        # Timing
library(yaml)          # YAML config (if used)
```

**Python** (inside the conda env): `openai`, `json`, optionally `torch` for GPU detection.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `API_ERROR` on every paper | Check `.env` exists and contains a valid key |
| Conda env not found | Run `Reticulate Setup.R` first |
| JSON parse errors | Inspect the individual `.json` file in the output folder |
| Partial run | Re-run the master script; existing `.json` files are not overwritten |

---

## Legacy Scripts

`Loop.R` and `Thematic_Analysis_Loop.R` are the original monolithic scripts. They still work but are superseded by the modular `_MASTER_RUN_PIPELINE.R` approach.
