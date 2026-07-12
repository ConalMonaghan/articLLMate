# ==============================================================================
# STAGE 2d: CONTENT-BASED FILTER  —  *** STUB / HOOK POINT ***
# ==============================================================================
#
# STATUS: NOT IMPLEMENTED in the Logging branch (intentionally).
#
# PURPOSE (future):
# Remove inappropriate files that survive the length filter but are not real
# research articles: tables of contents, errata/corrigenda, editorials, book
# reviews, author indexes, etc. Detection could combine cheap heuristics
# (title/first-page regex, ratio of numerals, absence of an abstract) with an
# optional LLM classification pass.
#
# WHY A STUB:
# The Logging branch scope is the audit system + orchestrator around the
# EXISTING pipeline. This module documents exactly where content filtering will
# plug in and reserves its ledger column (`content_flag`) so the schema and
# funnel are already shaped for it.
#
# CONTRACT (when implemented):
#   EXPECTS:  ledger, OUTPUT_DIR, source_batch, and any detection levers.
#   PRODUCES: ledger$content_flag set to a reason string (e.g. "toc",
#             "erratum", "editorial") for flagged articles; NA for clean ones.
#             ledger_finalize() already treats a non-NA content_flag as an
#             exclusion, so no other wiring is required.
#
# For now this is a no-op that simply notes it was skipped.
# ==============================================================================

cat("  [STUB] Content filter (TOC / errata / editorial) not implemented — skipped.\n")
cat("         Hook point reserved: ledger column `content_flag`, folder STAGE_DIRS$content (02d_Content_Filtered).\n")
cat("         (No folder is created while skipped, so its absence signals it did not run.)\n")
