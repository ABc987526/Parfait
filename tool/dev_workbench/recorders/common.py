"""Shared Dev Workbench client, server lifecycle, target resolution & timeout helpers."""

from __future__ import annotations

import http.client
import json
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CATALOG_PATH = REPO_ROOT / "tool" / "dev_workbench" / "catalog" / "catalog.json"
ROUTE_MAP_PATH = REPO_ROOT / "tool" / "dev_workbench" / "catalog" / "route_coverage_map.json"


class CommandTimeoutError(TimeoutError):
    """Raised when a Workbench client command does not return before deadline."""


class TargetNotFoundError(RuntimeError):
    """Raised when a non-optional catalog target locator cannot be found on screen."""


def load_catalog(path: Path = CATALOG_PATH) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return list(data.get("items", []))


def is_pre_home_item(item: dict[str, Any]) -> bool:
    sim_setup = item.get("sim_setup")
    if isinstance(sim_setup, dict) and sim_setup.get("signedIn") is False:
        return True
    rt = str(item.get("route_template") or "")
    return rt in ("/splash", "/welcome", "/welcome/language", "/user-agreement", "/login", "/login/web", "/login/callback")


def split_catalog_phases(
    items: list[dict[str, Any]],
    *,
    platform: str,
    include_foreground_opt_in: bool = False,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """Return (pre_home_required, signed_in_required, foreground_or_na_items)."""
    pre_home: list[dict[str, Any]] = []
    signed_in: list[dict[str, Any]] = []
    skipped_or_na: list[dict[str, Any]] = []

    pre_order = {
        "/splash": 0,
        "/welcome": 1,
        "/welcome/language": 2,
        "/login": 3,
        "/user-agreement": 4,
        "/login/web": 5,
        "/login/callback": 6,
    }

    for item in items:
        rule = str((item.get("platforms") or {}).get(platform, "not_applicable:missing"))
        if rule.startswith("not_applicable:"):
            skipped_or_na.append(item)
            continue
        if rule.startswith("foreground_opt_in:") and not include_foreground_opt_in:
            skipped_or_na.append(item)
            continue
        if is_pre_home_item(item):
            pre_home.append(item)
        else:
            signed_in.append(item)

    pre_home.sort(key=lambda it: pre_order.get(str(it.get("route_template") or ""), 99))
    # Keep destructive window close item at the end of signed_in phase so remaining items don't restart mid-run.
    signed_in.sort(
        key=lambda it: (
            1 if any(step.get("allow_process_exit") for step in it.get("actions", [])) else 0,
        )
    )
    return pre_home, signed_in, skipped_or_na


class WorkbenchClient:
    """Loopback-only HTTP client talking to `server.py`."""

    def __init__(self, base_url: str, token: str) -> None:
        parsed = urllib.parse.urlsplit(base_url)
        if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost"):
            raise ValueError(f"Refusing non-loopback workbench URL: {base_url!r}")
        self.base_url = base_url.rstrip("/")
        self.host = parsed.hostname
        self.port = int(parsed.port or 80)
        self.token = token

    def _request(self, method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10.0)
        try:
            headers = {"Host": f"{self.host}:{self.port}"}
            raw: bytes | None = None
            if body is not None:
                headers["Content-Type"] = "application/json"
                headers["X-Parfait-Workbench-Token"] = self.token
                raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
            conn.request(method, path, body=raw, headers=headers)
            resp = conn.getresponse()
            data = resp.read().decode("utf-8", errors="replace")
            if resp.status < 200 or resp.status >= 300:
                raise RuntimeError(f"Workbench {method} {path} HTTP {resp.status}: {data}")
            return json.loads(data) if data else {}
        finally:
            conn.close()

    def state(self) -> dict[str, Any]:
        return self._request("GET", "/api/state")

    def set_fault(self, route_prefix: str, mode: str) -> None:
        self._request("POST", "/api/faults", {"routePrefix": route_prefix, "mode": mode})

    def reset_faults(self) -> None:
        self._request("POST", "/api/faults", {"reset": True})

    def wait_for_client(
        self,
        *,
        platform_prefix: str | None = None,
        client_id_substring: str | None = None,
        timeout: float = 45.0,
    ) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            st = self.state()
            candidates = [
                c
                for c in st.get("clients", [])
                if c.get("online")
                and (platform_prefix is None or str(c.get("platform", "")).startswith(platform_prefix))
                and (client_id_substring is None or client_id_substring in str(c.get("clientId", "")))
            ]
            if candidates:
                # Pick freshest
                candidates.sort(key=lambda c: float(c.get("ageSeconds", 999.0)))
                return candidates[0]
            time.sleep(0.35)
        raise TimeoutError(
            f"Timed out after {timeout:.0f}s waiting for online client "
            f"(platform={platform_prefix!r}, filter={client_id_substring!r})"
        )

    def send_command(
        self,
        client_id: str,
        cmd_type: str,
        args: dict[str, Any] | None = None,
        *,
        timeout: float = 12.0,
    ) -> dict[str, Any]:
        resp = self._request(
            "POST",
            "/api/commands",
            {"clientId": client_id, "type": cmd_type, "args": args or {}},
        )
        cmd_id = resp["id"]
        deadline = time.time() + timeout
        while time.time() < deadline:
            st = self.state()
            for r in st.get("commandResults", []):
                if r.get("id") == cmd_id:
                    if not r.get("ok"):
                        raise RuntimeError(f"Command {cmd_type} failed: {r.get('error')}")
                    return dict(r.get("result") or {})
            time.sleep(0.18)
        raise CommandTimeoutError(f"Command {cmd_type} ({cmd_id}) timed out after {timeout:.1f}s")

    def snapshot(self, client_id: str, *, timeout: float = 10.0) -> dict[str, Any]:
        return self.send_command(client_id, "snapshot", {}, timeout=timeout)

    def navigate(self, client_id: str, path: str, *, settle_sec: float = 0.65) -> dict[str, Any]:
        res = self.send_command(client_id, "navigate", {"path": path}, timeout=12.0)
        if settle_sec > 0:
            time.sleep(settle_sec)
        return res

    def capture_screenshot_png(self, client_id: str, *, timeout: float = 10.0) -> bytes:
        res = self.send_command(client_id, "captureScreenshot", {}, timeout=timeout)
        url_path = str(res.get("screenshotUrl") or "")
        if not url_path.startswith("/"):
            raise RuntimeError(f"Missing screenshotUrl in captureScreenshot response: {res!r}")
        conn = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        try:
            conn.request(
                "GET",
                url_path,
                headers={
                    "Host": f"{self.host}:{self.port}",
                    "X-Parfait-Workbench-Token": self.token,
                },
            )
            resp = conn.getresponse()
            data = resp.read()
            if resp.status < 200 or resp.status >= 300 or not data.startswith(b"\x89PNG"):
                raise RuntimeError(f"Failed downloading screenshot {url_path}: HTTP {resp.status} ({len(data)}B)")
            return data
        finally:
            conn.close()

    def resolve_target(
        self,
        client_id: str,
        target: dict[str, Any],
        snap: dict[str, Any],
        *,
        override_offsets: tuple[float, float] | None = None,
    ) -> dict[str, Any]:
        """Resolve a catalog target locator to logical/physical coordinates inside viewport."""
        vp = snap.get("viewport") or {"width": 1280, "height": 800, "dpr": 1.0}
        vw = max(1.0, float(vp.get("width") or 1280))
        vh = max(1.0, float(vp.get("height") or 800))
        dpr = float(vp.get("dpr") or 1.0)
        ox = float(override_offsets[0] if override_offsets else target.get("offset_x_ratio", 0.5))
        oy = float(override_offsets[1] if override_offsets else target.get("offset_y_ratio", 0.5))

        kind = str(target.get("kind") or "viewport_ratio")
        if kind == "viewport_ratio":
            rx = float(target.get("x_ratio", 0.5))
            ry = float(target.get("y_ratio", 0.5))
            lx = max(1.0, min(vw - 1.0, vw * rx))
            ly = max(1.0, min(vh - 1.0, vh * ry))
            return {
                "found": True,
                "x": lx,
                "y": ly,
                "px": int(round(lx * dpr)),
                "py": int(round(ly * dpr)),
                "vw": vw,
                "vh": vh,
                "dpr": dpr,
                "bounds": {"x": 0.0, "y": 0.0, "width": vw, "height": vh},
            }

        if kind == "non_client_drag":
            idx = int(target.get("index", 0))
            regions = (snap.get("nonClientRegions") or {}).get("dragRegions") or []
            if not regions or idx >= len(regions):
                raise TargetNotFoundError(f"dragRegions[{idx}] unavailable in snapshot")
            reg = regions[idx]
            lx = float(reg["left"]) + float(reg["width"]) * ox
            ly = float(reg["top"]) + float(reg["height"]) * oy
            return {
                "found": True,
                "x": lx,
                "y": ly,
                "px": int(round(lx * dpr)),
                "py": int(round(ly * dpr)),
                "vw": vw,
                "vh": vh,
                "dpr": dpr,
                "bounds": reg,
            }

        # Map any_key / any_semantics / any_text onto sequential findBounds queries
        if kind in ("key", "semantics", "text"):
            queries = [(kind, str(target.get("query") or ""))]
        elif kind in ("any_key", "any_semantics", "any_text"):
            base_kind = kind.removeprefix("any_")
            queries = [(base_kind, str(q)) for q in (target.get("queries") or [])]
        else:
            raise ValueError(f"Unsupported target kind: {kind!r}")

        for q_kind, q_text in queries:
            if not q_text:
                continue
            res = self.send_command(
                client_id,
                "findBounds",
                {"kind": q_kind, "query": q_text},
                timeout=8.0,
            )
            if res.get("found"):
                bx = float(res["x"])
                by = float(res["y"])
                bw = float(res["width"])
                bh = float(res["height"])
                lx = max(1.0, min(vw - 1.0, bx + bw * ox))
                ly = max(1.0, min(vh - 1.0, by + bh * oy))
                return {
                    "found": True,
                    "x": lx,
                    "y": ly,
                    "px": int(round(lx * dpr)),
                    "py": int(round(ly * dpr)),
                    "vw": vw,
                    "vh": vh,
                    "dpr": dpr,
                    "bounds": res,
                    "matched_query": q_text,
                }
        raise TargetNotFoundError(f"Locator not found on current route: {target!r}")


class ManagedWorkbenchServer:
    """Starts an isolated in-run `server.py` instance with ephemeral token & state file."""

    def __init__(
        self,
        *,
        port: int = 0,
        artifacts_dir: Path | None = None,
        allow_emulator_host: bool = False,
        state_file: Path | None = None,
    ) -> None:
        self.port = port
        self.artifacts_dir = artifacts_dir
        self.allow_emulator_host = allow_emulator_host
        self.state_file = state_file or (
            REPO_ROOT / ".dart_tool" / "dev_workbench" / f"rec_{int(time.time())}.json"
        )
        self._proc: subprocess.Popen[str] | None = None
        self.url: str = ""
        self.token: str = ""
        self.bound_port: int = 0

    def __enter__(self) -> ManagedWorkbenchServer:
        cmd = [
            sys.executable,
            str(REPO_ROOT / "tool" / "dev_workbench" / "server.py"),
            "--port",
            str(self.port),
            "--state-file",
            str(self.state_file),
        ]
        if self.artifacts_dir is not None:
            cmd.extend(["--artifacts-dir", str(self.artifacts_dir)])
        if self.allow_emulator_host:
            cmd.append("--allow-emulator-host")
        self._proc = subprocess.Popen(
            cmd,
            cwd=str(REPO_ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        deadline = time.time() + 12.0
        while time.time() < deadline:
            if self._proc.poll() is not None:
                err = self._proc.stdout.read() if self._proc.stdout else ""
                raise RuntimeError(f"server.py exited early: {err}")
            line = self._proc.stdout.readline().strip() if self._proc.stdout else ""
            if "workbench_ready" in line:
                def _drain(pipe: Any) -> None:
                    try:
                        for _ in pipe:
                            pass
                    except Exception:
                        pass

                threading.Thread(target=_drain, args=(self._proc.stdout,), daemon=True).start()
                info = json.loads(self.state_file.read_text(encoding="utf-8"))
                self.url = str(info["url"])
                self.token = str(info["token"])
                self.bound_port = int(info["port"])
                return self
        raise TimeoutError("Timed out waiting for workbench_ready")

    def client(self) -> WorkbenchClient:
        return WorkbenchClient(self.url, self.token)

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        if self.state_file.exists():
            try:
                self.state_file.unlink()
            except OSError:
                pass
