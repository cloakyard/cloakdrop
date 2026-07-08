#!/usr/bin/env python3
"""Tiny test server for the extension E2E: serves a page that exercises every detection path —
HLS+DASH twin manifests, token-rotating signed mp4, a UI sound, an attachment export, a direct
<video> file, and a zip download link."""
import http.server
import functools
import sys

PAYLOAD = b"x" * 8192   # > 1 KB so nothing trips the sub-1KB noise gate

PAGE = b"""<!doctype html>
<html><head><meta charset="utf-8"><title>CloakDrop E2E</title></head>
<body>
<h1>E2E test page</h1>
<video id="main" src="/v/direct.mp4" width="640" height="360" controls></video>
<video id="preview" width="160" height="90"></video>
<a id="ziplink" href="/files/tool.zip">tool.zip</a>
<script>
  fetch('/vod/video.m3u8');
  fetch('/vod/video.mpd');
  fetch('/v/movie.mp4?token=AAA');
  setTimeout(() => fetch('/v/movie.mp4?token=BBB'), 150);
  fetch('/sounds/success.mp3');
  fetch('/api/export?id=7');
</script>
</body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            self.reply(PAGE, "text/html")
        elif path.endswith(".m3u8"):
            self.reply(PAYLOAD, "application/vnd.apple.mpegurl")
        elif path.endswith(".mpd"):
            self.reply(PAYLOAD, "application/dash+xml")
        elif path.endswith(".mp4"):
            self.reply(PAYLOAD, "video/mp4")
        elif path.endswith(".mp3"):
            self.reply(PAYLOAD, "audio/mpeg")
        elif path == "/api/export":
            self.reply(PAYLOAD, "application/octet-stream",
                       [("Content-Disposition", 'attachment; filename="dataset-2026.zip"')])
        elif path.endswith(".zip"):
            self.reply(PAYLOAD, "application/zip",
                       [("Content-Disposition", 'attachment; filename="tool.zip"')])
        else:
            self.send_error(404)
    def reply(self, body, ctype, extra=()):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra: self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
