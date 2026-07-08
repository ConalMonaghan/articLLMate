# ==============================================================================
# STAGE 2e: MAIN-TEXT TRUNCATION  —  *** STUB / HOOK POINT ***
# ==============================================================================
#
# STATUS: NOT IMPLEMENTED in the Logging branch (intentionally).
#
# PURPOSE (future):
# Optionally trim each article's body down to main text only — dropping
# reference lists, appendices, acknowledgements, funding statements, and other
# back-matter — when the user wants to minimise tokens sent to the model. GROBID
# TEI marks many of these regions (e.g. <div type="references">), so truncation
# can be done at the XML stage (stage 2b) or here on the extracted Text.
#
# WHY A STUB:
# Out of scope for the Logging branch (audit + orchestrator only). This module
# documents where truncation will plug in and reserves its ledger column
# (`truncated`) plus a master-level lever so the pipeline is ready for it.
#
# CONTRACT (when implemented):
#   EXPECTS:  ledger, OUTPUT_DIR, source_batch, and a lever such as
#             `truncate_to_main_text` (logical).
#   PRODUCES: rewritten $XML$Text with back-matter removed; ledger$truncated set
#             TRUE for affected articles. Token counts in stage 3 then reflect
#             the truncated text automatically.
#
# For now this is a no-op that simply notes it was skipped.
# ==============================================================================

cat("  [STUB] Main-text truncation not implemented — skipped.\n")
cat("         Hook point reserved: ledger column `truncated`, lever `truncate_to_main_text`.\n")
