# =============================================================================
# app.R — AI Loop Remote Monitoring Dashboard
# Reads from two Google Sheets tabs: mac_monitor, rtx_monitor
# Auto-refreshes every 60 seconds
# =============================================================================

library(shiny)
library(googlesheets4)
library(dplyr)
library(ggplot2)
library(plotly)
library(lubridate)

# -----------------------------------------------------------------------------
# AUTHENTICATION — service account key
# -----------------------------------------------------------------------------

# Prevent any interactive auth prompts (important for deployed apps)
gs4_deauth()

# When deployed, the key lives inside the app folder at keys/ArticLLMate_Key.json.
# Locally, also check the project root keys/ folder as a fallback.
KEY_PATH <- NULL
for (candidate in c("keys/ArticLLMate_Key.json",
                     file.path(dirname(getwd()), "keys", "ArticLLMate_Key.json"))) {
  if (file.exists(candidate)) { KEY_PATH <- candidate; break }
}

if (is.null(KEY_PATH)) {
  stop("No service account key found.\n",
       "  Place ArticLLMate_Key.json in Monitoring Dashboard/keys/")
}

gs4_auth(path = KEY_PATH)
message("[OK] Authenticated with service account: ", KEY_PATH)

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

SHEET_ID     <- Sys.getenv("GSHEET_MONITOR_ID", unset = "YOUR_GOOGLE_SHEET_ID_HERE")
MAC_TAB      <- "MacM4"
RTX_TAB      <- "RTX3090"       # create this tab when you run the RTX machine
TOTAL_ARTS   <- 50000
STALL_MINS   <- 10      # minutes without update = stall alert
REFRESH_SECS <- 60

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------

read_sheet_safe <- function(sheet_tab) {
  tryCatch(
    googlesheets4::read_sheet(SHEET_ID, sheet = sheet_tab, col_types = "c"),
    error = function(e) {
      message("[WARN] read_sheet('", sheet_tab, "') failed: ", e$message)
      NULL
    }
  )
}

coerce_numeric <- function(df, cols) {
  for (col in cols) {
    if (col %in% names(df)) df[[col]] <- suppressWarnings(as.numeric(df[[col]]))
  }
  df
}

parse_monitor_data <- function(raw) {
  if (is.null(raw) || nrow(raw) == 0) return(NULL)

  # Safe column accessor: returns NA vector if column missing
  safe_col <- function(df, col) {
    if (col %in% names(df)) df[[col]] else rep(NA_real_, nrow(df))
  }

  # Coerce pipeline columns to numeric (only those that exist)
  num_cols <- c("duration_secs", "cpu_usage_pct", "memory_used_mb", "memory_total_mb",
                "cpu_temp_c", "gpu_util_pct", "gpu_temp_c", "gpu_mem_used_mb",
                "gpu_mem_total_mb", "failure_count", "cumulative_articles",
                "cumulative_time_secs")
  raw$timestamp <- as.POSIXct(raw$timestamp, format = "%Y-%m-%d %H:%M:%S")
  raw <- coerce_numeric(raw, num_cols)

  # Derive dashboard metrics from raw per-article rows
  cum_arts <- safe_col(raw, "cumulative_articles")
  cum_time <- safe_col(raw, "cumulative_time_secs")
  fails    <- safe_col(raw, "failure_count")

  raw$articles_done    <- cum_arts
  raw$pct_complete     <- cum_arts / TOTAL_ARTS * 100
  raw$avg_loop_mins    <- ifelse(cum_arts > 0, cum_time / cum_arts / 60, NA_real_)
  raw$loops_per_hour   <- ifelse(!is.na(raw$avg_loop_mins) & raw$avg_loop_mins > 0,
                                 60 / raw$avg_loop_mins, NA_real_)
  raw$failure_count    <- fails
  raw$failure_rate_pct <- ifelse(cum_arts > 0, fails / cum_arts * 100, NA_real_)

  # Map system columns to dashboard names
  mem_used  <- safe_col(raw, "memory_used_mb")
  mem_total <- safe_col(raw, "memory_total_mb")
  gpu_mu    <- safe_col(raw, "gpu_mem_used_mb")
  gpu_mt    <- safe_col(raw, "gpu_mem_total_mb")

  raw$cpu_pct     <- safe_col(raw, "cpu_usage_pct")
  raw$ram_pct     <- ifelse(!is.na(mem_total) & mem_total > 0,
                            mem_used / mem_total * 100, NA_real_)
  raw$gpu_pct     <- safe_col(raw, "gpu_util_pct")
  raw$gpu_temp    <- safe_col(raw, "gpu_temp_c")
  raw$cpu_temp    <- safe_col(raw, "cpu_temp_c")
  raw$gpu_mem_pct <- ifelse(!is.na(gpu_mt) & gpu_mt > 0,
                            gpu_mu / gpu_mt * 100, NA_real_)

  # Model name for display
  raw$model_name <- if ("model_id" %in% names(raw)) raw$model_id else "unknown"

  raw
}

