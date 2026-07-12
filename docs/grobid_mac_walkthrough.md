# Step 1 on a Mac: PDF → XML with GROBID

The first step of an articLLMate analysis is converting a folder of PDFs into
GROBID TEI XML. The provided `PDF XML pipeline/1_pdf to xml.py` assumes a
Windows machine with an NVIDIA GPU (`--gpus all`, the full deep-learning image,
`n=40`). This guide is the **Apple Silicon Mac** equivalent — same step, same
result, using `PDF XML pipeline/1_pdf to xml (Mac).py`.

Key differences on a Mac:
- **No GPU.** Docker on macOS can't pass through a GPU, so `--gpus all` is
  dropped and the deep-learning models aren't used.
- **Native arm64 image.** We use the CRF-only `lfoppiano/grobid` image, which
  runs natively on Apple Silicon — fast, no Rosetta emulation, no `--platform`
  flag. It's more than accurate enough for header/DOI/body extraction.
- **CPU concurrency.** `n` is set to your CPU core count instead of 40.

---

## 1. Install Docker Desktop

```bash
brew install --cask docker      # or download from https://www.docker.com/products/docker-desktop
open -a Docker                   # launch once so the engine starts
```

Give Docker enough memory: **Docker Desktop → Settings → Resources → Memory →
≥ 4 GB** (GROBID needs ~4 GB to structure full PDF content; 6 GB if you process
many at once). Apply & restart, then confirm:

```bash
docker info >/dev/null && echo "Docker OK"
```

## 2. Start the GROBID server

Run this in a terminal and leave it running:

```bash
docker run --rm --init --ulimit core=0 -p 8070:8070 lfoppiano/grobid:0.8.1
```

- `lfoppiano/grobid` is the CRF-only image and **runs natively on arm64** — no
  `--gpus`, no `--platform linux/amd64`, no emulation.
- Check https://hub.docker.com/r/lfoppiano/grobid for the newest tag and bump
  `0.8.1` if a later arm64 build exists.
- In a second terminal, confirm it's alive:

```bash
curl http://localhost:8070/api/isalive   # -> true
```

## 3. Convert PDFs to XML

Install the Python client once:

```bash
pip install grobid_client_python
```

Open [`PDF XML pipeline/1_pdf to xml (Mac).py`](../PDF%20XML%20pipeline/1_pdf%20to%20xml%20(Mac).py),
set `input_folder` (your PDFs) and `output_folder` (where XML should go) at the
top, then run:

```bash
python3 "PDF XML pipeline/1_pdf to xml (Mac).py"
```

It reuses the same GROBID client and options as the PC script — only the GPU
flags are removed and `n` is set to your core count. It skips PDFs that already
have XML (`force=False`), so re-running is safe.

## 4. Continue with the pipeline

Put the resulting `.tei.xml` files in your project's article-text folder and run
the pre-processing pipeline as usual:

```
input/<project>/01_Article_Text/    <- GROBID XML from Step 3
```

Set `project_name <- "<project>"` in `_MASTER_PREPROCESS_PIPELINE.R` and source
it (see [docs/preprocess_guide.md](preprocess_guide.md)).

---

## Notes

- **Want the deep-learning models anyway?** The full `grobid/grobid` image is
  amd64-only and runs emulated on a Mac (slower). If you need it:
  `docker run --rm --init --platform linux/amd64 -p 8070:8070 grobid/grobid:0.8.1`.
- **Scanned / image-only PDFs.** GROBID reads an existing text layer; it does
  not OCR. If a PDF has no text (empty `<body>` in the XML), add a text layer
  first with e.g. `ocrmypdf` (`brew install ocrmypdf`) before Step 3.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `rosetta error: … ld-linux-x86-64.so.2` | You pulled the amd64 full image. Use `lfoppiano/grobid` (arm64) as above, or add `--platform linux/amd64`. |
| Container **killed** right after a PDF is sent | Raise Docker memory to ≥ 4–6 GB (Settings → Resources → Memory). |
| `Connection refused` on port 8070 | The server terminal (Step 2) isn't running, or the port is in use. |
| Empty `<body>` in the XML | The PDF likely has no text layer — OCR it first (see Notes). |
