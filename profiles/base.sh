#!/usr/bin/env bash
# Base profile — runs on every fresh install before project-specific profiles.
# Called via SSH from the forged control script on lumina.
set -euo pipefail

echo "=== forged: base profile ==="

# Verify KVM
if command -v kvm-ok &>/dev/null; then
    kvm-ok || echo "WARNING: KVM not available"
fi

# Ensure brad is in kvm group
sudo usermod -aG kvm "$(whoami)" 2>/dev/null || true

# Update package cache
sudo apt update

# Rust (if not already installed)
if ! command -v cargo &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

echo "=== base profile complete ==="
