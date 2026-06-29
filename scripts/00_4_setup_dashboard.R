# ==============================================================================
# STEP 0.3: DASHBOARD SETUP (Google Sheets Logging)
# ==============================================================================
# PURPOSE:  Authenticate with Google Sheets and prepare a logging sheet
#           for tracking article processing in real-time.
#           Only used when dashboard = TRUE in the master pipeline.
#
# EXPECTS FROM MASTER:  dashboard_sheet, dashboard_tab, project_name, model_id,
#                        gpu_status, execution_mode, machine_id
# CREATES:              log_to_dashboard() function (in global env),
#                        FAILURE_COUNT (global counter),
#                        .MEMORY_TOTAL_MB (one-time system stat)
# ==============================================================================


####### IMPORTANT ###########
# When google asks for Auth, make sure to select all, not just click accept (auth. are off by default)

cat("Setting up Google Sheets dashboard...\n")

# ---- 0.3a. Check / install required packages ----
required_pkgs <- c("googlesheets4", "googledrive")
for (pkg in required_pkgs) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    cat(sprintf("  [INSTALL] Package '%s' not found. Installing...\n", pkg))
    install.packages(pkg)
  }
}
library(googlesheets4)
library(googledrive)

# ---- 0.3b. Authenticate ----
# Prefer service account key (headless / remote friendly).
# Falls back to interactive OAuth if no key file is found.
cat("  Authenticating with Google...\n")

sa_key_path <- file.path(getwd(), "keys", "ArticLLMate_Key.json")
if (!file.exists(sa_key_path)) {
  # Also check one level up (if running from scripts/ subdirectory)
  sa_key_path <- file.path(dirname(getwd()), "keys", "ArticLLMate_Key.json")
}

if (file.exists(sa_key_path)) {
  cat(sprintf("  Using service account key: %s\n", sa_key_path))
  gs4_auth(path = sa_key_path)
  drive_auth(path = sa_key_path)
  cat("  [OK] Service account authentication successful.\n")
} else {
  cat("  No service account key found at keys/ArticLLMate_Key.json\n")
  cat("  Falling back to interactive OAuth...\n")
  gs4_auth(scopes = c(
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive"
  ))
  drive_auth(token = gs4_token())  # reuse the same token for Drive
  cat("  [OK] Google OAuth authentication successful.\n")
}

# ---- 0.3c. Find or create the Google Sheet ----
# dashboard_sheet can be a URL, a sheet ID, or a name
sheet_id <- tryCatch({
  if (grepl("^https://", dashboard_sheet) || grepl("^[a-zA-Z0-9_-]{30,}$", dashboard_sheet)) {
    # Looks like a URL or ID — use directly
    as_sheets_id(dashboard_sheet)
  } else {
    # Treat as a name — search user's Drive
    matches <- drive_find(pattern = dashboard_sheet, type = "spreadsheet", n_max = 5)
    if (nrow(matches) == 0) {
      cat(sprintf("  [CREATE] Sheet '%s' not found. Creating it...\n", dashboard_sheet))
      new_ss <- gs4_create(dashboard_sheet, sheets = dashboard_tab)
      new_ss
    } else {
      as_sheets_id(matches$id[1])
    }
  }
}, error = function(e) {
  stop(
    "\n\n=== DASHBOARD SETUP FAILED ===\n",
    "Could not find or create Google Sheet: '", dashboard_sheet, "'\n",
    "Error: ", e$message, "\n",
    "Set dashboard <- FALSE in the master pipeline to skip.\n"
  )
})

cat(sprintf("  [OK] Using sheet: %s\n", dashboard_sheet))

# ---- 0.3d. Check / create the target tab ----
existing_tabs <- sheet_names(sheet_id)
if (!(dashboard_tab %in% existing_tabs)) {
  cat(sprintf("  [CREATE] Tab '%s' not found. Adding it with headers...\n", dashboard_tab))
  sheet_add(sheet_id, sheet = dashboard_tab)
}

