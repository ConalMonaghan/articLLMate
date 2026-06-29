import os
import glob
from grobid_client.grobid_client import GrobidClient

# 1. USER CONFIGURATION
input_folder = r"path/to/your/pdf/folder"
output_folder = r"path/to/your/output/xml/folder"

if not os.path.exists(output_folder):
    os.makedirs(output_folder)

# 2. INITIALIZE THE FACTORY
# Remove the '/api' - the client adds it automatically.
# Version 0.8.x uses 'grobid_server'
client = GrobidClient(
    config_path=None, 
    grobid_server="http://localhost:8070", 
    timeout=600 
)

# 3. EXECUTE THE BATCH
print("\n--- Starting 3090 GPU Extraction Factory ---")

# Removed 'generateWorkDesk' as it is deprecated in the latest version.
client.process(
    service="processFulltextDocument",
    input_path=input_folder,
    output=output_folder,
    n=40,                 # High concurrency for your RTX 3090 10 doesn't slow much. 40 will max out the GPU. 
    consolidate_header=True, 
    force=False            # Checkpointing: skip existing XMLs
)

# 4. QUICK STATS
pdf_count = len(glob.glob(os.path.join(input_folder, "*.pdf")))
xml_count = len(glob.glob(os.path.join(output_folder, "*.tei.xml")))
print(f"\nStatus: {xml_count}/{pdf_count} files processed successfully.")
print("--- Batch Complete ---")

# To run in terminal first
#docker run --rm --init --gpus all `
#  -e TF_FORCE_GPU_ALLOW_GROWTH=true `
#  -p 8070:8070 `
#  grobid/grobid:0.8.2