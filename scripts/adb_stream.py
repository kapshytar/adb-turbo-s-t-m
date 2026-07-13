#!/usr/bin/env python3
"""
adb_stream.py — Stream a video file off an Android phone over adb to a local
HTTP URL, with HTTP Range support so a player (QuickTime/VLC) can SEEK without
downloading the whole file.

Nothing is installed on the phone. Byte ranges are read on demand using the
verified primitive:

    adb -s <SERIAL> exec-out "tail -c +<OFFSET+1> '<REMOTE_PATH>' | head -c <LEN>"

which returns exactly LEN raw bytes starting at 0-based byte OFFSET (binary-safe
because exec-out does not mangle the stdout stream).

Usage:
    python3 adb_stream.py "<remote_path_on_phone>" [--serial SERIAL] [--port 8970]

Standard library only.
"""

import argparse
import mimetypes
import os
import shlex
import shutil
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# Chunk size used when copying adb stdout into the HTTP response.
CHUNK = 256 * 1024  # 256 KB


def find_adb():
    """Return the adb binary path. Prefer the standard macOS SDK location, else
    fall back to 'adb' from PATH."""
    candidate = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
    if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        return candidate
    return "adb"


def list_devices(adb):
    """Return a list of online device serials from `adb devices`."""
    try:
        out = subprocess.check_output(
            [adb, "devices"], text=True, stderr=subprocess.STDOUT
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        sys.exit(f"Failed to run adb ({adb}): {e}")

    serials = []
    for line in out.splitlines()[1:]:  # skip the "List of devices attached" header
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    return serials


def pick_serial(adb):
    """Pick the first device. Prefer a USB serial (no ':') over a wireless
    host:port serial."""
    serials = list_devices(adb)
    if not serials:
        sys.exit(
            "No online adb devices found. Connect your phone, enable USB "
            "debugging, and run `adb devices` to verify."
        )
    usb = [s for s in serials if ":" not in s]
    if usb:
        return usb[0]
    return serials[0]


def get_file_size(adb, serial, remote_path):
    """Return the total size in bytes of the remote file using `stat`."""
    # shlex.quote so paths with spaces / special chars survive the phone shell.
    cmd = [adb, "-s", serial, "shell", "stat", "-c", "%s", shlex.quote(remote_path)]
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT).strip()
    except subprocess.CalledProcessError as e:
        sys.exit(
            f"Could not stat remote file '{remote_path}':\n{e.output}\n"
            "Check the path exists on the phone and is readable."
        )
    try:
        return int(out)
    except ValueError:
        sys.exit(
            f"Could not parse file size from stat output: {out!r}\n"
            "Check the remote path is correct."
        )


def spawn_range_reader(adb, serial, remote_path, start, length):
    """Spawn an adb process that emits `length` bytes starting at 0-based byte
    offset `start` from the remote file, and return the Popen object. Its stdout
    is the raw byte stream.

    Uses the verified primitive: tail -c +<start+1> | head -c <length>.
    """
    qpath = shlex.quote(remote_path)
    # tail -c +N is 1-based, so the byte at 0-based offset `start` is +start+1.
    inner = f"tail -c +{start + 1} {qpath} | head -c {length}"
    cmd = [adb, "-s", serial, "exec-out", inner]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE)


def spawn_full_reader(adb, serial, remote_path):
    """Spawn an adb process that emits the entire remote file via `cat`."""
    qpath = shlex.quote(remote_path)
    cmd = [adb, "-s", serial, "exec-out", f"cat {qpath}"]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE)


def parse_range(range_header, size):
    """Parse a 'bytes=START-END' Range header into (start, end) inclusive byte
    offsets clamped to [0, size-1]. Supports:
        bytes=START-END   -> explicit range
        bytes=START-      -> START to end of file
        bytes=-N          -> last N bytes (suffix range)
    Returns None if the header is malformed or unsatisfiable.
    """
    if not range_header or not range_header.startswith("bytes="):
        return None
    spec = range_header[len("bytes="):].strip()
    # We handle a single range only (ignore multi-range comma lists).
    if "," in spec:
        spec = spec.split(",", 1)[0].strip()
    if "-" not in spec:
        return None
    start_s, end_s = spec.split("-", 1)
    start_s, end_s = start_s.strip(), end_s.strip()

    try:
        if start_s == "":
            # Suffix range: last N bytes.
            if end_s == "":
                return None
            n = int(end_s)
            if n <= 0:
                return None
            start = max(0, size - n)
            end = size - 1
        else:
            start = int(start_s)
            end = int(end_s) if end_s != "" else size - 1
    except ValueError:
        return None

    # Clamp and validate.
    if start < 0 or start >= size:
        return None
    if end >= size:
        end = size - 1
    if end < start:
        return None
    return start, end