# ---- 0.3e. Ensure header row exists ----
dashboard_headers <- c(
  "timestamp", "project_name", "article_id", "rds_source", "status",
  "duration_secs", "model_id", "gpu_status", "machine_id",
  "cpu_usage_pct", "memory_used_mb", "memory_total_mb", "power_source",
  "cpu_temp_c", "gpu_util_pct", "gpu_temp_c", "gpu_mem_used_mb", "gpu_mem_total_mb",
  "failure_count", "last_critique",
  "cumulative_articles", "cumulative_time_secs"
)

existing_data <- tryCatch(
  read_sheet(sheet_id, sheet = dashboard_tab, range = "A1:V1", col_names = FALSE),
  error = function(e) tibble::tibble()
)

if (nrow(existing_data) == 0) {
  cat("  [INIT] Writing header row...\n")
  sheet_append(sheet_id, data = as.data.frame(t(dashboard_headers)), sheet = dashboard_tab)
}

# ---- 0.3f. Collect one-time system stats at startup ----

# Total memory (collected once, reused each loop)
.MEMORY_TOTAL_MB <<- NA_real_
os <- Sys.info()["sysname"]

if (os == "Darwin") {
  tryCatch({
    .MEMORY_TOTAL_MB <<- round(as.numeric(system("sysctl -n hw.memsize", intern = TRUE)) / 1048576, 0)
  }, error = function(e) {})
} else if (os == "Linux") {
  tryCatch({
    meminfo <- readLines("/proc/meminfo", n = 1)
    .MEMORY_TOTAL_MB <<- round(as.numeric(gsub("\\D", "", meminfo)) / 1024, 0)
  }, error = function(e) {})
} else if (os == "Windows") {
  tryCatch({
    mem_out <- system("wmic OS get TotalVisibleMemorySize /value", intern = TRUE, ignore.stderr = TRUE)
    total_line <- mem_out[grep("TotalVisibleMemorySize", mem_out)]
    if (length(total_line) > 0) {
      .MEMORY_TOTAL_MB <<- round(as.numeric(sub(".*=(\\d+).*", "\\1", total_line[1])) / 1024, 0)
    }
  }, error = function(e) {})
}

if (!is.na(.MEMORY_TOTAL_MB)) {
  cat(sprintf("  [OK] Total memory: %d MB\n", .MEMORY_TOTAL_MB))
}

# Initialise failure counter
FAILURE_COUNT <<- 0L

