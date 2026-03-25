#!/usr/bin/env bash
#
# forged — bare metal provisioning control
#
# Manages PXE boot modes and provisioning for bare metal machines
# from a Mac Studio running Docker.
#
set -euo pipefail

FORGED_DIR="$(cd "$(dirname "$0")" && pwd)"

# Configuration — edit these for your setup
FORGED_HOST="${FORGED_HOST:-lumina.local}"
FORGED_PORT="${FORGED_PORT:-8070}"
TARGET_HOST="${TARGET_HOST:-hotcell-bench}"
TARGET_MAC="${TARGET_MAC:-}"  # Set to desktop's MAC for WoL

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

API="http://${FORGED_HOST}:${FORGED_PORT}"

log()  { echo -e "${DIM}$*${RESET}"; }
info() { echo -e "${CYAN}$*${RESET}"; }
ok()   { echo -e "${GREEN}$*${RESET}"; }
err()  { echo -e "${RED}$*${RESET}" >&2; }
bold() { echo -e "${BOLD}$*${RESET}"; }

# Check if the forged HTTP server is reachable
api_ok() {
    curl -sf --connect-timeout 2 "${API}/status" >/dev/null 2>&1
}

# Check if the target machine is reachable via SSH
target_ok() {
    ssh -o ConnectTimeout=3 -o BatchMode=yes "${TARGET_HOST}" true 2>/dev/null
}

cmd_up() {
    info "Starting forged services..."
    cd "$FORGED_DIR"

    # Resolve current IP for dnsmasq config
    local ip
    ip=$(python3 -c "import socket; print(socket.gethostbyname('${FORGED_HOST}'))" 2>/dev/null || true)
    if [ -z "$ip" ]; then
        ip=$(ifconfig | grep -A2 'en0\|en1' | grep 'inet ' | head -1 | awk '{print $2}')
    fi
    if [ -z "$ip" ]; then
        err "Cannot determine host IP. Set FORGED_HOST or check network."
        exit 1
    fi
    export SERVER_IP="$ip"
    log "Host IP: $ip"

    # Write resolved dnsmasq config (substitute SERVER_IP)
    sed "s/\${SERVER_IP}/$ip/g" config/dnsmasq.conf > data/dnsmasq.conf.resolved

    docker compose up -d --build
    ok "Forged services running on ${FORGED_HOST}:${FORGED_PORT}"
}

cmd_down() {
    info "Stopping forged services..."
    cd "$FORGED_DIR"
    docker compose down
    ok "Forged services stopped."
}

cmd_logs() {
    cd "$FORGED_DIR"
    docker compose logs -f "${1:-}"
}

cmd_boot() {
    local mode="${1:-}"
    if [ -z "$mode" ]; then
        err "Usage: ./ctl boot <linux|windows|reimage>"
        exit 1
    fi
    if [[ ! "$mode" =~ ^(linux|windows|reimage)$ ]]; then
        err "Invalid mode: $mode (must be linux, windows, or reimage)"
        exit 1
    fi

    if ! api_ok; then
        err "Forged HTTP server not reachable at ${API}"
        err "Run './ctl up' first."
        exit 1
    fi

    curl -sf -X POST "${API}/mode/${mode}" || { err "Failed to set mode"; exit 1; }
    ok "Boot mode set to: ${mode}"

    if [ "$mode" = "reimage" ]; then
        log "Next boot will re-image the Linux drive."
        log "Use './ctl reboot' to trigger it, or './ctl wake' if the machine is off."
    fi
}

cmd_reimage() {
    local profile="base"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile) profile="$2"; shift 2 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    if ! api_ok; then
        err "Forged HTTP server not reachable at ${API}"
        err "Run './ctl up' first."
        exit 1
    fi

    bold "Re-imaging ${TARGET_HOST} with profile: ${profile}"
    echo ""

    # Set mode and profile
    curl -sf -X POST "${API}/mode/reimage" >/dev/null
    curl -sf -X POST "${API}/profile/${profile}" >/dev/null
    ok "Mode: reimage | Profile: ${profile}"

    # Reboot or wake the target
    if target_ok; then
        log "Target is reachable — rebooting via SSH..."
        ssh "${TARGET_HOST}" sudo reboot 2>/dev/null || true
    elif [ -n "${TARGET_MAC}" ]; then
        log "Target not reachable — sending Wake-on-LAN..."
        cmd_wake
    else
        err "Target not reachable and no MAC address configured for WoL."
        err "Set TARGET_MAC in this script or power on the machine manually."
        err "Mode is set to reimage — next PXE boot will re-image."
        exit 1
    fi

    echo ""
    info "Waiting for autoinstall to complete..."
    log "(This typically takes 5-10 minutes)"
    echo ""

    # Wait for the mode to reset to linux (autoinstall calls /api/install-complete)
    local waited=0
    while [ $waited -lt 900 ]; do
        local current_mode
        current_mode=$(curl -sf "${API}/mode" 2>/dev/null || echo "unknown")
        if [ "$current_mode" = "linux" ]; then
            ok "Autoinstall complete! Mode reset to linux."
            break
        fi
        sleep 10
        waited=$((waited + 10))
        if (( waited % 60 == 0 )); then
            log "  Still waiting... (${waited}s, mode=${current_mode})"
        fi
    done

    if [ $waited -ge 900 ]; then
        err "Timed out waiting for autoinstall (15 minutes)."
        err "Check the desktop console for errors."
        exit 1
    fi

    # Wait for SSH to become available after reboot
    echo ""
    info "Waiting for SSH..."
    for i in $(seq 1 60); do
        if target_ok; then
            ok "SSH available!"
            break
        fi
        sleep 5
    done

    if ! target_ok; then
        err "SSH not available after 5 minutes. Check the desktop."
        exit 1
    fi

    # Run provisioning
    cmd_provision --profile "$profile"
}

