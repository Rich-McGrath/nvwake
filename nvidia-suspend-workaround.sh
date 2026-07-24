#!/usr/bin/env bash
#
# nvidia-suspend-workaround.sh
#
# Works around two resume-from-suspend failures on Linux laptops with an
# NVIDIA GPU and DDR5 memory:
#
#   1. nvidia-drm: "Failed to register auto-value-update on pre-wait value
#      for sync FD semaphore surface"  -> VRAM not preserved across suspend
#   2. spd5118: "failed to resume async: error -6"  -> DDR5 SPD temperature
#      sensor can't reach the SMBus on resume
#
# These are workarounds, not fixes: the underlying bugs live in the NVIDIA
# driver and the kernel. Both may become unnecessary after a driver or
# kernel update -- check whether you still need this before applying it.
#
# Usage:
#   sudo ./nvidia-suspend-workaround.sh              # apply
#   sudo ./nvidia-suspend-workaround.sh --dry-run    # preview only
#   sudo ./nvidia-suspend-workaround.sh --revert     # undo
#
set -euo pipefail

NVIDIA_CONF=/etc/modprobe.d/nvidia-power-management.conf
SPD_CONF=/etc/modprobe.d/blacklist-spd5118.conf
TMPPATH=/var/tmp
STAMP=$(date +%Y%m%d-%H%M%S)

DRY_RUN=0
REVERT=0
CHANGED=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --revert)  REVERT=1 ;;
        -h|--help) sed -n '3,21p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

info()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32mok\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# ------------------------------------------------- initramfs tool detect ----
# The modprobe.d files are distro-neutral; only the initramfs rebuild differs.

detect_initramfs_tool() {
    if command -v update-initramfs >/dev/null 2>&1; then
        echo "update-initramfs"          # Debian, Ubuntu, Pop!_OS, Mint
    elif command -v dracut >/dev/null 2>&1; then
        echo "dracut"                    # Fedora, RHEL, openSUSE, recent Arch
    elif command -v mkinitcpio >/dev/null 2>&1; then
        echo "mkinitcpio"                # Arch, Manjaro, EndeavourOS
    else
        echo "none"
    fi
}

rebuild_initramfs() {
    local tool
    tool=$(detect_initramfs_tool)
    case "$tool" in
        update-initramfs) info "Rebuilding initramfs with update-initramfs"
                          run update-initramfs -u ;;
        dracut)           info "Rebuilding initramfs with dracut"
                          run dracut --force ;;
        mkinitcpio)       info "Rebuilding initramfs with mkinitcpio"
                          run mkinitcpio -P ;;
        none)             warn "No known initramfs tool found (update-initramfs, dracut, mkinitcpio)."
                          warn "Rebuild your initramfs manually before rebooting, or the"
                          warn "modprobe.d changes may not take effect early enough." ;;
    esac
}

# ---------------------------------------------------------------- checks ----

[[ $EUID -eq 0 ]] || die "Run this with sudo."

# ---------------------------------------------------------------- revert ----

if [[ $REVERT -eq 1 ]]; then
    info "Reverting changes"
    for f in "$NVIDIA_CONF" "$SPD_CONF"; do
        if [[ -f $f ]]; then
            run rm -f "$f"
            ok "removed $f"
            CHANGED=1
        fi
    done
    if [[ $CHANGED -eq 1 ]]; then
        rebuild_initramfs
        warn "Reboot to finish reverting."
    else
        ok "Nothing to revert."
    fi
    exit 0
fi

# ------------------------------------------------------------ environment ---

info "Kernel:    $(uname -r)"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    info "Distro:    $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
fi
info "Initramfs: $(detect_initramfs_tool)"

if ! lsmod | grep -q '^nvidia' && ! lspci 2>/dev/null | grep -qi 'nvidia'; then
    warn "No NVIDIA GPU or module detected. Skipping the NVIDIA portion."
    SKIP_NVIDIA=1
else
    SKIP_NVIDIA=0
    if command -v nvidia-smi >/dev/null 2>&1; then
        info "Driver:    $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    fi
fi

# --------------------------------------------- 1. NVIDIA preserve VRAM ------