class StreamHandler(BaseHTTPRequestHandler):
    # These are injected as class attributes by the server setup below.
    adb = None
    serial = None
    remote_path = None
    size = None
    ctype = "video/mp4"
    url_path = "/"

    # Reduce console noise; comment out to see per-request logging.
    def log_message(self, fmt, *args):
        pass

    def _send_common_headers(self, content_length):
        self.send_header("Content-Type", self.ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(content_length))

    def _stream(self, proc):
        """Copy an adb process's stdout into the HTTP response body, then clean
        up. Quietly handle the player dropping the connection (e.g. on seek)."""
        try:
            shutil.copyfileobj(proc.stdout, self.wfile, CHUNK)
        except (BrokenPipeError, ConnectionResetError):
            # Player seeked or closed the connection; this is normal.
            pass
        finally:
            self._kill(proc)

    @staticmethod
    def _kill(proc):
        """Terminate the adb subprocess and reap it."""
        try:
            if proc.stdout:
                proc.stdout.close()
        except Exception:
            pass
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass

    def _handle(self, send_body):
        # Only serve the single file: at "/" or at "/<basename>" (the URL
        # carries the real filename so QuickTime can sniff the container from
        # the extension; the path has no filesystem meaning).
        if self.path not in ("/", self.url_path):
            self.send_error(404, "Not Found")
            return

        size = self.size
        range_header = self.headers.get("Range")
        rng = parse_range(range_header, size) if range_header else None

        if rng is not None:
            # ---- 206 Partial Content ----
            start, end = rng
            length = end - start + 1
            try:
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self._send_common_headers(length)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                return
            if not send_body:
                return
            proc = spawn_range_reader(
                self.adb, self.serial, self.remote_path, start, length
            )
            self._stream(proc)
        else:
            # If a Range header was present but unsatisfiable, signal it properly.
            if range_header is not None:
                try:
                    self.send_response(416)  # Range Not Satisfiable
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return

            # ---- 200 OK, whole file ----
            try:
                self.send_response(200)
                self._send_common_headers(size)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                return
            if not send_body:
                return
            proc = spawn_full_reader(self.adb, self.serial, self.remote_path)
            self._stream(proc)

    def do_GET(self):
        self._handle(send_body=True)

    def do_HEAD(self):
        # Players typically send HEAD first to probe for Range support.
        self._handle(send_body=False)


def main():
    parser = argparse.ArgumentParser(
        description="Stream a phone video over adb to a local HTTP URL with "
        "Range/seek support."
    )
    parser.add_argument("remote_path", help="Path to the video file on the phone.")
    parser.add_argument(
        "--serial",
        default=None,
        help="adb device serial. Defaults to the first device (prefers USB).",
    )
    parser.add_argument(
        "--port", type=int, default=8970, help="Local HTTP port (default 8970)."
    )
    parser.add_argument(
        "--adb",
        default=None,
        help="Path to adb binary (defaults to the macOS SDK location, else PATH).",
    )
    args = parser.parse_args()

    adb = args.adb or find_adb()
    serial = args.serial or pick_serial(adb)
    remote_path = args.remote_path

    size = get_file_size(adb, serial, remote_path)
    if size <= 0:
        sys.exit(f"Remote file '{remote_path}' has size {size}; nothing to stream.")

    basename = os.path.basename(remote_path.rstrip("/")) or remote_path

    # Wire the per-request handler with our connection details via class attrs.
    StreamHandler.adb = adb
    StreamHandler.serial = serial
    StreamHandler.remote_path = remote_path
    StreamHandler.size = size
    StreamHandler.ctype = mimetypes.guess_type(basename)[0] or "video/mp4"
    StreamHandler.url_path = "/" + urllib.parse.quote(basename)

    host = "127.0.0.1"
    server = ThreadingHTTPServer((host, args.port), StreamHandler)

    size_mb = size / (1024 * 1024)
    url = f"http://{host}:{args.port}{StreamHandler.url_path}"
    print(f"Streaming {basename}  ({size_mb:.1f} MB)  [device {serial}]")
    print("Open this in a player (QuickTime: File > Open Location, or VLC):")
    print(f"    {url}")
    print("Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