cmd_provision() {
    local profile="base"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile) profile="$2"; shift 2 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    if ! target_ok; then
        err "Target ${TARGET_HOST} not reachable via SSH."
        exit 1
    fi

    bold "Provisioning ${TARGET_HOST} with profile: ${profile}"
    echo ""

    # Always run base first
    if [ -f "${FORGED_DIR}/profiles/base.sh" ]; then
        log "Running base profile..."
        ssh "${TARGET_HOST}" 'bash -s' < "${FORGED_DIR}/profiles/base.sh"
        echo ""
    fi

    # Run the requested profile (if not base)
    if [ "$profile" != "base" ]; then
        local profile_script="${FORGED_DIR}/profiles/${profile}.sh"
        if [ ! -f "$profile_script" ]; then
            err "Profile not found: ${profile_script}"
            exit 1
        fi
        log "Running ${profile} profile..."
        ssh "${TARGET_HOST}" 'bash -s' < "$profile_script"
        echo ""
    fi

    ok "Provisioning complete!"
}

cmd_status() {
    bold "forged status"
    echo ""

    # Server status
    if api_ok; then
        local status
        status=$(curl -sf "${API}/status")
        local mode profile
        mode=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin)['mode'])" 2>/dev/null || echo "unknown")
        profile=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin)['profile'])" 2>/dev/null || echo "unknown")
        ok "  Server: running (${API})"
        echo -e "  Mode:    ${BOLD}${mode}${RESET}"
        echo -e "  Profile: ${profile}"
    else
        err "  Server: not running"
    fi

    # Target status
    if target_ok; then
        local uname_info
        uname_info=$(ssh -o ConnectTimeout=3 "${TARGET_HOST}" 'uname -r' 2>/dev/null || echo "?")
        ok "  Target: reachable (${TARGET_HOST}, kernel ${uname_info})"
    else
        err "  Target: not reachable (${TARGET_HOST})"
    fi
}

cmd_reboot() {
    if ! target_ok; then
        err "Target ${TARGET_HOST} not reachable via SSH."
        if [ -n "${TARGET_MAC}" ]; then
            log "Try './ctl wake' to power it on."
        fi
        exit 1
    fi
    info "Rebooting ${TARGET_HOST}..."
    ssh "${TARGET_HOST}" sudo reboot 2>/dev/null || true
    ok "Reboot command sent."
}

cmd_wake() {
    if [ -z "${TARGET_MAC}" ]; then
        err "No MAC address configured. Set TARGET_MAC in the script."
        exit 1
    fi
    info "Sending Wake-on-LAN to ${TARGET_MAC}..."
    if command -v wakeonlan &>/dev/null; then
        wakeonlan "${TARGET_MAC}"
    elif command -v wol &>/dev/null; then
        wol "${TARGET_MAC}"
    else
        # Python fallback
        python3 -c "
import socket, struct
mac = '${TARGET_MAC}'.replace(':', '').replace('-', '')
data = b'\\xff' * 6 + bytes.fromhex(mac) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(data, ('255.255.255.255', 9))
print('WoL packet sent')
"
    fi
    ok "Wake-on-LAN packet sent."
}

cmd_ssh() {
    ssh "${TARGET_HOST}" "$@"
}

