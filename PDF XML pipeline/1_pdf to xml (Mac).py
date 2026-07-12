import os
import glob
from grobid_client.grobid_client import GrobidClient

# ==============================================================================
# STEP 1 (Apple Silicon Mac): PDF -> GROBID TEI XML
# ==============================================================================
# Mac equivalent of "1_pdf to xml.py". Same client and options, but:
#   - no GPU (Docker on macOS can't pass one through)
#   - the CRF-only arm64 image (lfoppiano/grobid) runs natively, no emulation
#   - concurrency (n) is set to your CPU core count instead of 40
# See docs/grobid_mac_walkthrough.md for the full walkthrough.
# ==============================================================================

# 1. USER CONFIGURATION
input_folder = r"path/to/your/pdf/folder"
output_folder = r"path/to/your/output/xml/folder"

if not os.path.exists(output_folder):
    os.makedirs(output_folder)

# 2. INITIALIZE THE CLIENT
# Point at the local GROBID server (started via Docker; see the walkthrough).
client = GrobidClient(
    config_path=None,
    grobid_server="http://localhost:8070",
    timeout=600
)

# 3. EXECUTE THE BATCH
# CRF extraction is CPU-bound, so concurrency scales with cores, not a GPU.
n_workers = os.cpu_count() or 4
print(f"\n--- Starting GROBID extraction on Mac (CPU, n={n_workers}) ---")

client.process(
    service="processFulltextDocument",
    input_path=input_folder,
    output=output_folder,
    n=n_workers,
    consolidate_header=True,
    force=False            # Checkpointing: skip PDFs that already have XML
)

# 4. QUICK STATS
pdf_count = len(glob.glob(os.path.join(input_folder, "*.pdf")))
xml_count = len(glob.glob(os.path.join(output_folder, "*.tei.xml")))
print(f"\nStatus: {xml_count}/{pdf_count} files processed successfully.")
print("--- Batch Complete ---")

# Start the GROBID server first, in a terminal (native arm64, CRF-only image):
# docker run --rm --init --ulimit core=0 \
#   -p 8070:8070 \
#   lfoppiano/grobid:0.8.1
#
# (Full deep-learning image instead, emulated on Mac and slower:)
# docker run --rm --init --platform linux/amd64 -p 8070:8070 grobid/grobid:0.8.1
