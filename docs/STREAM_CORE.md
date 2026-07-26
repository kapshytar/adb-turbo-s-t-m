# Stream core — one implementation per runtime. Read this before touching streaming.

**The rule: there is exactly ONE range-streaming implementation per runtime. Do not write a second
one. If you are about to "just add a small HTTP server that serves a phone file over Range" —
stop, it already exists.**

| Runtime | File | Used by |
|---|---|---|
| Python | `scripts/adb_stream.py` | `phone-stream.sh` (CLI + tray), ADBFileExplorer ("Copy stream link") |
| Dart | `filedroid/lib/services/stream_server.dart` | FileDroid only |

Two implementations exist because Python cannot be imported from Flutter — that is a runtime
boundary, not a design choice. Everything on the Python side shares one file.

## Why this page exists

The same bug was found and fixed **three separate times**, in three copies of the same logic:

1. **2026-07-09** — FileDroid (Dart). QuickTime refused to play with `err -11828`: the stream URL was
   a bare `/` with no filename, so QuickTime could not tell the container from the extension.
   Fixed by putting the real filename in the URL.
2. **2026-07-27** — `adb_stream.py`. Same bug, still there, one month later. Fixed again.
3. **2026-07-27** — ADBFileExplorer had its own 215-line copy of the whole Range/adb server with
   the same bug *plus* a leak: the registry stored the URL but never the server object, and
   nothing ever called `shutdown()`, so every copied link left a listening socket behind until the
   app quit.

The third one was **not** fixed a third time. The copy was deleted and the app now calls
`adb_stream.py` (215 lines → 74). Do the same with any future copy.

## How to reuse the Python core

```python
url, server = adb_stream.start_server(remote_path, serial=device_id, adb=adb_path, port=0)
# ... hand `url` to a player / clipboard ...
server.shutdown(); server.server_close()   # the caller owns the server
```

- `port=0` lets the OS pick a free port; several servers can run at once (state lives on a
  per-file handler subclass, not on the module).
- Failures raise `adb_stream.StreamError` — the module never calls `sys.exit()`, so embedding it
  in a GUI cannot kill the host process.
- A live example is `ADBFileExplorer/src/app/services/stream_server.py`: registry + `stop_all()`
  and nothing else.

## The guard: `tests/range-probe.sh`

Shared *code* between Python and Dart is impossible; a shared **contract** is not. Run the probe
against any running stream server, in any language:

```bash
tests/range-probe.sh "http://127.0.0.1:8970/video.mp4"
```

It checks the things that actually broke in practice: `200` + `Accept-Ranges` + `Content-Length`,
media `Content-Type`, a filename with an extension in the URL, `bytes=0-1`, suffix `bytes=-500`,
a mid-file seek, a range past EOF → `416`, and a URL with a `?query` (which used to 404).

Proof it is not vacuous: run against the pre-fix `adb_stream.py` it reports **13 PASS / 1 FAIL**;
against the fixed one, **14 PASS / 0 FAIL**.

**Any new streaming implementation, or any change to an existing one, must pass this probe.**

## Streamer lifecycle (`phone-stream.sh`)

The streamer is owned by the run that started it: its PID goes into `/tmp/phone-stream.<port>.pid`
and a `trap` kills it on `EXIT/INT/TERM`. This replaced global `pkill -f "rclone serve http"`,
which killed unrelated processes. It is not cosmetic — an orphaned streamer keeps an SFTP session
open to the phone and stops its Wi-Fi radio from sleeping.

The one deliberate exception: if no player is found and the URL is opened in a browser, the
streamer must outlive the script, so `STREAM_PID` is cleared and the next run's `kill_stale`
collects it.

## Gotcha: `nc -z` on an adb-forwarded port always succeeds

`adb forward tcp:P tcp:P` makes **adb itself** listen locally, so a port probe succeeds even when
nothing is listening on the phone. A phone with no Termux at all reported "sshd alive". Probe the
banner instead — a real sshd sends `SSH-2.0-…` immediately:

```bash
nc -w 2 127.0.0.1 8022 </dev/null | head -c 4   # "SSH-" or nothing
```

`phone-transport.sh` uses this (`usb_ssh_ok`) so a USB phone without sshd cannot take the channel
away from a working Wi-Fi-SSH phone.
