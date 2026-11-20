"""Developer helper to run the hardened workbench server and launch dev clients."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.win_hidden_desktop import (
    DEFAULT_DESKTOP_NAME,
    WinHiddenDesktopSession,
    to_windows_path,
    to_wsl_path,
)

ROOT_DIR = Path(__file__).resolve().parents[2]
FLUTTER_BIN = os.environ.get("FLUTTER_BIN", "/opt/flutter-3.47.9/bin/flutter")
STATE_FILE = ROOT_DIR / ".dart_tool" / "dev_workbench" / "session.json"


def _read_session(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _drain_stream(pipe: Any) -> None:
    try:
        for line in pipe:
            text = line.strip()
            if text:
                print(text, flush=True)
    except Exception:
        pass


def _ensure_server(
    port: int,
    artifacts_dir: str | None,
    *,
    allow_emulator_host: bool = False,
) -> tuple[dict[str, object], subprocess.Popen[str] | None]:
    existing = _read_session(STATE_FILE)
    if existing and existing.get("port") == port and existing.get("token"):
        pid = existing.get("pid")
        if isinstance(pid, int):
            try:
                os.kill(pid, 0)
                return existing, None
            except OSError:
                pass

    cmd = [
        sys.executable,
        str(ROOT_DIR / "tool" / "dev_workbench" / "server.py"),
        "--port",
        str(port),
        "--state-file",
        str(STATE_FILE),
    ]
    if artifacts_dir:
        cmd.extend(["--artifacts-dir", artifacts_dir])
    if allow_emulator_host:
        cmd.append("--allow-emulator-host")
    proc = subprocess.Popen(
        cmd,
        cwd=str(ROOT_DIR),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    deadline = time.time() + 10.0
    while time.time() < deadline:
        if proc.stdout is not None:
            line = proc.stdout.readline().strip()
            if line:
                print(line, flush=True)
                if "workbench_ready" in line:
                    session = _read_session(STATE_FILE)
                    if session:
                        threading.Thread(
                            target=_drain_stream,
                            args=(proc.stdout,),
                            daemon=True,
                        ).start()
                        return session, proc
        time.sleep(0.1)
    proc.terminate()
    raise RuntimeError("dev_workbench server failed to become ready within 10s")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Launch Parfait Workbench + isolated dev client")
    parser.add_argument(
        "--platform",
        choices=("server", "linux", "android", "windows-cmd", "windows-hidden"),
        default="server",
    )
    parser.add_argument("--source", choices=("loopback", "live"), default="loopback")
    parser.add_argument("--port", type=int, default=18490)
    parser.add_argument("--profile", default="default")
    parser.add_argument("--fresh-onboarding", action="store_true")
    parser.add_argument("--artifacts-dir", default=None)
    parser.add_argument("--device-id", default=None)
    parser.add_argument("--win-exe", default=None, help="Path to Windows dev parfait.exe for windows-hidden")
    parser.add_argument("--win-dev-root", default=None, help="Windows isolated PARFAIT_DEV_ROOT directory")
    parser.add_argument("--dev-root", default=None, help="Explicit isolated PARFAIT_DEV_ROOT directory")
    parser.add_argument("--desktop-name", default=DEFAULT_DESKTOP_NAME, help="Secondary Win32 desktop name")
    parser.add_argument(
        "--allow-emulator-host",
        action="store_true",
        help="Allow non-browser Android AVD traffic via 10.0.2.2:<port> without adb reverse",
    )
    args = parser.parse_args(argv)

    session, server_proc = _ensure_server(
        args.port,
        args.artifacts_dir,
        allow_emulator_host=args.allow_emulator_host,
    )
    url = str(session["url"])
    token = str(session["token"])
    client_workbench_url = (
        f"http://10.0.2.2:{args.port}"
        if args.platform == "android" and args.allow_emulator_host
        else url
    )
    print(f"Workbench URL: {url}/  (profile={args.profile}, source={args.source})", flush=True)

    defines = [
        f"--dart-define=PARFAIT_DEV_PROFILE_NAME={args.profile}",
        f"--dart-define=PARFAIT_DEV_SOURCE={args.source}",
        f"--dart-define=PARFAIT_DEV_LOOPBACK_URL={client_workbench_url}",
        f"--dart-define=PARFAIT_WORKBENCH_URL={client_workbench_url}",
        f"--dart-define=PARFAIT_WORKBENCH_TOKEN={token}",
        "--dart-define=PARFAIT_DEV_SHELL=true",
    ]
    if args.dev_root:
        defines.append(f"--dart-define=PARFAIT_DEV_ROOT={args.dev_root}")
    if args.fresh_onboarding:
        defines.append("--dart-define=PARFAIT_DEV_FRESH_ONBOARDING=true")

    if args.platform == "server":
        print("Server running. Press Ctrl+C to stop.", flush=True)
        try:
            while True:
                time.sleep(1.0)
        except KeyboardInterrupt:
            if server_proc is not None:
                server_proc.terminate()
            return 0

    if args.platform == "windows-cmd":
        win_root_display = args.win_dev_root or r"%APPDATA%\io.github.lopution\parfait-dev\profiles"
        print(
            "Windows dev launch env & args:\n"
            f"  set PARFAIT_DEV_PROFILE=1\n"
            f"  set PARFAIT_DEV_INSTANCE=1\n"
            f"  set PARFAIT_DEV_ROOT={win_root_display}\n"
            f"  parfait.exe --dev-profile={args.profile} --profile={args.profile} "
            f"--source={args.source} --loopback={url} --workbench-url={url} "
            f"--workbench-token={token}"
            f"{' --fresh-onboarding' if args.fresh_onboarding else ''}",
            flush=True,
        )
        if server_proc is not None:
            server_proc.terminate()
        return 0

    if args.platform == "windows-hidden":
        if not args.win_exe:
            parser.error("--win-exe is required when --platform=windows-hidden")
        if not args.win_dev_root:
            parser.error("--win-dev-root is required when --platform=windows-hidden")
        win_args = [
            f"--dev-profile={args.profile}",
            f"--source={args.source}",
            f"--loopback={url}",
            f"--workbench-url={url}",
            f"--workbench-token={token}",
        ]
        if args.fresh_onboarding:
            win_args.append("--fresh-onboarding")
        win_root_dir = to_wsl_path(args.win_dev_root)
        win_root_dir.mkdir(parents=True, exist_ok=True)
        win_env = {
            "PARFAIT_DEV_PROFILE": "1",
            "PARFAIT_DEV_INSTANCE": "1",
            "PARFAIT_DEV_ROOT": to_windows_path(win_root_dir),
        }
        try:
            with WinHiddenDesktopSession(
                desktop_name=args.desktop_name,
                keepalive_dir=win_root_dir,
            ) as desk:
                launch = desk.launch(args.win_exe, win_args, env_vars=win_env)
                print(
                    f"Windows hidden-desktop client launched on WinSta0\\{desk.desktop_name}: "
                    f"pid={launch.pid} hidden_wins={launch.hidden_windows} default_wins={launch.default_windows}",
                    flush=True,
                )
                while True:
                    time.sleep(1.0)
        except KeyboardInterrupt:
            return 0
        finally:
            if server_proc is not None:
                server_proc.terminate()

    env = os.environ.copy()
    env.update({
        "PARFAIT_DEV_PROFILE": "1",
        "PARFAIT_DEV_INSTANCE": "1",
        "PARFAIT_DEV_PROFILE_NAME": args.profile,
        "PARFAIT_DEV_SOURCE": args.source,
        "PARFAIT_DEV_LOOPBACK_URL": client_workbench_url,
        "PARFAIT_WORKBENCH_URL": client_workbench_url,
        "PARFAIT_WORKBENCH_TOKEN": token,
    })
    if args.platform == "linux":
        linux_dev_root = args.dev_root or os.environ.get("PARFAIT_DEV_ROOT") or str(
            ROOT_DIR / ".dart_tool" / "dev_workbench" / "profiles" / "linux"
        )
        Path(linux_dev_root).mkdir(parents=True, exist_ok=True)
        env["PARFAIT_DEV_ROOT"] = linux_dev_root
        env["PARFAIT_APP_ID"] = "io.github.lopution.parfait.dev"
        cmd = [FLUTTER_BIN, "run", "-d", "linux", "-t", "lib/main_dev.dart", *defines]
    else:
        if not args.allow_emulator_host:
            adb = shutil.which("adb") or "/opt/android-sdk/platform-tools/adb"
            rev_cmd = [adb]
            if args.device_id:
                rev_cmd.extend(["-s", args.device_id])
            rev_cmd.extend(["reverse", f"tcp:{args.port}", f"tcp:{args.port}"])
            subprocess.run(rev_cmd, check=True)
        cmd = [
            FLUTTER_BIN,
            "run",
            *(["-d", args.device_id] if args.device_id else []),
            "--flavor",
            "github",
            "-t",
            "lib/main_dev.dart",
            "--dart-define=PARFAIT_DEV_APP_ID=true",
            *defines,
        ]

    try:
        return subprocess.call(cmd, cwd=str(ROOT_DIR), env=env)
    finally:
        if server_proc is not None:
            server_proc.terminate()


if __name__ == "__main__":
    raise SystemExit(main())
