"""Minimal HTTP server for forged PXE provisioning.

Serves static files from /srv/config/ and handles the mode API:
  GET  /mode         → current boot mode (linux, windows, reimage)
  POST /mode/<mode>  → set boot mode
  POST /api/install-complete → reset mode to linux after autoinstall
"""

import http.server
import json
import os
import socketserver
from pathlib import Path

PORT = 8070
DATA_DIR = Path("/srv/data")
CONFIG_DIR = Path("/srv/config")
MODE_FILE = DATA_DIR / "mode"
PROFILE_FILE = DATA_DIR / "profile"


class ForgedHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(CONFIG_DIR), **kwargs)

    def do_GET(self):
        if self.path == "/mode":
            mode = self._read_mode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(mode.encode())
            return

        if self.path == "/ipxe/current.ipxe":
            # Serve the mode-specific iPXE script based on current mode.
            # This is what boot.ipxe chainloads — avoids iPXE having to
            # parse text files (which it's bad at).
            mode = self._read_mode()
            script_path = CONFIG_DIR / "ipxe" / f"mode-{mode}.ipxe"
            if script_path.exists():
                content = script_path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            else:
                self.send_error(404, f"No script for mode: {mode}")
            return

        if self.path == "/profile":
            profile = PROFILE_FILE.read_text().strip() if PROFILE_FILE.exists() else "base"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(profile.encode())
            return

        if self.path == "/status":
            status = {
                "mode": self._read_mode(),
                "profile": PROFILE_FILE.read_text().strip() if PROFILE_FILE.exists() else "base",
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(status).encode())
            return

        # Serve static files from config/
        super().do_GET()

    def do_POST(self):
        if self.path.startswith("/mode/"):
            mode = self.path.split("/mode/")[1]
            if mode not in ("linux", "windows", "reimage"):
                self.send_error(400, f"Invalid mode: {mode}")
                return
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            MODE_FILE.write_text(mode)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"Mode set to: {mode}\n".encode())
            return

        if self.path.startswith("/profile/"):
            profile = self.path.split("/profile/")[1]
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            PROFILE_FILE.write_text(profile)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"Profile set to: {profile}\n".encode())
            return

        if self.path == "/api/install-complete":
            # Called by autoinstall late-command to reset mode after re-image
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            MODE_FILE.write_text("linux")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Mode reset to linux\n")
            return

        self.send_error(404)

    def _read_mode(self):
        if MODE_FILE.exists():
            return MODE_FILE.read_text().strip()
        return "linux"


if __name__ == "__main__":
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with socketserver.TCPServer(("", PORT), ForgedHandler) as httpd:
        print(f"Forged HTTP server on port {PORT}")
        print(f"  Config: {CONFIG_DIR}")
        print(f"  Data:   {DATA_DIR}")
        httpd.serve_forever()
