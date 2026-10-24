#!/usr/bin/env python3
"""Deterministic HTTP fixture for updater integration tests."""

import argparse
import hashlib
import json
import signal
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional, Sequence


CHUNK_SIZE = 64 * 1024
FIXTURE_PAYLOAD = (
    b"Neuralese automatic updater integration fixture\n" * 30_000
)[: 1_250_000]
FIXTURE_SHA256 = hashlib.sha256(FIXTURE_PAYLOAD).hexdigest()
PUBLIC_PACKAGE_URL = (
    "https://github.com/hex358/neuralese-builder/releases/download/"
    "v9.9.9/Neuralese-Setup.exe"
)


def fixture_manifest(base_url: str) -> dict:
    return {
        "schema_version": 1,
        "version": "9.9.9",
        "mandatory": False,
        "published_at": "2026-07-17T00:00:00Z",
        "builder_commit_sha": "b" * 40,
        "setup_commit_sha": "c" * 40,
        "notes_markdown": {
            "ru": "**Fixture**\n\n- Streaming test",
            "en": "**Fixture**\n\n- Streaming test",
        },
        "downloads": {
            "windows": {
                "url": PUBLIC_PACKAGE_URL,
                "fixture_url": f"{base_url}/payload",
                "size_bytes": len(FIXTURE_PAYLOAD),
                "sha256": FIXTURE_SHA256,
            }
        },
    }


class _FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        path = self.path.split("?", 1)[0]
        if path == "/metadata":
            self._send_json(
                {
                    "size_bytes": len(FIXTURE_PAYLOAD),
                    "sha256": FIXTURE_SHA256,
                    "package_url": PUBLIC_PACKAGE_URL,
                }
            )
            return
        if path == "/manifest":
            self._send_json(fixture_manifest(self.server.base_url))
            return
        if path == "/payload":
            self._send_payload(FIXTURE_PAYLOAD)
            return
        if path == "/wrong-size":
            self._send_payload(FIXTURE_PAYLOAD[:-17])
            return
        if path == "/wrong-sha":
            corrupted = bytes([FIXTURE_PAYLOAD[0] ^ 0xFF]) + FIXTURE_PAYLOAD[1:]
            self._send_payload(corrupted)
            return
        if path == "/disconnect":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(FIXTURE_PAYLOAD)))
            self.end_headers()
            self.wfile.write(FIXTURE_PAYLOAD[: len(FIXTURE_PAYLOAD) // 2])
            self.wfile.flush()
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            return
        self._send_payload(b"not found", status=404, content_type="text/plain")

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send_json(self, value: dict) -> None:
        payload = (json.dumps(value, sort_keys=True) + "\n").encode("utf-8")
        self._send_payload(payload, content_type="application/json; charset=utf-8")

    def _send_payload(
        self,
        payload: bytes,
        *,
        status: int = 200,
        content_type: str = "application/octet-stream",
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        for offset in range(0, len(payload), CHUNK_SIZE):
            self.wfile.write(payload[offset : offset + CHUNK_SIZE])
            self.wfile.flush()
            time.sleep(0.001)


class UpdateFixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, host: str, port: int) -> None:
        super().__init__((host, port), _FixtureHandler)

    @property
    def base_url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}"


def _parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", type=Path)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parse_args(argv)
    server = UpdateFixtureServer(args.host, args.port)

    def stop(_signum: int, _frame: object) -> None:
        server.shutdown()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    if args.ready_file:
        args.ready_file.parent.mkdir(parents=True, exist_ok=True)
        args.ready_file.write_text(server.base_url + "\n", encoding="utf-8")
    print(server.base_url, flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
