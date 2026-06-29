# ==============================================================================
# STEP 5: POST-PROCESSING
# ==============================================================================
# PURPOSE:  Split nested JSON results into three CSV tables based on a
#           per-prompt YAML config file:
#
#           1. *_main.csv      — One row per article, scalar fields
#           2. *_metadata.csv  — One row per article, long-text fields
#           3. *_detail.csv    — Long-format table, one row per array element
#
#           The YAML config (e.g., prompts/prompt DC.yml) tells us which
#           top-level JSON keys belong to which table. Any key not listed
#           in the config defaults to "main".
#
# EXPECTS FROM MASTER:  results_list, files_analysed, project_name,
#                        OUTPUT_DIR, table_config_file
# CREATES:              results_main, results_metadata, results_detail,
#                        three CSV files
# ==============================================================================

cat("Post-processing results...\n")

# ---- 5a. Load the table-routing config ----
# table_config is already loaded by the master pipeline. Re-read only if missing.
if (!exists("table_config") || is.null(table_config)) {
  config_path <- here(table_config_file)
  if (!file.exists(config_path)) {
    cat(sprintf("  [WARN] No config found at %s — all fields go to main table.\n", config_path))
    table_config <- list(main = character(0), metadata = character(0), detail = character(0))
  } else {
    table_config <- yaml::read_yaml(config_path)
    cat(sprintf("  [OK] Table config loaded: %s\n", config_path))
  }
} else {
  cat("  [OK] Using table config from master pipeline.\n")
}

# Normalise config lists (NULL -> character(0))
for (tbl in c("main", "metadata", "detail")) {
  if (is.null(table_config[[tbl]])) table_config[[tbl]] <- character(0)
}


# ---- 5b. Helper: classify a JSON key into main / metadata / detail ----
classify_key <- function(key, config) {
  # Check detail first (may use dotted paths like evidence_extraction.categorical)
  for (d in config$detail) {
    # Match exact key or key is the prefix before the dot
    if (key == d || startsWith(d, paste0(key, "."))) return("detail")
  }
  if (key %in% config$metadata) return("metadata")
  if (key %in% config$main)     return("main")
  # Default: main
  return("main")
}


# ---- 5c. Helper: flatten a named list (nested object) into dot-free columns ----
flatten_object <- function(x, prefix = "") {
  flat <- list()
  for (name in names(x)) {
    full_key <- if (prefix == "") name else paste(prefix, name, sep = "_")
    val <- x[[name]]

    if (is.list(val) && !is.null(names(val))) {
      # Named list (nested object) -> recurse
      flat <- c(flat, flatten_object(val, full_key))
    } else if (is.list(val) && is.null(names(val))) {
      # Unnamed list (array) -> store as JSON string
      flat[[full_key]] <- as.character(toJSON(val, auto_unbox = TRUE))
    } else if (is.atomic(val) && length(val) > 1) {
      # Atomic vector -> collapse
      flat[[full_key]] <- paste(val, collapse = "; ")
    } else {
      flat[[full_key]] <- val
    }
  }
  return(flat)
}


# ---- 5d. Helper: expand detail arrays into long-format rows ----
# detail_paths are dotted paths like "evidence_extraction.categorical"
expand_detail <- function(result_data, detail_paths, filename) {
  rows <- list()

  for (path in detail_paths) {
    parts <- strsplit(path, "\\.")[[1]]

    # Navigate into the nested structure
    node <- result_data
    for (p in parts) {
      if (is.list(node) && p %in% names(node)) {
        node <- node[[p]]
      } else {
        node <- NULL
        break
      }
    }

    if (is.null(node) || length(node) == 0) next

    # node should be an array of objects (unnamed list of named lists)
    if (!is.list(node)) next

    for (j in seq_along(node)) {
      element <- node[[j]]
      if (!is.list(element)) {
        # Simple array element (string, number)
        row <- list(
          filename     = filename,
          detail_table = path,
          item_index   = j,
          value        = as.character(element)
        )
      } else {
        # Object -> flatten it, coerce all values to character for consistent binding
        flat <- flatten_object(element)
        flat <- lapply(flat, as.character)
        row <- c(
          list(filename = filename, detail_table = path, item_index = j),
          flat
        )
      }
      rows[[length(rows) + 1]] <- row
    }
  }

  return(rows)
}


# ---- 5e. Build the three tables ----
main_rows     <- list()
metadata_rows <- list()
detail_rows   <- list()

for (item in results_list) {
  if (is.null(item)) next

  filename <- item$filename
  status   <- item$status

  # Strip internal metadata before routing
  result_data <- item
  result_data$filename <- NULL
  result_data$status   <- NULL

  # Initialise row stubs
  main_row     <- list(filename = filename)
  metadata_row <- list(filename = filename)

  # Route each top-level key
  for (key in names(result_data)) {
    dest <- classify_key(key, table_config)

    if (dest == "detail") {
      # Handled separately below
      next
    }

    val <- result_data[[key]]

    if (dest == "metadata") {
      if (is.list(val) && !is.null(names(val))) {
        metadata_row <- c(metadata_row, flatten_object(val, key))
      } else if (is.list(val) && is.null(names(val))) {
        metadata_row[[key]] <- as.character(toJSON(val, auto_unbox = TRUE))
      } else if (is.atomic(val) && length(val) > 1) {
        metadata_row[[key]] <- paste(val, collapse = "; ")
      } else {
        metadata_row[[key]] <- val
      }
    } else {
      # main
      if (is.list(val) && !is.null(names(val))) {
        main_row <- c(main_row, flatten_object(val, key))
      } else if (is.list(val) && is.null(names(val))) {
        # Unnamed list (JSON array of objects) -> collapse to string
        main_row[[key]] <- paste(sapply(val, as.character), collapse = "; ")
      } else if (is.atomic(val) && length(val) > 1) {
        # Atomic vector (JSON array of scalars, e.g. meta_authors, structure_study_ids) -> collapse
        main_row[[key]] <- paste(val, collapse = "; ")
      } else {
        main_row[[key]] <- val
      }
    }
  }

  # Add status to main
  main_row$status <- status
  main_rows[[length(main_rows) + 1]] <- main_row
  metadata_rows[[length(metadata_rows) + 1]] <- metadata_row

  # Expand detail arrays
  detail_rows <- c(detail_rows, expand_detail(result_data, table_config$detail, filename))
}


# ---- 5f. Assemble and save ----
save_table <- function(rows, suffix, label) {
  if (length(rows) == 0) {
    cat(sprintf("  [WARN] No rows for %s table.\n", label))
    return(data.frame())
  }

  df <- bind_rows(rows)
  csv_path <- file.path(OUTPUT_DIR, paste0(project_name, "_", suffix, ".csv"))
  write_csv(df, csv_path)
  cat(sprintf("  [OK] %s table: %s (%d rows x %d cols)\n",
              label, csv_path, nrow(df), ncol(df)))
  cat("       Columns:", paste(names(df), collapse = ", "), "\n")
  return(df)
}

results_main     <- save_table(main_rows,     "main",     "Main")
results_metadata <- save_table(metadata_rows, "metadata", "Metadata")
results_detail   <- save_table(detail_rows,   "detail",   "Detail")

cat("Post-processing complete.\n")
