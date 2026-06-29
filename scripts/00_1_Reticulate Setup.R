# === articLLMate Environment Setup ===

library(reticulate)

env_name <- "articLLMate"

# ---- Step 1: Detect platform ----
os <- Sys.info()["sysname"]
cat("Platform:", os, "\n")

if (os == "Darwin") {
  conda_bin <- "~/miniconda3/bin/conda"
} else {
  conda_bin <- "auto"  # reticulate will find it on Windows/Linux
}

# ---- Step 2: Check if environment exists ----
envs <- tryCatch(conda_list(conda = conda_bin), error = \(e) data.frame(name = character()))

if (env_name %in% envs$name) {
  cat("Environment '", env_name, "' found. Binding...\n", sep = "")
  use_condaenv(env_name, conda = conda_bin, required = TRUE)
  py_config()
  
  # ---- Guard against incomplete installs ----
  py_run_string("
import importlib
required = ['torch', 'openai', 'pandas', 'tiktoken', 'google.genai']
missing = [p for p in required if importlib.util.find_spec(p) is None]
if missing:
    print('WARNING - missing packages:', ', '.join(missing))
else:
    print('All required packages present.')
")

} else {
  cat("Environment '", env_name, "' not found. Creating...\n", sep = "")
  
  # ---- Step 3: Create environment ----
  conda_create(
    envname = env_name,
    python_version = "3.11",
    conda = conda_bin
  )
  
  # ---- Step 4: Install packages (platform-specific) ----
  common_pkgs <- c("openai", "pandas", "tiktoken", "google-generativeai", "anthropic", "google-genai")
  
  if (os == "Darwin") {
    # macOS: MPS acceleration via torch metal backend
    conda_install(env_name, common_pkgs, pip = TRUE, conda = conda_bin)
    conda_install(env_name, c("torch", "torchvision"), pip = TRUE, conda = conda_bin)
    # MPS is built into torch on arm64 mac — no extra install needed
    
  } else {
    # Windows/Linux: CUDA GPU support
    conda_install(env_name, common_pkgs, pip = TRUE, conda = conda_bin)
    conda_install(
      env_name,
      c("torch", "torchvision", "torchaudio"),
      pip = TRUE,
      pip_options = "--index-url https://download.pytorch.org/whl/cu121",
      conda = conda_bin
    )
  }
  
  use_condaenv(env_name, conda = conda_bin, required = TRUE)
  py_config()
}

# ---- Step 5: Verify acceleration ----
py_run_string("
import torch
if torch.backends.mps.is_available():
    print('Accelerator: MPS (Apple Silicon GPU)')
    device = 'mps'
elif torch.cuda.is_available():
    print(f'Accelerator: CUDA ({torch.cuda.get_device_name(0)})')
    device = 'cuda'
else:
    print('Accelerator: None (CPU only)')
    device = 'cpu'
print(f'Using device: {device}')
")