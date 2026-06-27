# Phone as External Storage

> Mount your old Android phone as a macOS Finder volume — **free, open-source, no copying required**.

## The Problem

- Android killed USB Mass Storage years ago
- Google abandoned Android File Transfer (crashes on macOS 13+)
- MTP is slow, buggy, and unreliable
- MacDroid / Commander One cost money and are closed-source
- No free OSS solution that mounts phone as a real Finder volume with no-copy access on macOS

## What This Does

- **Mounts phone as a volume in Finder** via FUSE (`~/Phone` = internal storage, auto-detects SD card)
- **Photo thumbnails with EXIF** in Finder (because it's a real filesystem mount, not a sidecar)
- **One-command mount/unmount** — `./mount-phone.sh` and done
- **No-copy access** — files stay on the phone; browse, preview, open directly
- Works over **USB** (fast, recommended) or **Wi-Fi ADB** (Wireless Debugging)
- **Auto-mount on connect** via launchd agent

## Architecture

```
macFUSE <- adbfs-rootless (patched: ADBFS_ROOT env for base-path)
              ^
         ADB over USB (or Wi-Fi Wireless Debugging)
              ^
         Android phone (USB Debugging enabled)
```

**Key components:**
- **[macFUSE](https://macfuse.github.io)** — kernel FUSE driver for macOS
- **[adbfs-rootless](https://github.com/spion/adbfs-rootless)** (GPLv3, upstream) — FUSE filesystem over ADB. We apply `patch/adbfs-root-env.patch` to add `ADBFS_ROOT` env var support, so you can mount a specific subdirectory (e.g. `/storage/emulated/0`) instead of the full filesystem root
- **adbfs flags used**: `-f` (foreground, required for FUSE on macOS), `ANDROID_SERIAL` for targeting specific device

## Installation

### 1. Install macFUSE

```bash
brew install --cask macfuse
# Then: System Settings -> Privacy & Security -> allow macFUSE -> REBOOT
```

### 2. Install ADB

```bash
brew install android-platform-tools
```

### 3. Build adbfs-rootless (patched)

```bash
git clone https://github.com/spion/adbfs-rootless
cd adbfs-rootless
git apply /path/to/patch/adbfs-root-env.patch   # adds ADBFS_ROOT env var support
make
# put the adbfs binary somewhere in your PATH, e.g. ~/PhoneAsExtStorage/adbfs-rootless/adbfs
```

### 4. Enable USB Debugging on your phone

Settings -> Developer Options -> USB Debugging -> **ON**

### 5. Clone this repo and run

```bash
git clone https://github.com/kapshytar/phone-as-external-storage
cd phone-as-external-storage
./mount-phone.sh
```

## Usage

```bash
# Mount phone internal storage to ~/Phone
./mount-phone.sh

# Mount specific phone by serial
./mount-phone.sh -s SERIAL_NUMBER

# Mount full system root
./mount-phone.sh system

# Unmount all phone volumes
./unmount-phone.sh

# Restrict ADB permissions (battery/doze restore when idle)
./phone-restrict.sh restore
```

### Auto-mount on connect (launchd)

```bash
cd launchd
./install.sh
```

This registers `com.kapshytar.adbfs-phone` as a LaunchAgent that:
- Starts at login
- Waits up to 30 seconds for a USB Android device
- Mounts internal storage to `~/Phone`
- Restarts automatically if adbfs crashes (but not if phone is absent — exits 0)

To uninstall:

```bash
cd launchd
./uninstall.sh
```

### phone-restrict.sh — battery-friendly power management

When the phone is mounted for active work, `mount-phone.sh` automatically calls `phone-restrict.sh lift` which:
- Keeps screen on while plugged in (`stay_on_while_plugged_in=3`)
- Disables Wi-Fi scan throttling
- Disables Doze mode
- Raises phantom process limit

When `unmount-phone.sh` runs, it calls `phone-restrict.sh restore` to return original values.

## Real-World Speed

| Method | Speed | Notes |
|--------|-------|-------|
| USB 3 + adbfs | ~175 MB/s | Best for large transfers |
| Wi-Fi 5GHz | ~20-40 MB/s | Limited by Android power-saving latency, not radio ceiling |
| MTP over USB | ~5-15 MB/s | Built-in macOS/Android, but slow and glitchy |

Use USB for anything serious. Wi-Fi adds latency because Android's Wi-Fi chip aggressively power-saves between packets.

## Known Gotchas

- **adbfs copies to /tmp on open**: when any app opens a file via FUSE, adbfs pulls it to a local temp location. For true no-copy streaming (e.g. playing a video directly off phone) use rclone or sshfs instead
- **Wi-Fi ADB is not `adb tcpip 5555`**: modern Android uses *Wireless Debugging* (Settings -> Developer Options -> Wireless Debugging) with a dynamically assigned port. The old `adb connect ip:5555` method is deprecated on Android 11+
- **macFUSE requires kext approval + reboot**: after installing macFUSE, go to System Settings -> Privacy & Security -> allow the kernel extension, then reboot. Skipping this = `mount: failed`
- **Multiple devices**: set `ANDROID_SERIAL` env var to target a specific device when multiple are connected
- **SD card auto-detection**: `mount-phone.sh` detects external SD cards by listing `/storage/` and looking for `XXXX-XXXX` formatted directory names. Mounts to `~/Phone-SD`

## patch/adbfs-root-env.patch

The upstream `adbfs-rootless` exposes the entire Android filesystem root via FUSE. This patch adds:

1. `g_root` global string — optional device-side path prefix
2. `remap_path()` helper — prepends `g_root` to every FUSE path operation
3. `ADBFS_ROOT` env var support in `main()` — if set, initializes `g_root`

This lets you mount `/storage/emulated/0` directly as the FUSE root, so Finder shows your photos/music/documents without navigating deep into the Android filesystem tree.

Apply to upstream commit `277c088` (Implements utimens touch dates):

```bash
git clone https://github.com/spion/adbfs-rootless
cd adbfs-rootless
# verify you're at the right commit
git checkout 277c088
git apply /path/to/patch/adbfs-root-env.patch
make
```

## Credits

Standing on the shoulders of giants:

| Project | License | Link |
|---------|---------|------|
| macFUSE | BSD + FUSE | https://macfuse.github.io |
| adbfs-rootless | **GPLv3** | https://github.com/spion/adbfs-rootless |
| ADBFileExplorer | **GPLv3** | https://github.com/Aldeshov/ADBFileExplorer |
| FileDroid | — | https://github.com/andrisasuke/filedroid |
| rclone | MIT | https://rclone.org |

**Our scripts** (mount-phone.sh, unmount-phone.sh, phone-restrict.sh, launchd/) are released under the **MIT License**.

> The `adbfs` binary is **GPLv3** (upstream). This repo provides a patch only — build it yourself from the upstream source.

## License

MIT License — see [LICENSE](LICENSE).

> adbfs-rootless (upstream) remains GPLv3. Build separately and apply `patch/adbfs-root-env.patch`.