# ---- 0.3g. System stats helper (no sudo required) ----
.get_system_stats <- function() {
  os <- Sys.info()["sysname"]
  stats <- list(
    cpu_usage_pct  = NA_real_,
    memory_used_mb = NA_real_,
    power_source   = NA_character_,
    cpu_temp_c     = NA_real_,
    gpu_util_pct   = NA_real_,
    gpu_temp_c     = NA_real_,
    gpu_mem_used_mb  = NA_real_,
    gpu_mem_total_mb = NA_real_
  )

  if (os == "Darwin") {
    # macOS: CPU usage from top
    tryCatch({
      top_out <- system("top -l 1 -s 0 | head -4 | grep 'CPU usage'", intern = TRUE, ignore.stderr = TRUE)
      if (length(top_out) > 0) {
        idle <- as.numeric(sub(".*?(\\d+\\.?\\d*)% idle.*", "\\1", top_out[1]))
        stats$cpu_usage_pct <- round(100 - idle, 1)
      }
    }, error = function(e) {})

    # macOS: Memory from vm_stat
    tryCatch({
      vm <- system("vm_stat", intern = TRUE, ignore.stderr = TRUE)
      page_size <- as.numeric(sub(".*page size of (\\d+) bytes.*", "\\1", vm[1]))
      active   <- as.numeric(gsub("\\D", "", vm[grep("Pages active", vm)]))
      wired    <- as.numeric(gsub("\\D", "", vm[grep("Pages wired", vm)]))
      compressed <- as.numeric(gsub("\\D", "", vm[grep("Pages occupied by compressor", vm)]))
      used_pages <- sum(c(active, wired, compressed), na.rm = TRUE)
      stats$memory_used_mb <- round(used_pages * page_size / 1024 / 1024, 0)
    }, error = function(e) {})

    # macOS: Power source
    tryCatch({
      pwr <- system("pmset -g batt 2>/dev/null | head -1", intern = TRUE, ignore.stderr = TRUE)
      if (length(pwr) > 0) {
        if (grepl("AC Power", pwr)) stats$power_source <- "AC Power"
        else if (grepl("Battery", pwr)) stats$power_source <- "Battery"
        else stats$power_source <- trimws(pwr)
      }
    }, error = function(e) {})

    # macOS: CPU temperature (requires: brew install osx-cpu-temp)
    tryCatch({
      temp_out <- system("osx-cpu-temp 2>/dev/null", intern = TRUE, ignore.stderr = TRUE)
      if (length(temp_out) > 0) {
        stats$cpu_temp_c <- as.numeric(gsub("[^0-9.]", "", temp_out[1]))
      }
    }, error = function(e) {})

    # macOS: GPU stats — not available without sudo, leave as NA

  } else if (os == "Linux") {
    # Linux: CPU usage from /proc/stat (instantaneous)
    tryCatch({
      cpu_line <- readLines("/proc/stat", n = 1)
      vals <- as.numeric(strsplit(sub("^cpu\\s+", "", cpu_line), "\\s+")[[1]])
      idle <- vals[4]
      total <- sum(vals)
      stats$cpu_usage_pct <- round((1 - idle / total) * 100, 1)
    }, error = function(e) {})

    # Linux: Memory from /proc/meminfo
    tryCatch({
      meminfo <- readLines("/proc/meminfo", n = 5)
      total <- as.numeric(gsub("\\D", "", meminfo[grep("MemTotal", meminfo)]))[1]
      avail <- as.numeric(gsub("\\D", "", meminfo[grep("MemAvailable", meminfo)]))[1]
      stats$memory_used_mb <- round((total - avail) / 1024, 0)
    }, error = function(e) {})

    # Linux: Power source
    tryCatch({
      if (file.exists("/sys/class/power_supply/AC/online")) {
        ac <- readLines("/sys/class/power_supply/AC/online", n = 1)
        stats$power_source <- if (ac == "1") "AC Power" else "Battery"
      }
    }, error = function(e) {})

    # Linux: CPU temperature
    tryCatch({
      if (file.exists("/sys/class/thermal/thermal_zone0/temp")) {
        raw_temp <- as.numeric(readLines("/sys/class/thermal/thermal_zone0/temp", n = 1))
        stats$cpu_temp_c <- round(raw_temp / 1000, 1)
      }
    }, error = function(e) {})

    # Linux: GPU stats via nvidia-smi (single call for all 4 fields)
    tryCatch({
      gpu_out <- system(
        "nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null",
        intern = TRUE, ignore.stderr = TRUE
      )
      if (length(gpu_out) > 0 && !grepl("command not found|not found", gpu_out[1], ignore.case = TRUE)) {
        vals <- trimws(strsplit(gpu_out[1], ",")[[1]])
        if (length(vals) >= 4) {
          stats$gpu_util_pct     <- as.numeric(vals[1])
          stats$gpu_temp_c       <- as.numeric(vals[2])
          stats$gpu_mem_used_mb  <- as.numeric(vals[3])
          stats$gpu_mem_total_mb <- as.numeric(vals[4])
        }
      }
    }, error = function(e) {})

  } else if (os == "Windows") {
    # Windows: CPU usage via wmic
    tryCatch({
      cpu_out <- system("wmic cpu get loadpercentage /value", intern = TRUE, ignore.stderr = TRUE)
      cpu_line <- cpu_out[grep("LoadPercentage", cpu_out)]
      if (length(cpu_line) > 0) {
        stats$cpu_usage_pct <- as.numeric(sub(".*=(\\d+).*", "\\1", cpu_line[1]))
      }
    }, error = function(e) {})

    # Windows: Memory
    tryCatch({
      mem_out <- system("wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /value", intern = TRUE, ignore.stderr = TRUE)
      total_line <- mem_out[grep("TotalVisibleMemorySize", mem_out)]
      free_line  <- mem_out[grep("FreePhysicalMemory", mem_out)]
      if (length(total_line) > 0 && length(free_line) > 0) {
        total_kb <- as.numeric(sub(".*=(\\d+).*", "\\1", total_line[1]))
        free_kb  <- as.numeric(sub(".*=(\\d+).*", "\\1", free_line[1]))
        stats$memory_used_mb <- round((total_kb - free_kb) / 1024, 0)
      }
    }, error = function(e) {})

    # Windows: GPU stats via nvidia-smi
    tryCatch({
      gpu_out <- suppressWarnings(system(
        "nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>nul",
        intern = TRUE, ignore.stderr = TRUE
      ))
      if (length(gpu_out) > 0) {
        vals <- trimws(strsplit(gpu_out[1], ",")[[1]])
        if (length(vals) >= 4) {
          stats$gpu_util_pct     <- as.numeric(vals[1])
          stats$gpu_temp_c       <- as.numeric(vals[2])
          stats$gpu_mem_used_mb  <- as.numeric(vals[3])
          stats$gpu_mem_total_mb <- as.numeric(vals[4])
        }
      }
    }, error = function(e) {})
  }

  stats
}

