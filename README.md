# ADB Turbo S/T ⚡ — Stream Transfer

> Turn any old Android phone into a fast, mounted external drive for your Mac — free & open-source.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2011%2B-lightgrey?logo=apple)](https://github.com/kapshytar/phone-as-external-storage)
[![Built with rclone + macFUSE](https://img.shields.io/badge/Built%20with-rclone%20%2B%20macFUSE-orange)](https://rclone.org)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/kapshytar/phone-as-external-storage/pulls)

---

## 😤 The Pain

Android killed USB Mass Storage years ago. What replaced it?

- **Google abandoned Android File Transfer** — crashes on macOS 13+, no longer maintained
- **MTP is slow, buggy, and unreliable** — drops connections, corrupts transfers, tops out at 5–15 MB/s
- **MacDroid / Commander One** — paid, closed-source, no thank you
- **OpenMTP** — copy-only, no Finder volume, no streaming
- **Raw adbfs / sshfs** — CLI-only, no setup wizard, breaks on every Android update

There is no free, open-source tool that mounts your Android phone as a real Finder volume with true no-copy access on macOS. Until now.

---

## ✨ What You Get

- 📂 **Phone as a Finder volume** — mounted at `~/PhoneStream`, appears like any external drive
- 🎬 **True no-copy streaming** — open videos, photos, documents directly on the phone; nothing is copied to your Mac
- ⚡ **Multi-threaded reads** — rclone `--vfs-read-chunk-streams` pulls in parallel for maximum throughput
- ✍️ **Full write support** — copy files back to the phone, edit documents in place (VFS write-back cache)
- 🔌 **Auto transport selection** — USB turbo mode via `adb forward` or Wi-Fi via Wireless Debugging (mDNS), with automatic fallback
- 🖥️ **Menubar app** — switch transport, reconnect, mount/unmount — no Terminal required
- 🌙 **Silent server mode** — screen stays dark, adaptive wake-lock (CPU full only when SSH session is active, deep sleep otherwise)
- 🧙 **One-command setup wizard** — `./setup.sh` walks you through every step; safe to re-run

**Free forever. No paywall. No trial. No account.**

---

## 📊 Speed

| Method | Speed | Notes |
|--------|-------|-------|
| USB 3 + adbfs (FUSE Mode) | **~175 MB/s** | Best for large transfers, Finder integration, EXIF thumbnails |
| USB + rclone/sftp (Stream Mode) | **~110–140 MB/s** | True no-copy, best for video streaming |
| Wi-Fi 5 GHz | ~20–40 MB/s | Bottleneck is Android power-saving latency, not the radio |
| MTP over USB (built-in macOS) | 5–15 MB/s | Slow, glitchy, crashes |

> Use USB for anything serious. Wi-Fi adds latency because Android's Wi-Fi chip aggressively power-saves between packets — the radio is fast, the wakeup isn't.

---

## 🆚 Comparison

| Feature | **ADB Turbo S/T** | MacDroid | OpenMTP | Android File Transfer | adbfs / sshfs (raw) |
|---|---|---|---|---|---|
| Finder volume mount | ✅ | ✅ | ❌ | ❌ | ✅ (manual) |
| No-copy streaming | ✅ | ❌ | ❌ | ❌ | ❌ |
| Multi-threaded reads | ✅ | ❌ | ❌ | ❌ | ❌ |
| Write support | ✅ | ✅ | ❌ | ❌ | ✅ (partial) |
| GUI / menubar app | ✅ | ✅ | ✅ | ✅ | ❌ |
| Free & open-source | ✅ | ❌ (paid) | ✅ | ✅ (dead) | ✅ (CLI only) |
| Transport | ADB (USB + Wi-Fi) | MTP | MTP | MTP | ADB / SSH |

---

## 🚀 Quick Start

**Mac:**

```bash
git clone https://github.com/kapshytar/phone-as-external-storage
cd phone-as-external-storage
./setup.sh
```

The wizard installs all dependencies (macFUSE, rclone official binary, ADB), configures SSH keys and the rclone remote, and creates Desktop launchers. Safe to re-run — already-done steps are skipped.

**Phone (Termux, one-liner):**

```bash
curl -fsSL https://raw.githubusercontent.com/kapshytar/phone-as-external-storage/main/scripts/termux-init.sh | bash
```

This installs `openssh`, sets up `sshd`, grants storage access, and starts the server. After that, launch **PhoneStream** from your Mac menubar.

---

## 🧱 How It Works

Two complementary mount stacks — pick the one that fits your use case:

### Stream Mode (rclone + Termux sshd) — recommended for video / large files

```
Mac Finder (~/PhoneStream)
    └── rclone mount  [multi-stream sftp, VFS cache]
        └── adb forward tcp:8022  [USB or Wi-Fi tunnel]
            └── Termux sshd  [port 8022, ed25519 key]
                └── Android storage (/storage/emulated/0)
```

True no-copy streaming. Files never leave the phone. Multi-threaded reads via `--vfs-read-chunk-streams`.

### FUSE Mode (adbfs + macFUSE) — recommended for Finder integration / EXIF thumbnails

```
Mac Finder (~/Phone, ~/Phone-SD)
    └── macFUSE kernel driver
        └── adbfs-rootless (patched, ADBFS_ROOT env)
            └── ADB over USB / Wi-Fi
                └── Android phone
```

Full FUSE volume: photo thumbnails, Spotlight indexing, SD card auto-detection. Note: adbfs copies to `/tmp` on file open — for true streaming use Stream Mode.

---

## ✅ Compatibility / Requirements

### Phone (Android)

| Feature | Requirement | Notes |
|---------|-------------|-------|
| Termux (sshd, Stream Mode) | Android **7.0+** | Termux minimum requirement |
| USB transport (adb forward) | Any Android with USB Debugging | Works on all brands |
| Wi-Fi / Wireless Debugging (mDNS auto-discovery) | **Android 11+** recommended | On older Android: USB only, or legacy `adb tcpip` (not reliable) |
| Samsung devices | Wi-Fi: Wireless Debugging only | Knox blocks legacy `adb tcpip 5555` → use Wireless Debugging or USB |
| Termux:Boot (auto-start sshd) | Optional | Install from F-Droid |
| Termux:Widget | Optional | Install from F-Droid |

**Install Termux from [F-Droid](https://f-droid.org), not the Play Store** — the Play Store build is outdated.

Tested on: **Samsung Galaxy S10+ (Android 12)**. Any Android brand works; Samsung-specific caveats are noted above.

### Mac (macOS)

| Component | Requirement | Notes |
|-----------|-------------|-------|
| macOS | **11 Big Sur+** | |
| rclone binary | Intel `osx-amd64` | Apple Silicon: swap to `osx-arm64` binary in `setup.sh` |
| macFUSE | Requires kext approval + **reboot** | System Settings → Privacy & Security → allow → reboot |
| macFUSE on Apple Silicon | Needs lowered security in Recovery for KEXT | Alternative: [FUSE-T](https://www.fuse-t.org) (no kext required) |

---

## 🛡️ Hardening & Longevity

For always-on server use — keeping the phone running reliably as headless storage.

### rclone / VFS cache

- **`--vfs-cache-mode writes`** (default) — enables full write-back caching; required for writes to work correctly. `minimal` mode does **not** support writes.
- **`--vfs-cache-mode full`** — only needed if apps require random-seek access or in-place editing (e.g. SQLite databases). Has higher local disk usage.
- **`--vfs-read-chunk-streams 8`** (default) — sweet spot is 4–8 parallel streams. Higher values can saturate phone CPU or flash I/O without improving speed.

### Security

- **SSH over adb forward (recommended):** keep `sshd` bound to `127.0.0.1` — accessible only through `adb forward tcp:8022`, invisible to the network. No open port, no exposure.
- **SSH over direct LAN/VPN access:** use a dedicated SSH key for mount only, set `PasswordAuthentication no`, restrict the user, and add `from=<LAN/VPN subnet>` in `~/.ssh/authorized_keys` on the phone.
- **Wireless Debugging:** enable only on trusted (home/VPN) networks. Disable when not in use.

### Android power & process management

- In Android Settings: set **Battery → Termux → Unrestricted** and allow autostart for Termux and Termux:Boot. Without this, Android may kill the sshd process.
- **Phantom process killer** (Android 12+): disable via `adb shell device_config put activity_manager max_phantom_processes 2147483647` — `phone-restrict.sh lift` does this automatically.
- After a phone reboot: the screen must be unlocked once (credential-encrypted storage is locked at boot). Wireless Debugging may also reset → keep a USB cable as a recovery path.

### Physical / hardware

- For permanent charging: enable **battery charge limit at 80–85%** (Samsung: *Settings → Battery → Protect battery*). Continuous 100% charging degrades the battery and risks swelling.
- Use a quality cable and ensure adequate ventilation around the phone.

### Write durability

- rclone write-back cache flushes after ~5 seconds. **Do not unplug the cable or put the Mac to sleep immediately after copying large files** — data may still be uploading to the phone.
- A hung mount is recovered automatically: `phone-stream-up.sh` performs force-unmount + remount if needed.

### Known limitation: concurrent edits

SFTP has no push-notification protocol. If a file is modified from the phone while the FUSE mount is active, the Mac may not see the change immediately. Remount to force a refresh.

---

## 🗺️ Roadmap

See [ROADMAP.md](ROADMAP.md) for the full list. Coming next:

- **scrcpy screen mirror** — control your phone screen from the Mac while it's mounted
- Auto-reconnect on sleep/wake
- Apple Silicon native build (arm64 rclone + FUSE-T default)
- Menubar app: volume usage graph, transfer progress

---

## 🙏 Credits

Standing on the shoulders of giants:

| Project | Author | License | Link |
|---------|--------|---------|------|
| macFUSE | Benjamin Fleischer et al. | BSD + FUSE | [macfuse.github.io](https://macfuse.github.io) |
| rclone | Nick Craig-Wood et al. | MIT | [rclone.org](https://rclone.org) |
| Termux | Termux contributors | GPL / MIT | [termux.dev](https://termux.dev) |
| adbfs-rootless | spion | **GPLv3** | [github.com/spion/adbfs-rootless](https://github.com/spion/adbfs-rootless) |
| ADBFileExplorer | Aldeshov | **GPLv3** | [github.com/Aldeshov/ADBFileExplorer](https://github.com/Aldeshov/ADBFileExplorer) |
| FileDroid | andrisasuke | — | [github.com/andrisasuke/filedroid](https://github.com/andrisasuke/filedroid) |
| scrcpy *(optional)* | Genymobile | Apache-2.0 | [github.com/Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) |

> Screen mirroring is powered by **scrcpy** — we don't bundle or redistribute it; the app just launches your locally-installed `scrcpy` (offers to `brew install` it if missing).

> The `adbfs` binary is **GPLv3** (upstream). This repo provides a patch only — build it yourself from upstream source. Do not redistribute the binary.

---

## 📄 License

Our scripts and menubar app (`setup.sh`, `scripts/`, app source) are released under the **MIT License** — see [LICENSE](LICENSE).

adbfs-rootless (upstream) remains GPLv3. Build separately and apply `patch/adbfs-root-env.patch`.