cmd_setup() {
    bold "forged setup"
    echo ""
    info "This will prepare the forged server for first use."
    echo ""

    # Create data directory
    mkdir -p "${FORGED_DIR}/data"

    # Download iPXE EFI binary if not present
    if [ ! -f "${FORGED_DIR}/config/ipxe/ipxe.efi" ]; then
        info "Downloading iPXE EFI binary..."
        curl -sL "https://boot.ipxe.org/ipxe.efi" -o "${FORGED_DIR}/config/ipxe/ipxe.efi"
        ok "Downloaded ipxe.efi"
    else
        log "ipxe.efi already present"
    fi

    # Download Ubuntu installer if not present
    if [ ! -f "${FORGED_DIR}/config/ubuntu/vmlinuz" ]; then
        info "Downloading Ubuntu 24.04 Server installer..."
        local iso_url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
        local iso_path="/tmp/ubuntu-24.04-server.iso"

        if [ ! -f "$iso_path" ]; then
            curl -L "$iso_url" -o "$iso_path"
        fi

        # Extract kernel and initrd from ISO
        local mount_dir
        mount_dir=$(mktemp -d)
        log "Extracting kernel and initrd from ISO..."

        # On macOS, use hdiutil to mount ISO
        if [[ "$(uname)" == "Darwin" ]]; then
            hdiutil attach "$iso_path" -mountpoint "$mount_dir" -nobrowse -quiet
            cp "$mount_dir/casper/vmlinuz" "${FORGED_DIR}/config/ubuntu/vmlinuz"
            cp "$mount_dir/casper/initrd" "${FORGED_DIR}/config/ubuntu/initrd"
            hdiutil detach "$mount_dir" -quiet
        else
            sudo mount -o loop "$iso_path" "$mount_dir"
            cp "$mount_dir/casper/vmlinuz" "${FORGED_DIR}/config/ubuntu/vmlinuz"
            cp "$mount_dir/casper/initrd" "${FORGED_DIR}/config/ubuntu/initrd"
            sudo umount "$mount_dir"
        fi
        rmdir "$mount_dir"
        ok "Extracted vmlinuz and initrd"
    else
        log "Ubuntu installer files already present"
    fi

    # Check autoinstall config
    if grep -q "LINUX_NVME_SERIAL" "${FORGED_DIR}/config/autoinstall/user-data"; then
        echo ""
        err "WARNING: autoinstall/user-data still has placeholder values!"
        err "You must update:"
        err "  1. LINUX_NVME_SERIAL — get from Windows: Get-PhysicalDisk | Select SerialNumber"
        err "  2. SSH public key — replace REPLACE_WITH_YOUR_SSH_PUBLIC_KEY"
        err "  3. Password hash — generate with: mkpasswd -m sha-512 <password>"
    fi

    # Check MAC address
    if [ -z "${TARGET_MAC}" ]; then
        echo ""
        log "NOTE: TARGET_MAC not set. Wake-on-LAN won't work."
        log "Set it in this script or export TARGET_MAC=AA:BB:CC:DD:EE:FF"
    fi

    echo ""
    ok "Setup complete. Next steps:"
    echo "  1. Update config/autoinstall/user-data with NVMe serial + SSH key"
    echo "  2. Run './ctl up' to start services"
    echo "  3. Configure desktop BIOS (PXE first, SVM on, Secure Boot off)"
    echo "  4. Run './ctl reimage --profile hotcell' to install Linux"
}

cmd_help() {
    bold "forged — bare metal provisioning"
    echo ""
    echo "Usage: ./ctl <command> [options]"
    echo ""
    echo "Setup:"
    echo "  setup                     Download dependencies and check config"
    echo "  up                        Start forged Docker services"
    echo "  down                      Stop forged Docker services"
    echo "  logs [service]            Tail service logs"
    echo ""
    echo "Boot control:"
    echo "  boot <linux|windows>      Set boot mode (persistent)"
    echo "  reimage --profile NAME    Wipe + reinstall Linux, then provision"
    echo "  reboot                    Reboot the target machine"
    echo "  wake                      Send Wake-on-LAN packet"
    echo ""
    echo "Provisioning:"
    echo "  provision --profile NAME  Run provisioning on existing install"
    echo ""
    echo "Info:"
    echo "  status                    Show server and target status"
    echo "  ssh [cmd...]              SSH to target machine"
    echo "  help                      Show this help"
    echo ""
    echo "Environment:"
    echo "  FORGED_HOST    Server hostname  (default: lumina.local)"
    echo "  FORGED_PORT    Server HTTP port (default: 8070)"
    echo "  TARGET_HOST    Target hostname  (default: hotcell-bench)"
    echo "  TARGET_MAC     Target MAC addr  (for Wake-on-LAN)"
}

# Main dispatch
cmd="${1:-help}"
shift || true

case "$cmd" in
    up)        cmd_up "$@" ;;
    down)      cmd_down "$@" ;;
    logs)      cmd_logs "$@" ;;
    boot)      cmd_boot "$@" ;;
    reimage)   cmd_reimage "$@" ;;
    provision) cmd_provision "$@" ;;
    status)    cmd_status "$@" ;;
    reboot)    cmd_reboot "$@" ;;
    wake)      cmd_wake "$@" ;;
    ssh)       cmd_ssh "$@" ;;
    setup)     cmd_setup "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        err "Unknown command: $cmd"
        cmd_help
        exit 1
        ;;
esac
