# nvwake
A small, idempotent Bash script that works around two resume-from-suspend failures on Linux laptops with an NVIDIA GPU and DDR5 memory.

**This is a workaround, not a fix.** The underlying bugs are in the NVIDIA proprietary driver and in the mainline kernel's DDR5 sensor driver — nothing here patches either of them. It changes configuration to avoid the code paths that break. Both may become unnecessary after a driver or kernel update, so re-test before assuming you still need it.

## Symptoms

After closing the lid or suspending, the laptop wakes to a black screen, a frozen desktop, or drops to a console showing kernel messages like:

```
[drm:__nv_drm_semsurf_wait_fence_work_cb [nvidia_drm]] *ERROR* [nvidia-drm]
  [GPU ID 0x00000100] Failed to register auto-value-update on pre-wait value
  for sync FD semaphore surface
spd5118 14-0050: Failed to write b = 0: -6
spd5118 14-0050: PM: dpm_run_callback(): spd5118_resume [spd5118] returns -6
spd5118 14-0050: PM: failed to resume async: error -6
```

## Root causes

**1. NVIDIA — video memory not preserved across suspend.**
By default the proprietary driver only saves the console framebuffer when the system suspends. Everything else in VRAM is discarded, so on resume the driver cannot restore its sync objects and semaphore surfaces, and the `nvidia-drm` error above is thrown. This is the failure that actually breaks the desktop.

**2. spd5118 — DDR5 SPD hub temperature sensor.**
`spd5118` is the hwmon driver for the temperature sensor built into DDR5 DIMMs. On many laptops the SMBus it lives on isn't ready when the driver's resume callback runs, so the write fails with `-6` (`ENXIO`, no such device or address). This is cosmetic — it only affects RAM temperature reporting — but it adds noise to the log and can stall the resume chain.

## Is this distro-specific?

No. The cause is the driver and the kernel, not the distribution:

- `NVreg_PreserveVideoMemoryAllocations` is a parameter of NVIDIA's kernel module — same name and behaviour everywhere.
- `nvidia-suspend/resume/hibernate.service` ship with NVIDIA's own driver package upstream; most distros package them, though not all enable them by default.
- `spd5118` is a mainline kernel driver, so the bug follows the kernel version.
- `/etc/modprobe.d/` works identically on Debian, Fedora, Arch, openSUSE and others.

The only distro-dependent step is the initramfs rebuild, and the script detects which tool to use.

## What the script changes

| # | Change | File / command |
|---|--------|----------------|
| 1 | Tells the NVIDIA driver to preserve **all** VRAM across suspend, staging it in `/var/tmp` | writes `/etc/modprobe.d/nvidia-power-management.conf` with `options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp` |
| 2 | Enables the driver's power-management units so the save/restore actually runs | `systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service` |
| 3 | Stops the DDR5 sensor module from loading | writes `/etc/modprobe.d/blacklist-spd5118.conf` containing `blacklist spd5118` |
| 4 | Applies the modprobe changes to the boot image | `update-initramfs -u`, `dracut --force`, or `mkinitcpio -P`, whichever is present |

Safety behaviour built into the script:

- **Idempotent** — detects settings that are already correct and makes no change.
- **Backs up** any pre-existing `nvidia-power-management.conf` to `*.bak.<timestamp>`.
- **Skips gracefully** if no NVIDIA GPU is present, if systemd isn't in use, or if a unit isn't shipped by the installed driver package.
- **Free-space check** — VRAM is written to disk on suspend, so it warns if `/var/tmp` has less room than the GPU has memory.
- `--dry-run` prints every action without touching the system; `--revert` removes both config files and rebuilds the initramfs.

## Tested / expected to work on

| Family | Initramfs tool | Status |
|--------|----------------|--------|
| Pop!_OS, Ubuntu, Debian, Mint | `update-initramfs` | tested |
| Fedora, RHEL, openSUSE | `dracut` | expected to work — reports welcome |
| Arch, Manjaro, EndeavourOS | `mkinitcpio` | expected to work — reports welcome |

## Usage

```bash
chmod +x nvidia-suspend-workaround.sh
sudo ./nvidia-suspend-workaround.sh --dry-run   # preview
sudo ./nvidia-suspend-workaround.sh             # apply
sudo reboot
```

## Verifying it worked

Suspend and wake the machine, then:

```bash
journalctl -b -k | grep -Ei 'nvidia|spd5118|PM: '
```

The `spd5118` lines should be gone entirely, and there should be no `*ERROR*` from `nvidia-drm` around the resume timestamp.

## Reverting

```bash
sudo ./nvidia-suspend-workaround.sh --revert
sudo reboot
```

## Caveats and trade-offs

- Preserving full VRAM makes suspend and resume slightly slower, since several GB may be written to and read from disk.
- If `/var/tmp` is small or on a separate partition, point `NVreg_TemporaryFilePath` somewhere with more space.
- Blacklisting `spd5118` removes DDR5 DIMM temperature readings from `sensors` output. If you rely on those, leave the module loaded — the errors are noisy but harmless on their own.
- Try `sudo apt update && sudo apt full-upgrade` (or your distro's equivalent) first. Several suspend regressions were addressed in newer driver packages, and the better outcome is not needing a workaround at all.
- Because this is a workaround, the right long-term move is to report the failure upstream — to NVIDIA for the `nvidia-drm` error, and to the kernel hwmon maintainers or your distro's tracker for `spd5118` — so it eventually gets fixed properly.

## License
MIT — see [LICENSE](LICENSE).
