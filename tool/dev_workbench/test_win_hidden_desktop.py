"""Unit tests for the Win32 secondary-desktop workbench helper."""

from __future__ import annotations

import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.win_hidden_desktop import (  # noqa: E402
    HiddenDesktopError,
    WinHiddenDesktopSession,
    build_windows_command_line,
    kill_matching_parfait_processes,
    ps_single_quote,
    to_windows_path,
    to_wsl_path,
)


class _FakePopen:
    """Minimal Popen double at the OS process boundary."""

    def __init__(self, stdout_lines: list[str], *, exit_code: int | None = None) -> None:
        self.stdout = io.StringIO("".join(stdout_lines))
        self.stderr = io.StringIO("")
        self._exit_code = exit_code
        self.returncode = exit_code
        self.terminated = False

    def poll(self) -> int | None:
        return self._exit_code

    def wait(self, timeout: float | None = None) -> int:
        self._exit_code = 0
        self.returncode = 0
        return 0

    def terminate(self) -> None:
        self.terminated = True
        self._exit_code = -15
        self.returncode = -15


class WinHiddenDesktopTests(unittest.TestCase):
    def test_path_and_command_line_conversions(self) -> None:
        self.assertEqual(to_windows_path("/mnt/e/dev/parfait-win"), r"E:\dev\parfait-win")
        self.assertEqual(to_windows_path("/mnt/c"), "C:\\")
        self.assertEqual(to_windows_path(r"D:/foo/bar"), r"D:\foo\bar")
        self.assertEqual(to_wsl_path(r"E:\dev\parfait-win"), Path("/mnt/e/dev/parfait-win"))
        self.assertEqual(to_wsl_path("/tmp/already-posix"), Path("/tmp/already-posix"))
        self.assertEqual(ps_single_quote("a'b"), "'a''b'")
        self.assertIn("--dev-profile=e2e", build_windows_command_line("parfait.exe", ["--dev-profile=e2e"]))
        with self.assertRaises(ValueError):
            build_windows_command_line("   ")

    def test_validation_guards_and_kill_requires_substring(self) -> None:
        with self.assertRaises(ValueError):
            WinHiddenDesktopSession(desktop_name="bad desktop name!")
        with self.assertRaises(ValueError):
            kill_matching_parfait_processes("   ")

        recorded: list[str] = []
        kill_matching_parfait_processes(
            "parfait-dev",
            ps_runner=lambda script, **_: recorded.append(script) or "",
        )
        self.assertEqual(len(recorded), 1)
        self.assertIn("'*parfait-dev*'", recorded[0])

    def test_session_lifecycle_cleans_keepalive_and_stops_children_on_error(self) -> None:
        scripts: list[str] = []
        fake_holder = _FakePopen(["DESK_READY\n"])

        def fake_ps(script: str, **_: object) -> str:
            scripts.append(script)
            if "HiddenDeskLaunch" in script:
                return "4242:2:0:258:259"
            if "HiddenDeskClick" in script:
                return "DESK_TARGET=FLUTTERVIEW CLIENT=1600x1000 CLICK=800,400"
            return ""

        with tempfile.TemporaryDirectory() as tmp:
            keepalive_base = Path(tmp)
            sess = WinHiddenDesktopSession(
                desktop_name="TestDesk",
                keepalive_dir=keepalive_base,
                ps_runner=fake_ps,
                popen_fn=lambda *a, **kw: fake_holder,
                win_path_resolver=lambda p: (
                    r"C:\Temp\keepalive" if Path(p).suffix == ".keepalive" else to_windows_path(p)
                ),
            )
            with self.assertRaises(RuntimeError):
                with sess:
                    self.assertTrue(sess._keepalive_wsl.exists())
                    launch = sess.launch(
                        "/mnt/e/dev/parfait.exe",
                        ["--source=loopback"],
                        env_vars={"PARFAIT_DEV_ROOT": r"E:\dev\root"},
                    )
                    self.assertEqual(launch.pid, 4242)
                    self.assertEqual(launch.default_windows, 0)
                    self.assertTrue(launch.still_running)
                    out = sess.click_bounds(
                        launch.pid,
                        {"centerX": 640, "centerY": 400},
                        {"width": 1280, "height": 800},
                    )
                    self.assertIn("CLICK=800,400", out)
                    raise RuntimeError("boom")

            self.assertFalse(sess._keepalive_wsl.exists())
            self.assertTrue(any("Stop-Process -Id 4242" in s for s in scripts))

    def test_launch_rejects_default_desktop_leak_and_stops_pid(self) -> None:
        scripts: list[str] = []
        fake_holder = _FakePopen(["DESK_READY\n"])

        def fake_ps(script: str, **_: object) -> str:
            scripts.append(script)
            if "HiddenDeskLaunch" in script:
                return "9001:1:1:258:259"
            return ""

        with tempfile.TemporaryDirectory() as tmp:
            sess = WinHiddenDesktopSession(
                desktop_name="LeakCheckDesk",
                keepalive_dir=Path(tmp),
                ps_runner=fake_ps,
                popen_fn=lambda *a, **kw: fake_holder,
                win_path_resolver=lambda p: r"C:\Temp\k",
            )
            with sess:
                with self.assertRaises(HiddenDesktopError):
                    sess.launch("/mnt/e/dev/parfait.exe")
        self.assertTrue(any("Stop-Process -Id 9001" in s for s in scripts))


if __name__ == "__main__":
    unittest.main()
