# PhoneStream — Android Phone as External Storage on macOS

> App-centric access to your Android phone from the Mac menubar. Browse files in ADBFileExplorer, stream video directly to IINA, transfer via rclone/adb — no MTP, no copy required for playback.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2011%2B-lightgrey?logo=apple)](https://github.com/kapshytar/adb-turbo-s-t-m)
[![Built with rclone + macFUSE](https://img.shields.io/badge/Built%20with-rclone%20%2B%20macFUSE-orange)](https://rclone.org)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/kapshytar/adb-turbo-s-t-m/pulls)

---

## ⚠️ Tested configuration / no support

This was built and tested on **exactly one setup**:

- **Phone:** Samsung Galaxy S10+ (SM-G975F), Android 12 / One UI (non-rooted)
- **Mac:** Intel Mac with T2, macOS

Much of the device-side logic works around **Samsung/One UI specifics** (Knox, Wireless Debugging behavior, `protect_battery` 85% cap, phantom-process killer). On Pixel / Xiaomi / other Android versions the device UID, Wi-Fi interface name, settings keys and quirks differ — it likely **won't work out of the box**.

This is a personal project shared as-is. **No support, no guarantees, no promise it works on your hardware.** If it's useful to you: fork it, adapt the hardcoded bits (phone UID, paths, IP via `~/.phone_wifi_ip`), and run with it. PRs welcome but not actively maintained for other devices.

**Multi-device note:** the app supports multiple phones connected simultaneously. Device selection is stored by **model name** in `~/.phone_active_model` (not by serial — Wi-Fi serials are ephemeral). SSH operations (upload, download, streaming, Wi-Fi mount) route to the cached IP independently of the device selector; the selector governs adb-level operations (USB mount, scrcpy, cache clear).

---

## Why this exists

Android dropped USB Mass Storage years ago. Existing options each have tradeoffs:

- **Android File Transfer** — unmaintained, crashes on macOS 13+
- **MTP** — slow (5–15 MB/s), connection drops, unreliable on macOS
- **MacDroid / Commander One** — paid, closed-source
- **OpenMTP** — copy workflow only, no streaming
- **Phone-side FTP/WebDAV apps** (X-plore, Material Files, MiXplorer, ES) — see below: the built-in server keeps dying
- **Raw adbfs / sshfs** — CLI only, fragile across Android updates

**What nothing else does:** seamless automatic USB↔Wi-Fi failover combined with no-copy media streaming to IINA. This project wires those pieces together with a menubar app so you never touch the terminal for day-to-day use.

### Why phone-side FTP/WebDAV apps are unreliable (and this isn't)

People try the FTP/WebDAV server built into file-manager apps (X-plore, Material Files, MiXplorer, ES) and find it works for five minutes, then drops. The problem isn't FTP — it's that **Android aggressively kills the app's background server**:

- Background the app or turn off the screen → Doze, battery optimization and the phantom-process killer **terminate the foreground service** → the server dies.
- Wi-Fi power-save puts the radio to sleep → connections stall and drop.
- Plain FTP itself is fragile (no encryption, no resume, passive-mode/NAT issues), and Finder handles FTP/WebDAV poorly.
- No wake-lock → the phone sleeps and takes the server with it.

**This project hardens exactly that weak link:**

- **Termux + `termux-wake-lock` + battery set to Unrestricted + Termux:Boot** — sshd stays alive in the background and survives a reboot.
- A **self-healing watchdog** on the phone restarts sshd if it ever dies.
- **SSH instead of FTP** — encrypted, key-auth, multi-stream, resumable.
- On the Mac: keepalive + watchdog + automatic channel failover.

That's the actual reason to use this over a tap-to-start FTP app: the server doesn't quietly die on you.

---

## How it works: 4 connection channels

The **PhoneStream** tray app manages four channels and picks the best available one automatically. When multiple phones are connected, channels are shown for the **selected device** only and update live when you switch devices.

| Channel | When used | Notes |
|---------|-----------|-------|
| **USB — adb** | USB cable connected | Highest speed and reliability; preferred for transfers and streaming |
| **Wi-Fi — SSH :8022** | USB unavailable, Termux sshd reachable | Used for file streaming via rclone; multithreaded range requests. Requires Termux sshd on the phone. |
| **Wireless Debugging — mDNS** | Android 11+, WD enabled | Auto-discovery via `adb mdns services`; no manual IP needed. Admin commands only (scrcpy, pm, logcat). |
| **adb :5555 (legacy)** | Fallback if `service.adb.tcp.port=5555` is set | Not reboot-proof; not available on Samsung by default |

The app keeps a USB keepalive running in the background (prevents macOS from suspending the USB port at 85% charge) and caches the phone's Wi-Fi IP for instant fallback.

**Important:** SSH-based operations (upload, download, streaming, Wi-Fi mount) are only possible if the selected phone has Termux sshd running. On a second phone without Termux, only USB-adb operations are available.

---

## Multi-device support

When more than one Android phone is connected, a **Device:** selector appears at the top of the tray menu. Each entry shows the model name and connection kind (e.g. `SM-G975F — USB+Wi-Fi`). Clicking a row switches the active device **without closing the menu**; the active device is marked with ✓ and shown in bold white.

What the device selector affects:

- Channel indicators (🟢/⚪️) in the Connection Center reflect only the selected device's channels and update live on switch.
- Mount section headers show the selected device's model.
- USB mount, scrcpy, and cache-clear operations target the selected device.
- Upload and download operations auto-pick the best channel (USB → Wi-Fi SSH) for the selected device.

The selection persists across tray restarts via `~/.phone_active_model` (stores the model string, not the serial — Wi-Fi adb serials are ephemeral and change on each Wireless Debugging session).

---

## What you get

- **File browser** — ADBFileExplorer shows directory listings instantly over any channel; no Finder volume needed to browse
- **No-copy streaming** — open videos directly in IINA via HTTP range requests; the file never lands on your Mac
- **Bulk upload** — rclone/SFTP with 8 parallel streams; ~24 MB/s over Wi-Fi, faster over USB; file picker in the tray
- **Direct-to-phone download** — paste a URL; rclone fetches it onto the phone bypassing the Mac disk
- **FUSE mount (optional)** — USB mount (`~/Phone-USB`) for apps that need a file path; Wi-Fi mount available as a last resort (marked ⚠)
- **Menubar app** — connect, stream, browse, mount/unmount without opening Terminal
- **Auto-transport** — USB→Wi-Fi failover is automatic; the active channel is shown in the Connection Center
- **Screen mirror** — `scrcpy` launched from the tray (uses your locally-installed scrcpy), targets the selected device
- **Setup wizard** — `./setup.sh` installs all dependencies and configures SSH keys; safe to re-run
- **Anti-hang watchdog** — proactive stat-timeout + reachability check; force-unmounts a stalling mount before the OS enters D-state

---

## Speed — by mode

Tested: Samsung Galaxy S10+ (Android 12), Intel Mac (T2 chip), USB 3 cable. Results are representative, not a formal benchmark.

| Mode | Typical speed | Notes |
|------|--------------|-------|
| `adb pull` over USB | ~175 MB/s | Bulk file transfer, most reliable |
| rclone/SFTP via `adb forward` (USB) | ~110–140 MB/s | Structured copy; multithread |
| HTTP range stream via `adb exec-out` (USB) | ~27 MB/s | No-copy playback in IINA; USB path |
| rclone upload --transfers 8 (Wi-Fi SSH) | ~24 MB/s | Multi-stream upload from tray button |
| Wi-Fi SSH multistream (5 GHz) | ~25 MB/s | Ceiling is Wi-Fi radio + phone power-saving latency, not the channel |
| Wi-Fi HTTP range stream | ~7 MB/s per chunk | Fallback when USB unavailable |
| MTP over USB (macOS built-in) | 5–15 MB/s | Baseline for comparison |

> Wi-Fi speed is capped by Android's aggressive power-saving: the radio is fast (802.11ac 5 GHz capable of 30–75 MB/s), but ping latency spikes to 35–88 ms between packets. Multi-stream rclone helps on explicit transfers; it does not fix mount latency.

---

## Transfers

### Upload to phone — fast, multi-stream

**Tray menu → ⬆︎ Upload to phone (fast, multi-stream)**

Opens a file/folder picker. Selected items are sent to `/sdcard/Download` via `rclone copy` over SFTP with `--transfers 8 --multi-thread-streams 4`. Channel is auto-selected by `phone-transport.sh`: USB first (via `adb forward`), then Wi-Fi SSH. Typical throughput ~24 MB/s over Wi-Fi, faster over USB.

### Download from internet to phone

**Tray menu → ⬇︎ Download from internet to phone**

Paste an `http://` or `https://` URL. `rclone copyurl` delivers the file directly to `/sdcard/Download` on the phone via SFTP — the Mac disk is never involved. Only `http`/`https` are accepted (file:// and other schemes are rejected). Channel is auto-selected the same way as upload.

### Which transfer method for what

The tray item **ⓘ Transfers — which for what** (and **ⓘ Which channel for what** for channels) shows an in-app summary. Quick reference:

| Goal | Method |
|------|--------|
| Bulk / many / large files to phone | ⬆︎ Upload button (multi-stream rclone) |
| Grab a download link onto phone | ⬇︎ Download from internet |
| Browse and watch video | ADB Explorer / FileDroid → streams in IINA |
| Another Mac app needs a file path | Mount USB folder (Finder) |
| Bulk pull from phone to Mac | `adb pull` (~175 MB/s USB) |

---

## Browsing vs. mounting

**For browsing and streaming:** use ADBFileExplorer + IINA. Discrete adb calls with timeouts are safe; a persistent FUSE mount over Wi-Fi is not — if the connection flaps, the mount wedges the kernel into uninterruptible I/O (D-state), freezing Finder and Activity Monitor until the adb connection is physically severed.

**For mounting (giving a file path to an application):** USB-only FUSE mount (`~/Phone-USB`) is stable. Wi-Fi mount is a last resort — use it only when USB is unavailable and expect the watchdog to force-unmount if the connection drops. The Wi-Fi mount entry is marked ⚠ in the menu to make this clear.

**Mount all:** mounts only the USB volume. The Wi-Fi mount is excluded deliberately — it requires an explicit "Mount Wi-Fi (last resort)" step with an additional confirmation dialog.

---

## Quick start

**Mac:**

```bash
git clone https://github.com/kapshytar/adb-turbo-s-t-m
cd adb-turbo-s-t-m
./setup.sh
```

The wizard installs dependencies (macFUSE, official rclone binary, ADB platform tools), configures SSH keys and the rclone remote, and creates launchers. Safe to re-run — completed steps are skipped. Detects Intel vs. Apple Silicon automatically.

**Phone (Termux, one-liner):**

```bash
curl -fsSL https://raw.githubusercontent.com/kapshytar/adb-turbo-s-t-m/master/scripts/termux-init.sh | bash
```

> Inspect the script before running: `curl -fsSL <url> -o termux-init.sh`, review it, then `bash termux-init.sh`.

Installs openssh, configures sshd on port 8022, grants storage access, starts the server. After that, launch **PhoneStream** from the Mac menubar.

---

## Requirements

### Mac

| Component | Notes |
|-----------|-------|
| macOS 11 Big Sur+ | |
| rclone — **official binary from downloads.rclone.org** | The Homebrew rclone does **not** support `mount` on macOS ("not supported when installed via Homebrew"). `setup.sh` downloads the correct binary. Apple Silicon path: `/opt/homebrew` is searched but the official binary is installed separately. |
| macFUSE | Requires kext approval + reboot: System Settings → Privacy & Security → allow → reboot. **Apple Silicon:** Reduced Security must be enabled in Recovery before kext approval works. Alternative: [FUSE-T](https://www.fuse-t.org) (no kext required). |
| IINA | For no-copy video streaming. `setup.sh` will prompt to install if missing. |
| adb (platform-tools ≥ 31) | Required for Wireless Debugging mDNS auto-discovery. |

### Phone (Android)

| Feature | Requirement | Notes |
|---------|-------------|-------|
| Termux | Android 7.0+ | Install from [F-Droid](https://f-droid.org), **not the Play Store** — the Play Store build is outdated |
| Termux:Boot | Optional | Auto-starts sshd after phone reboot; install from F-Droid |
| openssh in Termux | Any | `pkg install -y openssh`; sshd on port 8022 |
| SSH key (no passphrase) | Required | `setup.sh` generates and installs `~/.ssh/id_ed25519_phone` |
| Wireless Debugging + mDNS | Android 11+ | Required for Wi-Fi auto-discovery without a USB cable |
| Samsung / OneUI | — | `protect_battery` (charge limit at ~85%) causes USB port suspension at that threshold — `setup.sh` addresses this. Knox blocks `adb tcpip 5555`; use Wireless Debugging instead. `adb mdns services` may appear empty on macOS even when WD is active — restart the adb server (`adb kill-server && adb start-server`) before concluding WD is off. |

---

## Architecture

### Streaming (recommended for video / large files)

```
IINA  ←  HTTP range request
              └── phone-stream.sh
                    ├── USB path: adb exec-out → local HTTP server → IINA
                    └── Wi-Fi path: rclone serve http over SSH → IINA
```

Files never leave the phone. IINA seeks via HTTP 206 range requests.

### File browser (recommended for navigation)

```
ADBFileExplorer (Python/Qt)
    └── adb shell ls  [discrete call, 25 s timeout]
        └── USB serial  or  Wi-Fi adb endpoint
```

Each directory listing is a single `adb ls` call. No persistent connection; timeouts prevent D-state freezes.

### Transfers (upload / internet download)

```
phone-upload.sh / phone-download.sh
    └── phone-transport.sh  (auto-selects channel)
          ├── USB → adb forward tcp:8022 → rclone copy/copyurl over SFTP (localhost)
          └── Wi-Fi SSH → rclone copy/copyurl over SFTP (phone IP)
```

### Device selection (multi-device)

```
phone-devices.sh  →  parses `adb devices -l` (model: field, no getprop round-trip)
                       →  compares against active_model() from ~/.phone_active_model
                       →  emits SERIAL<TAB>MODEL<TAB>KIND<TAB>ACTIVE

PhoneStream.swift  →  runs phone-devices.sh every 15 s in background
                    →  Device: rows in tray (click = switch, menu stays open)
                    →  channel indicators and mount headers update live on switch
```

### FUSE mount (optional, USB recommended)

```
~/Phone-USB  (Finder volume)
    └── macFUSE
        └── adbfs-rootless (patched, ADBFS_ROOT env)
            └── adb over USB
```

Stable over USB. Wi-Fi FUSE mount exists as a last resort — connection flap wedges the kernel; the watchdog force-unmounts before D-state.

### Watchdog (anti-hang)

```
phone-watchdog.sh  (runs as long as the tray is alive)
    └── every 3 s per mounted volume:
          ├── stat with 3 s timeout → hang detected → force-unmount immediately
          └── reachability check (USB device present / Wi-Fi ping) → 2 misses → force-unmount
```

---

## Hardening for always-on use

### Battery longevity

- **Samsung:** enable *Settings → Battery → Protect battery* (limits charge to ~80–85%). Note: this causes USB port suspension at the threshold because the phone stops drawing current — macOS then suspends the port. The keepalive in PhoneStream mitigates this with `caffeinate`; for a permanent server role, prefer wall charger + Wi-Fi over a Mac USB port.
- Use a quality cable; ensure ventilation around the phone.

### Android power management

- Set **Battery → Termux → Unrestricted** and allow autostart for Termux and Termux:Boot.
- **Phantom process killer** (Android 12+): `adb shell device_config put activity_manager max_phantom_processes 2147483647` — `phone-restrict.sh lift` handles this.
- After a phone reboot: unlock the screen once (credential-encrypted storage is locked at boot). Wireless Debugging may have reset — keep a USB cable as a recovery path.

### rclone / VFS cache

- **`--vfs-cache-mode writes`** — required for write support. `minimal` mode does **not** support writes (verified).
- **`--vfs-cache-mode full`** — only needed for random-seek access (e.g. SQLite). Higher local disk usage.
- **`--vfs-read-chunk-streams 8`** — sweet spot is 4–8 parallel streams. Higher values can saturate phone CPU or flash I/O without improving throughput.

### Security

- **SSH over adb forward (default):** sshd bound to `127.0.0.1` — accessible only through `adb forward tcp:8022`, not visible on the network.
- **Direct LAN/VPN access:** use a dedicated mount-only SSH key, set `PasswordAuthentication no`, and restrict with `from=<subnet>` in `authorized_keys`.
- **Wireless Debugging:** enable only on trusted networks. Disable when not in use.

### Write durability

rclone write-back cache flushes after ~5 seconds. Do not unplug the cable or sleep the Mac immediately after copying large files.

---

## Tradeoffs vs. alternatives

| | **PhoneStream** | MacDroid | OpenMTP | Android File Transfer | adbfs / sshfs (raw) |
|---|---|---|---|---|---|
| File browser | yes (ADBFileExplorer) | yes (Finder) | yes | yes | no |
| No-copy streaming to IINA | yes | no | no | no | no |
| Automatic USB↔Wi-Fi failover | yes | no | no | no | no |
| Multi-device support | yes | no | no | no | no |
| FUSE mount | yes (USB; Wi-Fi as last resort) | yes | no | no | yes (manual) |
| Write support | yes | yes | no | no | partial |
| Menubar app | yes | yes | yes | yes | no |
| Fast upload (multi-stream) | yes (~24 MB/s Wi-Fi) | no | no | no | no |
| Direct internet→phone download | yes | no | no | no | no |
| Free & open-source | yes* | no (paid) | yes | yes (unmaintained) | yes (CLI only) |
| Transport | ADB + SSH | MTP | MTP | MTP | ADB / SSH |

*Components (adbfs, ADBFileExplorer, FileDroid) are GPLv3 — build from source; no pre-built binaries for those components.

---

## Roadmap

See [ROADMAP.md](ROADMAP.md).

---

## Credits

| Project | Author | License | Link |
|---------|--------|---------|------|
| macFUSE | Benjamin Fleischer et al. | BSD + FUSE | [macfuse.github.io](https://macfuse.github.io) |
| rclone | Nick Craig-Wood et al. | MIT | [rclone.org](https://rclone.org) |
| Termux | Termux contributors | GPL / MIT | [termux.dev](https://termux.dev) |
| IINA | IINA contributors | GPL-3.0 | [iina.io](https://iina.io) |
| adbfs-rootless | spion | **GPLv3** | [github.com/spion/adbfs-rootless](https://github.com/spion/adbfs-rootless) |
| ADBFileExplorer | Aldeshov | **GPLv3** | [github.com/Aldeshov/ADBFileExplorer](https://github.com/Aldeshov/ADBFileExplorer) |
| FileDroid | andrisasuke | **GPLv3** | [github.com/andrisasuke/filedroid](https://github.com/andrisasuke/filedroid) |
| scrcpy | Genymobile | Apache-2.0 | [github.com/Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) |

> Screen mirroring is powered by **scrcpy** — not bundled; the app launches your locally-installed `scrcpy` (offers `brew install scrcpy` if missing).

> **GPLv3 components** (adbfs-rootless, ADBFileExplorer, FileDroid): this repo provides patches and wrappers only. Build from upstream source; do not redistribute the binaries.

---

## License

Scripts and the PhoneStream menubar app (`setup.sh`, `scripts/`, app source) are released under the **MIT License** — see [LICENSE](LICENSE).

adbfs-rootless (upstream) remains GPLv3. Build separately and apply `patch/adbfs-root-env.patch`.
ADBFileExplorer and FileDroid remain GPLv3. Our changes are available in the respective forks.
