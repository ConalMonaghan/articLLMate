# ==============================================================================
# SCRIPT 02: PHASE 1.5 EMBEDDING & CLUSTERING
# ==============================================================================
# PURPOSE:  Cluster themes using nuanced context (Label + Type + Quote).
#           Timer and Progress Bar focus strictly on the API/Embedding step.
# INPUT:    output/phase1_raw/phase1_raw_themes.csv
# OUTPUT:   output/phase1_clusters/clustered_themes.csv
# ==============================================================================

library(here)
library(tidyverse)
library(reticulate)
library(stats)
library(tictoc) 
library(igraph) # The graph theory engine

# 1. SETUP & LOAD DATA
# ------------------------------------------------------------------------------
INPUT_FILE <- here("output", "phase1_raw", "phase1_raw_themes.csv")
OUTPUT_DIR <- here("output", "phase1_clusters")

if (!dir.exists(OUTPUT_DIR)) dir.create(OUTPUT_DIR, recursive = TRUE)

# Load data
if (!file.exists(INPUT_FILE)) stop("Input file not found. Run Script 1 first.")
df_raw <- read_csv(INPUT_FILE, show_col_types = FALSE)

cat(sprintf("Loaded %d raw themes.\n", nrow(df_raw)))

# 2. PREPARE RICH TEXT
# ------------------------------------------------------------------------------
# Combine Label, Type, and Quote so the AI understands the full nuance.
df_prepared <- df_raw %>%
  mutate(
    embedding_text = paste0(
      "Theme: ", replace_na(theme_label, ""), "\n",
      "Type: ", replace_na(theme_type, ""), "\n",
      "Evidence: ", replace_na(quote, "")
    )
  )

cat("Rich text prepared. Initializing Python connection...\n")

# 3. PYTHON ENVIRONMENT SETUP
# ------------------------------------------------------------------------------
if (!py_available()) stop("Python not initialized.")

openai <- import("openai")
# Sys.setenv(OPENAI_API_KEY = "sk-...") 

