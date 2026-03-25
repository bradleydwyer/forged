#!/usr/bin/env bash
# Fossik profile — installs GPU drivers and embedding infrastructure.
set -euo pipefail

echo "=== forged: fossik profile ==="

# NVIDIA driver + CUDA toolkit (for RTX 4090)
if ! command -v nvidia-smi &>/dev/null; then
    echo "Installing NVIDIA drivers..."
    sudo apt install -y nvidia-driver-550 nvidia-cuda-toolkit
    echo "NOTE: Reboot required for NVIDIA drivers to load."
fi

# Python ML dependencies
sudo apt install -y python3-venv

# Clone and build fossik
source "$HOME/.cargo/env"
if [ ! -d "$HOME/fossik" ]; then
    echo "Cloning fossik..."
    git clone git@github.com:braddwyer/fossik.git "$HOME/fossik"
fi

cd "$HOME/fossik"
git pull

echo "=== fossik profile complete ==="
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
fi