# ---- 0.3h. Dashboard logging function ----
# This function is placed in the global env so 03b can call it
log_to_dashboard <<- function(article_id, rds_source, status, duration, index,
                               api_result = NULL) {

  sys_stats <- .get_system_stats()
  cumulative_time <- if (exists("timings")) sum(timings[1:index], na.rm = TRUE) else duration

  # Extract last critique (first 500 chars) — uses fields from YAML config
  last_critique <- ""
  if (!is.null(api_result) && is.list(api_result)) {
    # Use config-driven field list; fall back to sensible defaults if not set
    critique_fields <- if (exists("table_config") && !is.null(table_config$dashboard_critique_fields)) {
      table_config$dashboard_critique_fields
    } else {
      c("thinking_chain_of_thought", "summary_final", "critique")
    }
    for (fld in critique_fields) {
      val <- resolve_field(api_result, fld)
      if (!is.null(val) && is.character(val)) {
        last_critique <- substr(val, 1, 500)
        break
      }
    }
  }

  # Helper: NA -> ""
  na_to_empty <- function(x) ifelse(is.na(x), "", x)

  row <- data.frame(
    timestamp            = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    project_name         = project_name,
    article_id           = article_id,
    rds_source           = rds_source,
    status               = status,
    duration_secs        = round(duration, 1),
    model_id             = model_id,
    gpu_status           = gpu_status,
    machine_id           = if (exists("machine_id")) machine_id else "",
    cpu_usage_pct        = na_to_empty(sys_stats$cpu_usage_pct),
    memory_used_mb       = na_to_empty(sys_stats$memory_used_mb),
    memory_total_mb      = na_to_empty(.MEMORY_TOTAL_MB),
    power_source         = na_to_empty(sys_stats$power_source),
    cpu_temp_c           = na_to_empty(sys_stats$cpu_temp_c),
    gpu_util_pct         = na_to_empty(sys_stats$gpu_util_pct),
    gpu_temp_c           = na_to_empty(sys_stats$gpu_temp_c),
    gpu_mem_used_mb      = na_to_empty(sys_stats$gpu_mem_used_mb),
    gpu_mem_total_mb     = na_to_empty(sys_stats$gpu_mem_total_mb),
    failure_count        = FAILURE_COUNT,
    last_critique        = last_critique,
    cumulative_articles  = index,
    cumulative_time_secs = round(cumulative_time, 1),
    stringsAsFactors     = FALSE
  )

  sheet_append(sheet_id, data = row, sheet = dashboard_tab)
}

cat("  [OK] Dashboard ready. Each article will be logged to Google Sheets.\n")
