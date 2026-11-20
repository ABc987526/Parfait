"""Security, validation, redaction, and Pixiv loopback tests for Dev Workbench."""

from __future__ import annotations

import base64
import http.client
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import unittest
import urllib.parse
import zipfile
from io import BytesIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.server import (
    ParfaitWorkbenchServer,
    WorkbenchState,
    write_state_files,
)


class DevWorkbenchServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.artifacts_dir = self.root / "artifacts"
        self.artifacts_dir.mkdir()
        (self.artifacts_dir / "sample.png").write_bytes(b"\x89PNG\r\n\x1a\n")

        self.token = "test_workbench_token_0123456789abcdef0123456789"
        self.state = WorkbenchState(token=self.token, artifacts_dir=self.artifacts_dir)
        self.server = ParfaitWorkbenchServer(0, self.state)
        self.port = self.server.bound_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.temp_dir.cleanup()

    def _raw_request(
        self,
        method: str,
        path: str,
        *,
        host: str | None = None,
        headers: dict[str, str] | None = None,
        body: bytes | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
            conn.putheader("Host", host if host is not None else f"127.0.0.1:{self.port}")
            for k, v in (headers or {}).items():
                conn.putheader(k, v)
            if body is not None:
                conn.putheader("Content-Length", str(len(body)))
            conn.endheaders(body)
            resp = conn.getresponse()
            raw = resp.read()
            resp_headers = {k.lower(): v for k, v in resp.getheaders()}
            return resp.status, resp_headers, raw
        finally:
            conn.close()

    def _authed_headers(self, **extra: str) -> dict[str, str]:
        hdrs = {
            "Content-Type": "application/json",
            "X-Parfait-Workbench-Token": self.token,
        }
        hdrs.update(extra)
        return hdrs

    def test_binds_loopback_only_and_state_file_permissions(self) -> None:
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        state_file = self.root / "session.json"
        write_state_files(self.port, self.token, state_file)
        mode = stat.S_IMODE(state_file.stat().st_mode)
        self.assertEqual(mode, 0o600)
        token_mode = stat.S_IMODE((self.root / ".workbench-token").stat().st_mode)
        self.assertEqual(token_mode, 0o600)

    def test_rejects_disallowed_host_and_never_emits_wildcard_acao(self) -> None:
        for bad_host in ("evil.example:18490", "127.0.0.1:9999", ""):
            status, hdrs, _ = self._raw_request("GET", "/api/state", host=bad_host)
            self.assertEqual(status, 403, f"expected 403 for Host={bad_host!r}")
            self.assertNotEqual(hdrs.get("access-control-allow-origin"), "*")

        status, hdrs, _ = self._raw_request("GET", "/api/state")
        self.assertEqual(status, 200)
        self.assertNotIn("access-control-allow-origin", hdrs)

    def test_blocks_cross_site_writes_missing_token_and_bad_ctype(self) -> None:
        hb = json.dumps({"clientId": "win-1", "platform": "windows", "snapshot": {}, "logs": []}).encode()
        st, _, _ = self._raw_request("POST", "/api/client/heartbeat", headers=self._authed_headers(), body=hb)
        self.assertEqual(st, 200)

        cmd_body = json.dumps({"clientId": "win-1", "type": "navigate", "args": {"path": "/ranking"}}).encode()

        # Cross-origin rejected
        st, _, _ = self._raw_request(
            "POST",
            "/api/commands",
            headers=self._authed_headers(Origin="https://evil.example"),
            body=cmd_body,
        )
        self.assertEqual(st, 403)

        # Sec-Fetch-Site: cross-site rejected
        st, _, _ = self._raw_request(
            "POST",
            "/api/commands",
            headers=self._authed_headers(**{"Sec-Fetch-Site": "cross-site"}),
            body=cmd_body,
        )
        self.assertEqual(st, 403)

        # Missing or wrong token rejected with 401
        st, _, _ = self._raw_request(
            "POST",
            "/api/commands",
            headers={"Content-Type": "application/json"},
            body=cmd_body,
        )
        self.assertEqual(st, 401)
        st, _, _ = self._raw_request(
            "POST",
            "/api/commands",
            headers={"Content-Type": "application/json", "X-Parfait-Workbench-Token": "wrong"},
            body=cmd_body,
        )
        self.assertEqual(st, 401)

        # Non-JSON Content-Type rejected
        st, _, _ = self._raw_request(
            "POST",
            "/api/commands",
            headers={"Content-Type": "text/plain", "X-Parfait-Workbench-Token": self.token},
            body=cmd_body,
        )
        self.assertEqual(st, 415)

        # Control /api/commands still caps at 2 MB while /api/client/command-result accepts >2 MB screenshots
        raw_req = (
            f"POST /api/commands HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.port}\r\n"
            f"Content-Type: application/json\r\n"
            f"X-Parfait-Workbench-Token: {self.token}\r\n"
            f"Content-Length: {2 * 1024 * 1024 + 100}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("ascii")
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(raw_req)
            resp_head = s.recv(4096).decode("utf-8", errors="replace")
        self.assertIn("400 ", resp_head.splitlines()[0])
        big_png = b"\x89PNG\r\n\x1a\n" + (b"\x00" * (1600 * 1024))
        big_b64 = base64.b64encode(big_png).decode("ascii")
        big_shot = json.dumps({
            "clientId": "win-1",
            "id": "shot-1",
            "ok": True,
            "result": {"width": 1280, "height": 800, "pngBase64": big_b64},
        }).encode()
        st, _, _ = self._raw_request("POST", "/api/client/command-result", headers=self._authed_headers(), body=big_shot)
        self.assertEqual(st, 200)

        st, _, state_raw = self._raw_request("GET", "/api/state")
        self.assertEqual(st, 200)
        state_json = json.loads(state_raw)
        self.assertNotIn("pngBase64", state_raw.decode("utf-8"))
        shot_res = state_json["commandResults"][0]["result"]
        self.assertEqual(shot_res["screenshotUrl"], "/api/screenshots/shot-1.png")
        self.assertEqual(shot_res["bytes"], len(big_png))
        self.assertLess(len(state_raw), 64 * 1024)

        st, hdrs, fetched_png = self._raw_request("GET", "/api/screenshots/shot-1.png")
        self.assertEqual(st, 200)
        self.assertEqual(hdrs["content-type"], "image/png")
        self.assertEqual(fetched_png, big_png)

    def test_closed_command_and_fault_schemas(self) -> None:
        hb = json.dumps({"clientId": "linux-1", "platform": "linux", "snapshot": {}, "logs": []}).encode()
        self._raw_request("POST", "/api/client/heartbeat", headers=self._authed_headers(), body=hb)

        bad_commands = [
            {"clientId": "linux-1", "type": "execShell", "args": {"cmd": "id"}},
            {"clientId": "linux-1", "type": "navigate", "args": {"path": "https://evil.com/pwn"}},
            {"clientId": "linux-1", "type": "navigate", "args": {"path": "/foo/../secret"}},
            {"clientId": "linux-1", "type": "history", "args": {"action": "clear"}},
            {"clientId": "linux-1", "type": "resizeWindow", "args": {"width": 100, "height": 800}},
            {"clientId": "linux-1", "type": "resizeWindow", "args": {"width": 9999, "height": 900}},
            {"clientId": "linux-1", "type": "setSourceMode", "args": {"mode": "proxy", "loopbackOrigin": "https://evil.com"}},
            {"clientId": "linux-1", "type": "findBounds", "args": {"kind": "xpath", "query": "//button"}},
            {"clientId": "linux-1", "type": "captureScreenshot", "args": {"quality": 80}},
        ]
        for payload in bad_commands:
            st, _, raw = self._raw_request(
                "POST",
                "/api/commands",
                headers=self._authed_headers(),
                body=json.dumps(payload).encode(),
            )
            self.assertEqual(st, 400, f"expected 400 for invalid command: {payload}")
            if payload["type"] == "captureScreenshot":
                self.assertIn("captureScreenshot", raw.decode("utf-8"))

        good_commands = [
            {"clientId": "linux-1", "type": "navigate", "args": {"path": "/illust/900001"}},
            {"clientId": "linux-1", "type": "history", "args": {"action": "back"}},
            {"clientId": "linux-1", "type": "resizeWindow", "args": {"width": 1280, "height": 800}},
            {"clientId": "linux-1", "type": "findBounds", "args": {"kind": "key", "query": "btn_download"}},
            {"clientId": "linux-1", "type": "captureScreenshot", "args": {}},
        ]
        for payload in good_commands:
            st, _, _ = self._raw_request(
                "POST",
                "/api/commands",
                headers=self._authed_headers(),
                body=json.dumps(payload).encode(),
            )
            self.assertEqual(st, 200, f"expected 200 for valid command: {payload}")

        st, _, _ = self._raw_request(
            "POST",
            "/api/faults",
            headers=self._authed_headers(),
            body=json.dumps({"routePrefix": "../etc", "mode": "server_500"}).encode(),
        )
        self.assertEqual(st, 400)

    def test_redaction_strips_secrets_across_logs_snapshots_and_traces(self) -> None:
        hb = {
            "clientId": "android-1",
            "platform": "android",
            "snapshot": {
                "route": "/recommended",
                "accessToken": "super-secret-oauth-token",
                "cookie": "PHPSESSID=secretcookie",
                "transferEnvelope": "top-secret-envelope",
            },
            "logs": [
                {
                    "seq": 1,
                    "timestamp": "2026-11-16T00:00:00Z",
                    "level": "info",
                    "source": "net",
                    "message": (
                        "GET /callback?code=authcode12345&client_secret=cs_xyz&oauth_token=ot_abc "
                        "Authorization: Basic dXNlcjpwYXNz X-Api-Key: sk_test_key "
                        "Cookie: a=1; PHPSESSID=multipart_cookie_secret; theme=dark "
                        "eyJ2ZXJzaW9uIjoyLCJwYXlsb2FkVHlwZSI6InBpeGl2LWFjY291bnQtdHJhbnNmZXIiLCJwYXlsb2FkIjp7fX0="
                    ),
                }
            ],
        }
        st, _, _ = self._raw_request(
            "POST",
            "/api/client/heartbeat",
            headers=self._authed_headers(),
            body=json.dumps(hb).encode(),
        )
        self.assertEqual(st, 200)

        # Trigger a Pixiv gateway request carrying Authorization + Cookie headers
        st, _, _ = self._raw_request(
            "GET",
            "/v1/illust/recommended?filter=for_ios",
            headers={
                "X-Parfait-Target-Host": "app-api.pixiv.net",
                "Authorization": "Bearer live_bearer_should_never_leak",
                "Cookie": "PHPSESSID=cookie_should_never_leak",
            },
        )
        self.assertEqual(st, 200)

        st, _, raw = self._raw_request("GET", "/api/state")
        self.assertEqual(st, 200)
        serialized = raw.decode("utf-8")
        for secret in (
            "super-secret-oauth-token",
            "secretcookie",
            "top-secret-envelope",
            "authcode12345",
            "cs_xyz",
            "ot_abc",
            "dXNlcjpwYXNz",
            "sk_test_key",
            "multipart_cookie_secret",
            "eyJ2ZXJzaW9uIjoyLCJwYXlsb2FkVHlwZSI6InBpeGl2LWFjY291bnQtdHJhbnNmZXIi",
            "live_bearer_should_never_leak",
            "cookie_should_never_leak",
        ):
            self.assertNotIn(secret, serialized)
        self.assertIn("[REDACTED]", serialized)

        # Also verify /__pixiv__/<host><path> with X-Parfait-Target-Host strips prefix properly
        st, _, raw = self._raw_request(
            "GET",
            "/__pixiv__/app-api.pixiv.net/v1/illust/recommended?filter=for_ios",
            headers={"X-Parfait-Target-Host": "app-api.pixiv.net"},
        )
        self.assertEqual(st, 200)
        self.assertIn("illusts", raw.decode("utf-8"))

    def test_loopback_pixiv_gateway_payloads_and_fault_injection(self) -> None:
        # Recommended illusts
        st, _, raw = self._raw_request(
            "GET",
            "/v1/illust/recommended?filter=for_ios&include_ranking_illusts=true",
            headers={"X-Parfait-Target-Host": "app-api.pixiv.net"},
        )
        self.assertEqual(st, 200)
        data = json.loads(raw)
        self.assertGreaterEqual(len(data["illusts"]), 1)
        self.assertEqual(data["illusts"][0]["id"], 900001)

        # PNG binary image on pximg
        st, hdrs, png = self._raw_request(
            "GET",
            "/img-original/img/900001_p0.png",
            headers={"X-Parfait-Target-Host": "i.pximg.net"},
        )
        self.assertEqual(st, 200)
        self.assertTrue(hdrs["content-type"].startswith("image/png"))
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))

        # Ugoira zip binary
        st, hdrs, zbytes = self._raw_request(
            "GET",
            "/img-zip-ugoira/img/900003_ugoira600x600.zip",
            headers={"X-Parfait-Target-Host": "i.pximg.net"},
        )
        self.assertEqual(st, 200)
        with zipfile.ZipFile(BytesIO(zbytes)) as zf:
            self.assertEqual(zf.namelist(), ["000000.png", "000001.png", "000002.png"])

        # Novel webview bootstrap HTML
        st, hdrs, nhtml = self._raw_request(
            "GET",
            "/webview/v2/novel?id=800001",
            headers={"X-Parfait-Target-Host": "app-api.pixiv.net"},
        )
        self.assertEqual(st, 200)
        self.assertIn("Object.defineProperty(window, 'pixiv'", nhtml.decode("utf-8"))

        # Fault injection: 429 & offline socket close & reset
        st, _, _ = self._raw_request(
            "POST",
            "/api/faults",
            headers=self._authed_headers(),
            body=json.dumps({"routePrefix": "/v1/illust/ranking", "mode": "rate_limit_429"}).encode(),
        )
        self.assertEqual(st, 200)
        st, _, _ = self._raw_request(
            "GET",
            "/v1/illust/ranking",
            headers={"X-Parfait-Target-Host": "app-api.pixiv.net"},
        )
        self.assertEqual(st, 429)

        st, _, _ = self._raw_request(
            "POST",
            "/api/faults",
            headers=self._authed_headers(),
            body=json.dumps({"routePrefix": "/v1/illust/ranking", "mode": "offline"}).encode(),
        )
        self.assertEqual(st, 200)
        with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError)):
            self._raw_request(
                "GET",
                "/v1/illust/ranking",
                headers={"X-Parfait-Target-Host": "app-api.pixiv.net"},
            )

        st, _, _ = self._raw_request(
            "POST",
            "/api/faults",
            headers=self._authed_headers(),
            body=json.dumps({"reset": True}).encode(),
        )
        self.assertEqual(st, 200)
        st, _, _ = self._raw_request(
            "GET",
            "/v1/illust/ranking",
            headers={"X-Parfait-Target-Host": "app-api.pixiv.net"},
        )
        self.assertEqual(st, 200)

    def test_artifact_traversal_blocked(self) -> None:
        st, _, _ = self._raw_request("GET", "/artifacts/../session.json")
        self.assertIn(st, (403, 404))
        st, _, raw = self._raw_request("GET", "/artifacts/sample.png")
        self.assertEqual(st, 200)
        self.assertTrue(raw.startswith(b"\x89PNG"))

    def test_emulator_host_opt_in_only_allows_non_browser_avd_traffic(self) -> None:
        # Default server rejects 10.0.2.2 Host header
        st, _, _ = self._raw_request("GET", "/api/state", host=f"10.0.2.2:{self.port}")
        self.assertEqual(st, 403)

        emu_server = ParfaitWorkbenchServer(0, self.state, allow_emulator_host=True)
        emu_port = emu_server.bound_port
        t = threading.Thread(target=emu_server.serve_forever, daemon=True)
        t.start()
        try:
            conn = http.client.HTTPConnection("127.0.0.1", emu_port, timeout=5)
            try:
                # Non-browser native AVD request allowed
                conn.request("GET", "/api/state", headers={"Host": f"10.0.2.2:{emu_port}"})
                self.assertEqual(conn.getresponse().status, 200)
            finally:
                conn.close()

            # Browser requests with Origin or Sec-Fetch-Site still blocked even when enabled
            for extra in (
                {"Origin": f"http://10.0.2.2:{emu_port}"},
                {"Sec-Fetch-Site": "cross-site"},
                {"Sec-Fetch-Site": "same-origin"},
            ):
                conn = http.client.HTTPConnection("127.0.0.1", emu_port, timeout=5)
                try:
                    hdrs = {"Host": f"10.0.2.2:{emu_port}", **extra}
                    conn.request("GET", "/api/state", headers=hdrs)
                    self.assertEqual(conn.getresponse().status, 403)
                finally:
                    conn.close()
        finally:
            emu_server.shutdown()
            emu_server.server_close()


if __name__ == "__main__":
    unittest.main()