if [[ $SKIP_NVIDIA -eq 0 ]]; then
    info "Configuring NVIDIA video memory preservation"

    # VRAM gets written to disk on suspend; make sure there's room for it.
    if command -v nvidia-smi >/dev/null 2>&1; then
        VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        AVAIL_MB=$(df -Pm "$TMPPATH" | awk 'NR==2 {print $4}')
        if [[ ${VRAM_MB:-0} -gt 0 && ${AVAIL_MB:-0} -lt ${VRAM_MB} ]]; then
            warn "$TMPPATH has ${AVAIL_MB}MB free but the GPU has ${VRAM_MB}MB of VRAM."
            warn "Suspend may fail to save VRAM. Free up space or edit NVreg_TemporaryFilePath."
        fi
    fi

    DESIRED_NVIDIA="# Written by nvidia-suspend-workaround.sh on ${STAMP}
# Preserve all VRAM across suspend/resume instead of only the console.
# Works around nvidia-drm sync/semaphore errors and black screens after wake.
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=${TMPPATH}"

    if [[ -f $NVIDIA_CONF ]] && grep -q 'NVreg_PreserveVideoMemoryAllocations=1' "$NVIDIA_CONF"; then
        ok "$NVIDIA_CONF already set"
    else
        if [[ -f $NVIDIA_CONF ]]; then
            run cp -a "$NVIDIA_CONF" "${NVIDIA_CONF}.bak.${STAMP}"
            warn "backed up existing config to ${NVIDIA_CONF}.bak.${STAMP}"
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '   [dry-run] would write %s:\n' "$NVIDIA_CONF"
            printf '%s\n' "$DESIRED_NVIDIA" | sed 's/^/      /'
        else
            printf '%s\n' "$DESIRED_NVIDIA" > "$NVIDIA_CONF"
            chmod 0644 "$NVIDIA_CONF"
        fi
        ok "wrote $NVIDIA_CONF"
        CHANGED=1
    fi

    # ------------------------------------ 2. NVIDIA power-management units ---
    info "Enabling NVIDIA power management services"
    if command -v systemctl >/dev/null 2>&1; then
        for unit in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
                if systemctl is-enabled "$unit" >/dev/null 2>&1; then
                    ok "$unit already enabled"
                else
                    run systemctl enable "$unit"
                    ok "enabled $unit"
                    CHANGED=1
                fi
            else
                warn "$unit not present (driver package may not ship it) - skipping"
            fi
        done
    else
        warn "systemd not found. On non-systemd systems, hook the driver's"
        warn "suspend/resume scripts into your init system manually."
    fi
fi

# ------------------------------------------- 3. blacklist spd5118 sensor ----

info "Blacklisting spd5118 (DDR5 SPD temperature sensor)"

if [[ -f $SPD_CONF ]] && grep -q '^blacklist spd5118' "$SPD_CONF"; then
    ok "$SPD_CONF already set"
else
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '   [dry-run] would write %s\n' "$SPD_CONF"
    else
        cat > "$SPD_CONF" <<EOF
# Written by nvidia-suspend-workaround.sh on ${STAMP}
# The DDR5 SPD hub temperature sensor fails to re-init on resume
# (dpm_run_callback: spd5118_resume returns -6). Only affects RAM
# temperature reporting; disabling it silences the error.
blacklist spd5118
EOF
        chmod 0644 "$SPD_CONF"
    fi
    ok "wrote $SPD_CONF"
    CHANGED=1
fi

# Unload it now so it isn't in the way before the reboot (ignore failure).
if lsmod | grep -q '^spd5118'; then
    run modprobe -r spd5118 2>/dev/null || warn "spd5118 in use, will stay unloaded after reboot"
fi

# ------------------------------------------------------------ initramfs -----

if [[ $CHANGED -eq 1 ]]; then
    rebuild_initramfs
    echo
    ok "Done. Reboot for the changes to take effect:  sudo reboot"
    echo
    echo "   After rebooting, suspend and wake the laptop, then check:"
    echo "     journalctl -b -k | grep -Ei 'nvidia|spd5118|PM: '"
    echo
    echo "   To undo:  sudo $0 --revert"
    echo "   Re-test after driver/kernel updates - you may not need this anymore."
else
    ok "Everything was already configured. No changes made."
fi
