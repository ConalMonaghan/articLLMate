"""
Helper script for 03d_submit_batch.R
Uploads a JSONL file and submits a Gemini batch job.
Called via system2() from R to avoid reticulate batch API issues.

Usage:
  python submit_gemini_batch.py <jsonl_path> <model_id> <chunk_num>

Output (stdout, one value per line):
  JOB_NAME=<name>
  JOB_STATE=<state>

Exits non-zero on failure, with error message on stderr.
"""

import sys
import os

def main():
    if len(sys.argv) != 4:
        print("Usage: python submit_gemini_batch.py <jsonl_path> <model_id> <chunk_num>", file=sys.stderr)
        sys.exit(1)

    jsonl_path = sys.argv[1]
    model_id   = sys.argv[2]
    chunk_num  = int(sys.argv[3])

    if not os.path.exists(jsonl_path):
        print(f"ERROR: File not found: {jsonl_path}", file=sys.stderr)
        sys.exit(1)

    # Check for API key
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    from google import genai
    from google.genai import types

    client = genai.Client(api_key=api_key)

    # Upload
    print(f"Uploading {os.path.basename(jsonl_path)}...", file=sys.stderr)
    uploaded = client.files.upload(
        file=jsonl_path,
        config=types.UploadFileConfig(
            display_name=f"batch-chunk-{chunk_num:03d}",
            mime_type="application/jsonl"
        )
    )
    print(f"  Uploaded: {uploaded.name}", file=sys.stderr)

    # Submit batch
    print("Submitting batch job...", file=sys.stderr)
    job = client.batches.create(
        model=model_id,
        src=uploaded.name,
        config={"display_name": f"batch-chunk-{chunk_num:03d}"}
    )
    print(f"  Job: {job.name}  State: {job.state.name}", file=sys.stderr)

    # Machine-readable output on stdout for R to parse
    print(f"JOB_NAME={job.name}")
    print(f"JOB_STATE={job.state.name}")

if __name__ == "__main__":
    main()