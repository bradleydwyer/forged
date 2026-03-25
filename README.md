# forged

Personal bare-metal provisioning system. PXE boots and re-images a dual-NVMe workstation from a Mac Studio, with automated Ubuntu autoinstall and post-install provisioning profiles.

Not intended for general use.

## How it works

A Mac Studio runs two Docker services — dnsmasq (ProxyDHCP/TFTP) and a Python HTTP server — that intercept PXE boot requests and serve iPXE scripts, Ubuntu installer images, and cloud-init configs. The boot mode (linux, windows, or reimage) is controlled via HTTP API and persists across reboots.

Re-imaging wipes the Linux NVMe (leaving the Windows drive untouched), installs Ubuntu 24.04 via autoinstall, then runs provisioning profiles over SSH.

## Usage

```
./ctl setup          # pull Docker images, download iPXE/kernel/initrd
./ctl up             # start services
./ctl mode linux     # set boot mode
./ctl reimage        # wipe and reinstall Linux
./ctl reimage --profile hotcell   # reinstall + provision
```

## Profiles

- **base** — KVM group, Rust toolchain
- **hotcell** — Firecracker, Cloud Hypervisor, VMM benchmarking
- **fossik** — NVIDIA drivers, CUDA, ML/embedding tooling

## Setup

Copy `.env.example` to `.env` and fill in your values. Update `config/autoinstall/user-data` with your NVMe serial and SSH key.