latest_row <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(NULL)
  df[which.max(df$timestamp), ]
}

mins_since_update <- function(df) {
  lr <- latest_row(df)
  if (is.null(lr)) return(Inf)
  as.numeric(difftime(Sys.time(), lr$timestamp, units = "mins"))
}

# ggplot2 dark theme matching dashboard
theme_monitor <- function() {
  theme_minimal(base_family = "mono") +
    theme(
      plot.background    = element_rect(fill = "#0d1117", colour = NA),
      panel.background   = element_rect(fill = "#0d1117", colour = NA),
      panel.grid.major   = element_line(colour = "#1e2a38", linewidth = 0.4),
      panel.grid.minor   = element_blank(),
      axis.text          = element_text(colour = "#8b9ab0", size = 9),
      axis.title         = element_text(colour = "#8b9ab0", size = 10),
      plot.title         = element_text(colour = "#e0e8f0", size = 12, face = "bold"),
      plot.subtitle      = element_text(colour = "#8b9ab0", size = 9),
      legend.background  = element_rect(fill = "#0d1117"),
      legend.text        = element_text(colour = "#8b9ab0"),
      legend.title       = element_text(colour = "#8b9ab0"),
      strip.text         = element_text(colour = "#c0cfe0")
    )
}

# Null coalescing helper
`%||%` <- function(a, b) if (!is.null(a) && !is.na(a) && length(a) > 0) a else b

MAC_COL <- "#00d4aa"
RTX_COL <- "#ff6b6b"

# -----------------------------------------------------------------------------
# UI
# -----------------------------------------------------------------------------

