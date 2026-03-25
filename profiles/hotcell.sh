#!/usr/bin/env bash
# Hotcell profile — installs VMM backends and builds hotcell for benchmarking.
set -euo pipefail

echo "=== forged: hotcell profile ==="

ARCH=$(uname -m)

# Firecracker
FC_VERSION="1.10.1"
if ! command -v firecracker &>/dev/null; then
    echo "Installing Firecracker v${FC_VERSION}..."
    cd /tmp
    curl -sLO "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-${ARCH}.tgz"
    tar xzf "firecracker-v${FC_VERSION}-${ARCH}.tgz"
    sudo mv "release-v${FC_VERSION}-${ARCH}/firecracker-v${FC_VERSION}-${ARCH}" /usr/local/bin/firecracker
    sudo mv "release-v${FC_VERSION}-${ARCH}/jailer-v${FC_VERSION}-${ARCH}" /usr/local/bin/jailer
    rm -rf "release-v${FC_VERSION}-${ARCH}" "firecracker-v${FC_VERSION}-${ARCH}.tgz"
fi

# Firecracker kernel
sudo mkdir -p /opt/hotcell/kernels
if [ ! -f /opt/hotcell/kernels/vmlinux ]; then
    echo "Downloading Firecracker kernel..."
    cd /tmp
    curl -sLO "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/vmlinux-5.10-${ARCH}.bin"
    sudo mv "vmlinux-5.10-${ARCH}.bin" /opt/hotcell/kernels/vmlinux
fi

# Cloud Hypervisor
CH_VERSION="v44.0"
if ! command -v cloud-hypervisor &>/dev/null; then
    echo "Installing Cloud Hypervisor ${CH_VERSION}..."
    curl -sLo /tmp/cloud-hypervisor "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/${CH_VERSION}/cloud-hypervisor-static"
    chmod +x /tmp/cloud-hypervisor
    sudo mv /tmp/cloud-hypervisor /usr/local/bin/cloud-hypervisor
fi

# virtiofsd (for Cloud Hypervisor)
if ! command -v virtiofsd &>/dev/null; then
    sudo apt install -y virtiofsd
fi

# Clone and build hotcell
source "$HOME/.cargo/env"
if [ ! -d "$HOME/hotcell" ]; then
    echo "Cloning hotcell..."
    git clone git@github.com:braddwyer/hotcell.git "$HOME/hotcell"
fi

echo "Building hotcell..."
cd "$HOME/hotcell"
git pull
cargo build --release

echo "=== hotcell profile complete ==="
echo ""
echo "Installed:"
echo "  firecracker: $(firecracker --version 2>&1 | head -1)"
echo "  cloud-hypervisor: $(cloud-hypervisor --version 2>&1 | head -1)"
echo "  kernel: /opt/hotcell/kernels/vmlinux"
echo "  hotcell: $(./target/release/hotcell --version 2>&1 || echo 'built')"