# Define Python function for batch embedding
py_run_string("
import os
from openai import OpenAI

def get_batch_embeddings(text_list, model='text-embedding-3-small'):
    client = OpenAI(api_key=os.environ.get('OPENAI_API_KEY'))
    # Clean newlines for best results
    cleaned_texts = [t.replace('\\n', ' ') for t in text_list]
    
    response = client.embeddings.create(
        input=cleaned_texts,
        model=model
    )
    # Return embeddings in order
    return [d.embedding for d in response.data]
")

# 4. GENERATE EMBEDDINGS (TIMER STARTS HERE)
# ------------------------------------------------------------------------------
# Settings for batching
BATCH_SIZE <- 20
total_rows <- nrow(df_prepared)
num_batches <- ceiling(total_rows / BATCH_SIZE)
all_embeddings <- list()

cat(sprintf("\nStarting Embeddings for %d items (%d batches)...\n", total_rows, num_batches))

# --- TIC: Start Embedding Timer ---
tictoc::tic("Embedding Generation") 

# Setup Progress Bar
pb <- txtProgressBar(min = 0, max = num_batches, style = 3)

for (i in 1:num_batches) {
  # Calculate indices
  start_idx <- ((i - 1) * BATCH_SIZE) + 1
  end_idx   <- min(i * BATCH_SIZE, total_rows)
  
  # Get text chunk
  batch_text <- df_prepared$embedding_text[start_idx:end_idx]
  
  # Call Python API
  batch_vectors <- py$get_batch_embeddings(batch_text)
  
  # Store results
  all_embeddings <- c(all_embeddings, batch_vectors)
  
  # Update Progress Bar
  setTxtProgressBar(pb, i)
}
close(pb)

# --- TOC: End Embedding Timer ---
tictoc::toc() 

###########################
##### Convert list to Matrix #############
vectors_mat <- do.call(rbind, all_embeddings)

# 3. HIERARCHICAL TMFG (THE CLUSTERING)
# ------------------------------------------------------------------------------
cat("\nRunning Hierarchical TMFG...\n")

# TRANSPOSE TRICK: Make Themes the Columns so EGA clusters the Themes
data_for_ega <- t(vectors_mat) 

tictoc::tic("Hierarchical Analysis")
hega_result <- hierEGA(
  data = data_for_ega,
  model = "TMFG", 
  lower.algorithm = "louvain",
  higher.algorithm = "leiden",
  scores = "network",
  plot.EGA = FALSE
)
tictoc::toc()

# 4. ASSIGN & SAVE (CORRECTED MAPPING)
# ------------------------------------------------------------------------------
# 1. Assign Lower Level
# Ensure it is numeric (1, 2, 3...)
df_raw$cluster_lower <- as.numeric(hega_result$lower_order$wc)

# 2. Assign Higher Level (Fixing the "001" vs "1" Mismatch)
# Get the mapping vector
upper_map <- hega_result$higher_order$wc

# CLEAN THE NAMES: Convert "001" -> "1" so they match our dataframe
names(upper_map) <- as.numeric(names(upper_map))

# Perform the Lookup
# We convert cluster_lower to character so it acts as a name lookup
df_raw$cluster_upper <- upper_map[as.character(df_raw$cluster_lower)]

# 3. Save
write_csv(df_raw, here("output", "phase1_clusters", "clustered_themes_hierarchical.csv"))
cat(sprintf("\nSaved CSV. Mapped %d lower clusters to %d upper clusters.\n", 
            length(unique(df_raw$cluster_lower)), 
            length(unique(df_raw$cluster_upper))))

# 5. VISUALIZATION (ROBUST FALLBACK)
# ------------------------------------------------------------------------------
# Using qgraph directly to avoid the "incorrect edge.size" error in EGAnet
library(qgraph)

pdf(here("output", "phase1_clusters", "hierarchical_network.pdf"), width = 15, height = 15)

# 1. Get the network structure (Adjacency Matrix of Lower Themes)
lower_graph <- hega_result$lower_order$network

# 2. Get the groupings (Higher Order Clusters)
# We create a list where each Upper ID contains the Lower IDs that belong to it.
upper_groups <- split(
  as.numeric(names(hega_result$higher_order$wc)), # The Lower Cluster IDs
  hega_result$higher_order$wc                     # The Upper Cluster IDs
)

# 3. Plot
qgraph(
  lower_graph,
  layout = "spring",           # Force-directed layout
  groups = upper_groups,       # Color nodes by Meta-Theme
  title = "Hierarchical Network (TMFG)",
  legend = FALSE,              # Hide legend (too many groups)
  borders = FALSE,
  vsize = 3,
  edge.width = 0.5             # Thinner edges for cleaner look
)

dev.off()

cat("\nPlot saved to 'output/phase1_clusters/hierarchical_network.pdf'\n")# 4. ASSIGN & SAVE (CORRECTED MAPPING)
# ------------------------------------------------------------------------------
# 1. Assign Lower Level
# Ensure it is numeric (1, 2, 3...)
df_raw$cluster_lower <- as.numeric(hega_result$lower_order$wc)

# 2. Assign Higher Level (Fixing the "001" vs "1" Mismatch)
# Get the mapping vector
upper_map <- hega_result$higher_order$wc

# CLEAN THE NAMES: Convert "001" -> "1" so they match our dataframe
names(upper_map) <- as.numeric(names(upper_map))

# Perform the Lookup
# We convert cluster_lower to character so it acts as a name lookup
df_raw$cluster_upper <- upper_map[as.character(df_raw$cluster_lower)]

# 3. Save
write_csv(df_raw, here("output", "phase1_clusters", "clustered_themes_hierarchical.csv"))
cat(sprintf("\nSaved CSV. Mapped %d lower clusters to %d upper clusters.\n", 
            length(unique(df_raw$cluster_lower)), 
            length(unique(df_raw$cluster_upper))))

# 5. VISUALIZATION (ROBUST FALLBACK)
# ------------------------------------------------------------------------------
# Using qgraph directly to avoid the "incorrect edge.size" error in EGAnet
library(qgraph)

pdf(here("output", "phase1_clusters", "hierarchical_network.pdf"), width = 15, height = 15)

# 1. Get the network structure (Adjacency Matrix of Lower Themes)
lower_graph <- hega_result$lower_order$network

# 2. Get the groupings (Higher Order Clusters)
# We create a list where each Upper ID contains the Lower IDs that belong to it.
upper_groups <- split(
  as.numeric(names(hega_result$higher_order$wc)), # The Lower Cluster IDs
  hega_result$higher_order$wc                     # The Upper Cluster IDs
)

# 3. Plot
qgraph(
  lower_graph,
  layout = "spring",           # Force-directed layout
  groups = upper_groups,       # Color nodes by Meta-Theme
  title = "Hierarchical Network (TMFG)",
  legend = FALSE,              # Hide legend (too many groups)
  borders = FALSE,
  vsize = 3,
  edge.width = 0.5             # Thinner edges for cleaner look
)

dev.off()

cat("\nPlot saved to 'output/phase1_clusters/hierarchical_network.pdf'\n")