ui <- fluidPage(
  tags$head(
    tags$link(rel = "preconnect", href = "https://fonts.googleapis.com"),
    tags$link(rel = "stylesheet",
              href = "https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;600&family=Syne:wght@400;700;800&display=swap"),
    tags$style(HTML("

      * { box-sizing: border-box; }

      body {
        background-color: #0d1117;
        color: #c9d1d9;
        font-family: 'JetBrains Mono', monospace;
        margin: 0; padding: 0;
      }

      /* ---- TOP BAR ---- */
      .top-bar {
        background: #010409;
        border-bottom: 1px solid #1e2a38;
        padding: 14px 28px;
        display: flex;
        align-items: center;
        justify-content: space-between;
      }
      .top-bar h1 {
        font-family: 'Syne', sans-serif;
        font-weight: 800;
        font-size: 20px;
        color: #e0e8f0;
        margin: 0;
        letter-spacing: 0.04em;
      }
      .top-bar .meta {
        font-size: 11px;
        color: #4a5568;
      }
      .top-bar .meta span { color: #8b9ab0; }

      /* ---- STALL BANNER ---- */
      .stall-banner {
        background: #3d1515;
        border: 1px solid #c0392b;
        border-radius: 4px;
        padding: 8px 16px;
        color: #ff6b6b;
        font-size: 12px;
        margin: 12px 24px 0;
        display: flex;
        align-items: center;
        gap: 8px;
      }
      .stall-banner.hidden { display: none; }

      /* ---- SECTION HEADER ---- */
      .section-header {
        font-family: 'Syne', sans-serif;
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 0.12em;
        color: #4a5568;
        text-transform: uppercase;
        padding: 20px 24px 8px;
        border-top: 1px solid #1e2a38;
        margin-top: 8px;
      }

      /* ---- MACHINE PANEL ---- */
      .machine-panel {
        background: #0d1117;
        border: 1px solid #1e2a38;
        border-radius: 6px;
        padding: 18px 20px;
        margin: 0 8px 12px;
        position: relative;
      }
      .machine-panel .machine-title {
        font-family: 'Syne', sans-serif;
        font-size: 15px;
        font-weight: 700;
        margin-bottom: 4px;
      }
      .machine-panel .model-tag {
        font-size: 10px;
        color: #4a5568;
        margin-bottom: 14px;
        font-family: 'JetBrains Mono', monospace;
      }
      .machine-panel.mac .machine-title  { color: #00d4aa; }
      .machine-panel.rtx .machine-title  { color: #ff6b6b; }

      /* ---- STAT GRID ---- */
      .stat-grid {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 10px;
        margin-bottom: 14px;
      }
      .stat-box {
        background: #010409;
        border: 1px solid #1e2a38;
        border-radius: 4px;
        padding: 10px 12px;
      }
      .stat-box .label {
        font-size: 9px;
        color: #4a5568;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        margin-bottom: 4px;
      }
      .stat-box .value {
        font-size: 18px;
        font-weight: 600;
        color: #e0e8f0;
        font-family: 'JetBrains Mono', monospace;
      }
      .stat-box .value.warn { color: #f39c12; }
      .stat-box .value.ok   { color: #00d4aa; }
      .stat-box .value.crit { color: #ff6b6b; }
      .stat-box .sub {
        font-size: 10px;
        color: #4a5568;
        margin-top: 2px;
      }

      /* ---- PROGRESS BAR ---- */
      .prog-wrap {
        background: #010409;
        border: 1px solid #1e2a38;
        border-radius: 3px;
        height: 8px;
        margin-bottom: 10px;
        overflow: hidden;
      }
      .prog-bar {
        height: 100%;
        border-radius: 3px;
        transition: width 0.8s ease;
      }
      .mac  .prog-bar  { background: linear-gradient(90deg, #007a60, #00d4aa); }
      .rtx  .prog-bar  { background: linear-gradient(90deg, #8b1a1a, #ff6b6b); }

      .prog-label {
        font-size: 10px;
        color: #8b9ab0;
        display: flex;
        justify-content: space-between;
        margin-bottom: 14px;
      }

      /* ---- STALL DOT ---- */
      .stall-dot {
        display: inline-block;
        width: 8px; height: 8px;
        border-radius: 50%;
        margin-right: 6px;
        vertical-align: middle;
      }
      .stall-dot.live  { background: #00d4aa; box-shadow: 0 0 6px #00d4aa; }
      .stall-dot.stall { background: #ff6b6b; animation: pulse 1s infinite; }
      @keyframes pulse {
        0%,100% { opacity: 1; }
        50%      { opacity: 0.3; }
      }

      /* ---- SYSTEM PANEL ---- */
      .sys-panel {
        background: #0d1117;
        border: 1px solid #1e2a38;
        border-radius: 6px;
        padding: 16px 18px;
        margin: 0 8px 12px;
      }
      .sys-title {
        font-family: 'Syne', sans-serif;
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.05em;
        margin-bottom: 12px;
      }
      .sys-panel.mac .sys-title { color: #00d4aa; }
      .sys-panel.rtx .sys-title { color: #ff6b6b; }

      .gauge-row {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }
      .gauge-item .gauge-label {
        font-size: 10px;
        color: #4a5568;
        display: flex;
        justify-content: space-between;
        margin-bottom: 3px;
      }
      .gauge-item .gauge-label span { color: #8b9ab0; }
      .gauge-track {
        background: #010409;
        border-radius: 2px;
        height: 5px;
        overflow: hidden;
      }
      .gauge-fill {
        height: 100%;
        border-radius: 2px;
        transition: width 0.6s ease;
      }
      .gauge-fill.cpu  { background: #5b9cf6; }
      .gauge-fill.ram  { background: #a78bfa; }
      .gauge-fill.gpu  { background: #fb923c; }
      .gauge-fill.temp { background: #f87171; }

      /* ---- QUALITY PANEL ---- */
      .critique-box {
        background: #010409;
        border: 1px solid #1e2a38;
        border-radius: 4px;
        padding: 14px 16px;
        margin: 0 8px 12px;
        font-size: 11px;
        color: #8b9ab0;
        line-height: 1.6;
      }
      .critique-box .critique-meta {
        font-size: 10px;
        color: #4a5568;
        margin-bottom: 8px;
      }
      .critique-box .critique-text {
        color: #c9d1d9;
        font-family: 'JetBrains Mono', monospace;
        white-space: pre-wrap;
        word-break: break-word;
      }

      /* ---- PLOTS ---- */
      .plot-panel {
        background: #0d1117;
        border: 1px solid #1e2a38;
        border-radius: 6px;
        padding: 16px;
        margin: 0 8px 12px;
      }

      /* ---- TABS ---- */
      .nav-tabs {
        border-bottom: 1px solid #1e2a38;
        padding: 0 16px;
      }
      .nav-tabs > li > a {
        color: #4a5568 !important;
        border: none !important;
        border-radius: 0 !important;
        font-size: 11px;
        padding: 8px 14px;
        background: transparent !important;
        font-family: 'JetBrains Mono', monospace;
      }
      .nav-tabs > li.active > a,
      .nav-tabs > li > a:hover {
        color: #00d4aa !important;
        border-bottom: 2px solid #00d4aa !important;
        background: transparent !important;
      }
      .tab-content { padding: 12px 0 0; }

      /* ---- MISC ---- */
      .container-fluid { padding: 0; }
      hr { border-color: #1e2a38; margin: 4px 0; }
    "))
  ),

  # TOP BAR
  div(class = "top-bar",
    div(tags$h1("⬡ CORPUS MONITOR")),
    div(class = "meta",
        "auto-refresh ", tags$span(paste0(REFRESH_SECS, "s")),
        " · last sync ", tags$span(textOutput("last_sync", inline = TRUE))
    )
  ),

  # STALL BANNER
  uiOutput("stall_banner"),

  # ---- SECTION: PROGRESS ----
  div(class = "section-header", "PIPELINE PROGRESS"),
  fluidRow(
    column(6, uiOutput("mac_progress_panel")),
    column(6, uiOutput("rtx_progress_panel"))
  ),

  # ---- SECTION: SYSTEM HEALTH ----
  div(class = "section-header", "SYSTEM HEALTH"),
  fluidRow(
    column(6, uiOutput("mac_sys_panel")),
    column(6, uiOutput("rtx_sys_panel"))
  ),

  # ---- SECTION: PLOTS ----
  div(class = "section-header", "DIAGNOSTICS"),
  div(style = "padding: 0 16px;",
    tabsetPanel(
      tabPanel("Throughput over time",
        div(class = "plot-panel", plotlyOutput("plot_throughput", height = "280px"))),
      tabPanel("Loop time by article",
        div(class = "plot-panel", plotlyOutput("plot_looptime", height = "280px"))),
      tabPanel("System load",
        div(class = "plot-panel", plotlyOutput("plot_sysload", height = "280px"))),
      tabPanel("Temperature",
        div(class = "plot-panel", plotlyOutput("plot_temp", height = "280px"))),
      tabPanel("Cumulative completion",
        div(class = "plot-panel", plotlyOutput("plot_cumulative", height = "280px"))),
      tabPanel("Failure rate",
        div(class = "plot-panel", plotlyOutput("plot_failures", height = "280px")))
    )
  ),

  # ---- SECTION: QUALITY SPOT-CHECK ----
  div(class = "section-header", "QUALITY SPOT-CHECK"),
  fluidRow(
    column(6, uiOutput("mac_critique")),
    column(6, uiOutput("rtx_critique"))
  ),

  # Bottom spacer
  tags$div(style = "height: 40px;")
)

# -----------------------------------------------------------------------------
# SERVER
# -----------------------------------------------------------------------------

server <- function(input, output, session) {

  auto_refresh <- reactiveTimer(REFRESH_SECS * 1000)

  # -- Data fetch --
  data_raw <- reactive({
    auto_refresh()
    list(
      mac = parse_monitor_data(read_sheet_safe(MAC_TAB)),
      rtx = parse_monitor_data(read_sheet_safe(RTX_TAB))
    )
  })

  mac_data <- reactive({ data_raw()$mac })
  rtx_data <- reactive({ data_raw()$rtx })
  mac_latest <- reactive({ latest_row(mac_data()) })
  rtx_latest <- reactive({ latest_row(rtx_data()) })

  # -- Last sync --
  output$last_sync <- renderText({
    auto_refresh()
    format(Sys.time(), "%H:%M:%S")
  })

  # -- Stall banner --
  output$stall_banner <- renderUI({
    mac_mins <- mins_since_update(mac_data())
    rtx_mins <- mins_since_update(rtx_data())
    stalls <- c()
    if (mac_mins > STALL_MINS) stalls <- c(stalls, sprintf("MAC (%.0f min ago)", mac_mins))
    if (rtx_mins > STALL_MINS) stalls <- c(stalls, sprintf("RTX3090 (%.0f min ago)", rtx_mins))
    if (length(stalls) > 0) {
      div(class = "stall-banner",
          "⚠ STALL DETECTED:", paste(stalls, collapse = " · "))
    }
  })

  # ---- MACHINE PANEL BUILDER ----
  make_machine_panel <- function(lr, css_class, label) {
    if (is.null(lr)) {
      return(div(class = paste("machine-panel", css_class),
                 div(class = "machine-title", label),
                 div(style="color:#4a5568;font-size:12px;", "No data yet.")))
    }

    pct      <- lr$pct_complete %||% 0
    done     <- lr$articles_done %||% 0
    lph      <- if (!is.na(lr$loops_per_hour)) sprintf("%.1f", lr$loops_per_hour) else "—"
    alm      <- if (!is.na(lr$avg_loop_mins))  sprintf("%.2f", lr$avg_loop_mins)  else "—"
    remaining <- TOTAL_ARTS - done
    eta <- if (!is.na(lr$avg_loop_mins) && lr$avg_loop_mins > 0) {
      hrs <- remaining * lr$avg_loop_mins / 60
      if (hrs > 24) sprintf("%.1f days", hrs / 24) else sprintf("%.1f hrs", hrs)
    } else "—"
    fails    <- lr$failure_count %||% 0
    fail_r   <- if (!is.na(lr$failure_rate_pct)) sprintf("%.2f%%", lr$failure_rate_pct) else "—"
    mins_ago <- mins_since_update(if(css_class=="mac") mac_data() else rtx_data())
    dot_cls  <- if (mins_ago > STALL_MINS) "stall" else "live"

    div(class = paste("machine-panel", css_class),
      div(class = "machine-title",
          tags$span(class = paste("stall-dot", dot_cls)),
          label),
      div(class = "model-tag",
          lr$model_name %||% "unknown model",
          " · updated ", sprintf("%.1f", mins_ago), " min ago"),

      # Progress bar
      div(class = "prog-wrap",
          div(class = "prog-bar", style = paste0("width:", pct, "%"))),
      div(class = "prog-label",
          span(paste0(format(done, big.mark=","), " / ",
                      format(TOTAL_ARTS, big.mark=","), " articles")),
          span(paste0(round(pct, 1), "%"))),

      # Stat grid
      div(class = "stat-grid",
          div(class = "stat-box",
              div(class="label","ETA"),
              div(class="value", style="font-size:13px;", eta)),
          div(class = "stat-box",
              div(class="label","Loops / hr"),
              div(class="value", lph)),
          div(class = "stat-box",
              div(class="label","Mins / loop"),
              div(class="value", alm)),
          div(class = "stat-box",
              div(class="label","Failures"),
              div(class=paste("value", if(fails>0)"warn" else "ok"),
                  format(fails, big.mark=","))),
          div(class = "stat-box",
              div(class="label","Fail rate"),
              div(class=paste("value", if(!is.na(lr$failure_rate_pct) && lr$failure_rate_pct>2)"warn" else "ok"),
                  fail_r)),
          div(class = "stat-box",
              div(class="label","% done"),
              div(class="value ok", paste0(round(pct,1), "%")))
      )
    )
  }

  output$mac_progress_panel <- renderUI({
    make_machine_panel(mac_latest(), "mac", "M4 MAX — MAC")
  })
  output$rtx_progress_panel <- renderUI({
    make_machine_panel(rtx_latest(), "rtx", "RTX 3090 — DESKTOP")
  })

  # ---- SYSTEM HEALTH PANEL BUILDER ----
  make_gauge <- function(label, value, max_val = 100, cls) {
    pct <- if (!is.na(value)) min(value / max_val * 100, 100) else 0
    val_str <- if (!is.na(value)) paste0(round(value, 1),
                                          if(cls == "temp") "°C" else "%") else "—"
    div(class = "gauge-item",
        div(class = "gauge-label", span(label), span(val_str)),
        div(class = "gauge-track",
            div(class = paste("gauge-fill", cls),
                style = paste0("width:", pct, "%"))))
  }

  make_sys_panel <- function(lr, css_class, label) {
    if (is.null(lr)) {
      return(div(class = paste("sys-panel", css_class),
                 div(class="sys-title", label),
                 div(style="color:#4a5568;font-size:12px;","No data.")))
    }
    div(class = paste("sys-panel", css_class),
        div(class = "sys-title", label),
        div(class = "gauge-row",
            make_gauge("CPU", lr$cpu_pct, 100, "cpu"),
            make_gauge("RAM", lr$ram_pct, 100, "ram"),
            make_gauge("GPU util", lr$gpu_pct, 100, "gpu"),
            make_gauge("GPU mem", lr$gpu_mem_pct, 100, "gpu"),
            make_gauge("CPU temp", lr$cpu_temp, 110, "temp"),
            make_gauge("GPU temp", lr$gpu_temp, 110, "temp")
        )
    )
  }

  output$mac_sys_panel <- renderUI({ make_sys_panel(mac_latest(), "mac", "M4 Max") })
  output$rtx_sys_panel <- renderUI({ make_sys_panel(rtx_latest(), "rtx", "RTX 3090") })

  # ---- QUALITY SPOT-CHECK ----
  make_critique_panel <- function(df, label, colour) {
    if (is.null(df) || nrow(df) == 0) {
      return(div(class="critique-box",
                 div(class="critique-meta", label),
                 div(class="critique-text","No critiques yet.")))
    }
    # Random sample from recent 20 rows
    recent <- tail(df, 20)
    row <- recent[sample(nrow(recent), 1), ]
    div(class = "critique-box",
        div(class = "critique-meta",
            tags$span(style=paste0("color:",colour,";"), label),
            " · article ", row$article_id %||% "?",
            " · ", format(row$timestamp, "%Y-%m-%d %H:%M")),
        div(class = "critique-text",
            row$last_critique %||% "No critique text."))
  }

  output$mac_critique <- renderUI({
    make_critique_panel(mac_data(), "M4 Max sample", MAC_COL)
  })
  output$rtx_critique <- renderUI({
    make_critique_panel(rtx_data(), "RTX 3090 sample", RTX_COL)
  })

  # ---- PLOTS ----

  combined_data <- reactive({
    mac <- mac_data()
    rtx <- rtx_data()
    if (!is.null(mac)) mac$machine <- "M4 Max"
    if (!is.null(rtx)) rtx$machine <- "RTX 3090"
    bind_rows(mac, rtx)
  })

  plot_colours <- c("M4 Max" = MAC_COL, "RTX 3090" = RTX_COL)

  dark_plotly <- function(p) {
    p %>% plotly::layout(
      paper_bgcolor = "#0d1117",
      plot_bgcolor  = "#0d1117",
      font          = list(color = "#8b9ab0", family = "JetBrains Mono"),
      xaxis         = list(gridcolor = "#1e2a38", zerolinecolor = "#1e2a38"),
      yaxis         = list(gridcolor = "#1e2a38", zerolinecolor = "#1e2a38"),
      legend        = list(bgcolor = "#0d1117", font = list(color = "#8b9ab0"))
    )
  }

  output$plot_throughput <- renderPlotly({
    df <- combined_data()
    req(nrow(df) > 0)
    p <- ggplot(df, aes(x = timestamp, y = loops_per_hour, colour = machine)) +
      geom_line(linewidth = 0.8, na.rm = TRUE) +
      geom_point(size = 1.5, na.rm = TRUE) +
      scale_colour_manual(values = plot_colours) +
      labs(title = "Loops per hour over time", x = NULL, y = "Loops / hr", colour = NULL) +
      theme_monitor()
    dark_plotly(ggplotly(p))
  })

  output$plot_looptime <- renderPlotly({
    df <- combined_data()
    req(nrow(df) > 0)
    p <- ggplot(df, aes(x = articles_done, y = avg_loop_mins, colour = machine)) +
      geom_point(size = 1.5, alpha = 0.7, na.rm = TRUE) +
      geom_smooth(se = FALSE, linewidth = 0.8, method = "loess", formula = y~x, na.rm = TRUE) +
      scale_colour_manual(values = plot_colours) +
      labs(title = "Loop time by article index", x = "Articles done", y = "Avg mins / loop", colour = NULL) +
      theme_monitor()
    dark_plotly(ggplotly(p))
  })

  output$plot_sysload <- renderPlotly({
    df <- combined_data()
    req(nrow(df) > 0)
    # Long format for cpu/ram/gpu
    df_long <- df %>%
      select(timestamp, machine, cpu_pct, ram_pct, gpu_pct) %>%
      tidyr::pivot_longer(c(cpu_pct, ram_pct, gpu_pct),
                          names_to = "resource", values_to = "pct") %>%
      mutate(resource = recode(resource,
                               cpu_pct = "CPU", ram_pct = "RAM", gpu_pct = "GPU"))
    p <- ggplot(df_long, aes(x = timestamp, y = pct, colour = resource, linetype = machine)) +
      geom_line(linewidth = 0.7, na.rm = TRUE) +
      scale_colour_manual(values = c(CPU="#5b9cf6", RAM="#a78bfa", GPU="#fb923c")) +
      scale_linetype_manual(values = c("M4 Max"="solid","RTX 3090"="dashed")) +
      labs(title = "System load over time", x = NULL, y = "Usage %",
           colour = "Resource", linetype = "Machine") +
      theme_monitor()
    dark_plotly(ggplotly(p))
  })

  output$plot_temp <- renderPlotly({
    df <- combined_data()
    req(nrow(df) > 0)
    df_temp <- df %>%
      select(timestamp, machine, cpu_temp, gpu_temp) %>%
      tidyr::pivot_longer(c(cpu_temp, gpu_temp),
                          names_to = "sensor", values_to = "temp") %>%
      mutate(sensor = recode(sensor, cpu_temp = "CPU", gpu_temp = "GPU"))
    p <- ggplot(df_temp, aes(x = timestamp, y = temp,
                              colour = machine, linetype = sensor)) +
      geom_line(linewidth = 0.8, na.rm = TRUE) +
      scale_colour_manual(values = plot_colours) +
      scale_linetype_manual(values = c(CPU="solid", GPU="dashed")) +
      labs(title = "Temperature over time", x = NULL, y = "°C",
           colour = "Machine", linetype = "Sensor") +
      theme_monitor()
    dark_plotly(ggplotly(p))
  })

  output$plot_cumulative <- renderPlotly({
    df <- combined_data()
    req(nrow(df) > 0)
    # On-track reference line
    if (nrow(df) > 0) {
      t_start <- min(df$timestamp, na.rm = TRUE)
      t_end   <- max(df$timestamp, na.rm = TRUE)
      elapsed_hrs <- as.numeric(difftime(t_end, t_start, units = "hours"))
    }
    p <- ggplot(df, aes(x = timestamp, y = articles_done, colour = machine)) +
      geom_line(linewidth = 1, na.rm = TRUE) +
      geom_hline(yintercept = TOTAL_ARTS, linetype = "dotted",
                 colour = "#4a5568", linewidth = 0.5) +
      scale_colour_manual(values = plot_colours) +
      scale_y_continuous(labels = scales::comma) +
      labs(title = "Cumulative articles completed", x = NULL,
           y = "Articles done", colour = NULL) +
      theme_monitor()
    dark_plotly(ggplotly(p))
  })

  output$plot_failures <- renderPlotly({
    df <- combined_data()
    req(nrow(df) > 0)
    p <- ggplot(df, aes(x = timestamp, y = failure_rate_pct, colour = machine)) +
      geom_line(linewidth = 0.8, na.rm = TRUE) +
      geom_hline(yintercept = 2, linetype = "dashed",
                 colour = "#f39c12", linewidth = 0.5) +
      scale_colour_manual(values = plot_colours) +
      labs(title = "Failure rate over time",
           subtitle = "Dashed line = 2% warning threshold",
           x = NULL, y = "Failure rate (%)", colour = NULL) +
      theme_monitor()
    dark_plotly(ggplotly(p))
  })
}

shinyApp(ui = ui, server = server)