"""Cross-WSL2 streaming media encoder via Windows `ffmpeg.exe` & decode checker."""

from __future__ import annotations

import dataclasses
import functools
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from typing import Any

from ..win_hidden_desktop import to_windows_path, to_wsl_path

DEFAULT_FFMPEG_EXE = "/mnt/c/Users/Public/sdct_portable_test/ffmpeg/ffmpeg.exe"
_DIM_RE = re.compile(r",\s*(\d{2,5})x(\d{2,5})(?:[\s,\[])")


@dataclasses.dataclass(frozen=True)
class EncodedArtifact:
    path: Path
    fmt: str
    width: int
    height: int
    bytes: int
    duration_ms: int
    decode_verified: bool
    decode_error: str = ""
    sheet_paths: tuple[Path, ...] = ()
    motion_metrics: dict[str, Any] = dataclasses.field(default_factory=dict)


def resolve_ffmpeg_exe() -> str:
    env_bin = os.environ.get("PARFAIT_FFMPEG_BIN", "").strip()
    if env_bin:
        return env_bin
    if Path(DEFAULT_FFMPEG_EXE).is_file():
        return DEFAULT_FFMPEG_EXE
    found = shutil.which("ffmpeg.exe") or shutil.which("ffmpeg")
    if found:
        return found
    raise FileNotFoundError(
        f"ffmpeg binary not found at {DEFAULT_FFMPEG_EXE} or PATH"
    )


@functools.lru_cache(maxsize=1)
def _win_stage_base_wsl() -> Path:
    """Resolve a fast Win32-writable temp folder accessible from both WSL and ffmpeg.exe."""
    cmd_exe = "/mnt/c/Windows/System32/cmd.exe"
    if Path(cmd_exe).is_file():
        try:
            res = subprocess.run(
                [cmd_exe, "/c", "echo %TEMP%"],
                cwd="/mnt/c",
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=5.0,
            )
            win_temp = res.stdout.strip().splitlines()[-1].strip() if res.stdout.strip() else ""
            if win_temp and len(win_temp) >= 3 and win_temp[1] == ":":
                base = to_wsl_path(win_temp) / "parfait_ffmpeg_stage"
                base.mkdir(parents=True, exist_ok=True)
                return base
        except (subprocess.SubprocessError, OSError):
            pass
    fallback = Path(tempfile.gettempdir()) / "parfait_ffmpeg_stage"
    fallback.mkdir(parents=True, exist_ok=True)
    return fallback


def _to_ffmpeg_path(path: Path) -> str:
    ffmpeg = resolve_ffmpeg_exe()
    if ffmpeg.lower().endswith(".exe"):
        return to_windows_path(path)
    return str(path)


_DURATION_RE = re.compile(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)")


def _probe_media_duration_ms(media_path: Path) -> int | None:
    """Parse actual stream duration in milliseconds from `ffmpeg -hide_banner -i`."""
    if not media_path.is_file() or media_path.stat().st_size <= 0:
        return None
    ffmpeg = resolve_ffmpeg_exe()
    stage_dir: Path | None = None
    target = media_path
    try:
        if ffmpeg.lower().endswith(".exe") and not str(media_path).startswith("/mnt/"):
            stage_dir = _win_stage_base_wsl() / uuid.uuid4().hex[:10]
            stage_dir.mkdir(parents=True, exist_ok=True)
            target = stage_dir / media_path.name
            shutil.copy2(media_path, target)
        win_in = _to_ffmpeg_path(target)
        win_cwd = "/mnt/c" if ffmpeg.lower().endswith(".exe") else None
        info = subprocess.run(
            [ffmpeg, "-hide_banner", "-i", win_in],
            cwd=win_cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15.0,
        )
        m = _DURATION_RE.search(info.stderr or "")
        if m:
            hrs, mins, secs = int(m.group(1)), int(m.group(2)), float(m.group(3))
            return max(100, round(((hrs * 60 + mins) * 60 + secs) * 1000.0))
        return None
    except (subprocess.SubprocessError, OSError):
        return None
    finally:
        if stage_dir is not None:
            shutil.rmtree(stage_dir, ignore_errors=True)


def verify_media_stream(media_path: Path) -> tuple[bool, str, int, int]:
    """Decode every frame using `ffmpeg -v error -f null -` and read dimensions."""
    if not media_path.is_file() or media_path.stat().st_size <= 0:
        return False, "output file missing or zero bytes", 0, 0

    ffmpeg = resolve_ffmpeg_exe()
    stage_dir: Path | None = None
    target = media_path
    try:
        if ffmpeg.lower().endswith(".exe") and not str(media_path).startswith("/mnt/"):
            stage_dir = _win_stage_base_wsl() / uuid.uuid4().hex[:10]
            stage_dir.mkdir(parents=True, exist_ok=True)
            target = stage_dir / media_path.name
            shutil.copy2(media_path, target)

        win_in = _to_ffmpeg_path(target)
        win_cwd = "/mnt/c" if ffmpeg.lower().endswith(".exe") else None
        chk = subprocess.run(
            [ffmpeg, "-v", "error", "-i", win_in, "-f", "null", "-"],
            cwd=win_cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30.0,
        )
        if chk.returncode != 0 or chk.stderr.strip():
            return False, (chk.stderr or f"exit {chk.returncode}").strip(), 0, 0

        # Query stream info for WxH
        info = subprocess.run(
            [ffmpeg, "-hide_banner", "-i", win_in],
            cwd=win_cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15.0,
        )
        width = height = 0
        for line in (info.stderr or "").splitlines():
            if "Video:" in line:
                m = _DIM_RE.search(line)
                if m:
                    width, height = int(m.group(1)), int(m.group(2))
                    break
        return True, "", width, height
    finally:
        if stage_dir is not None:
            shutil.rmtree(stage_dir, ignore_errors=True)


def encode_frames_to_media(
    frames: list[bytes],
    out_path: Path,
    fmt: str,
    *,
    fps: int = 20,
    input_codec: str = "png",
    sheet_dir: Path | None = None,
    direction: str = "one_way",
) -> EncodedArtifact:
    """Encode in-memory PNG/BMP frames via stdin `image2pipe` into *out_path*."""
    if fmt not in ("mp4", "gif"):
        raise ValueError(f"Unsupported media format: {fmt!r}")
    if not frames:
        raise ValueError("Cannot encode empty frame list")

    effective = list(frames)
    if len(effective) == 1:
        effective.append(effective[0])

    ffmpeg = resolve_ffmpeg_exe()
    stage_dir = _win_stage_base_wsl() / uuid.uuid4().hex[:10]
    stage_dir.mkdir(parents=True, exist_ok=True)
    staged_out = stage_dir / f"out.{fmt}"
    try:
        ffmpeg_out = _to_ffmpeg_path(staged_out)
        if fmt == "mp4":
            vcodec_args = [
                "-vf",
                "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                "-c:v",
                "libx264",
                "-preset",
                "fast",
                "-crf",
                "22",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
            ]
        else:
            gif_fps = min(fps, 20)
            vcodec_args = [
                "-vf",
                f"fps={gif_fps},scale=trunc(iw/2)*2:-1:flags=lanczos,"
                "split[s0][s1];[s0]palettegen=max_colors=192:stats_mode=diff[p];"
                "[s1][p]paletteuse=dither=bayer:bayer_scale=5",
            ]

        cmd = [
            ffmpeg,
            "-y",
            "-v",
            "error",
            "-f",
            "image2pipe",
            "-vcodec",
            input_codec,
            "-framerate",
            str(fps),
            "-i",
            "-",
            *vcodec_args,
            ffmpeg_out,
        ]
        payload = b"".join(effective)
        win_cwd = "/mnt/c" if ffmpeg.lower().endswith(".exe") else None
        res = subprocess.run(cmd, cwd=win_cwd, input=payload, capture_output=True, timeout=60.0)
        if res.returncode != 0:
            raise RuntimeError(
                f"ffmpeg encode failed ({fmt}, rc={res.returncode}): "
                f"{res.stderr.decode('utf-8', errors='replace').strip()}"
            )

        out_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(staged_out, out_path)
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)

    ok, err, w, h = verify_media_stream(out_path)
    duration_ms = max(100, round(len(effective) * 1000.0 / max(1, fps)))
    sheet_paths: tuple[Path, ...] = ()
    motion_metrics: dict[str, Any] = {}
    if sheet_dir is not None and ok:
        from .storyboard import build_storyboard_from_frame_bytes

        sheets, motion_metrics = build_storyboard_from_frame_bytes(
            frames,
            sheet_dir,
            fps=fps,
            direction=direction,
        )
        sheet_paths = tuple(sheets)
    return EncodedArtifact(
        path=out_path,
        fmt=fmt,
        width=w,
        height=h,
        bytes=out_path.stat().st_size if out_path.is_file() else 0,
        duration_ms=duration_ms,
        decode_verified=ok,
        decode_error=err,
        sheet_paths=sheet_paths,
        motion_metrics=motion_metrics,
    )


def transcode_video_segment(
    raw_mp4: Path,
    out_path: Path,
    fmt: str,
    *,
    start_sec: float = 0.0,
    duration_sec: float | None = None,
    fps: int = 24,
    sheet_dir: Path | None = None,
    direction: str = "one_way",
) -> EncodedArtifact:
    """Trim/transcode an MP4 (e.g., from `adb screenrecord`) into MP4 or palette GIF."""
    if fmt not in ("mp4", "gif"):
        raise ValueError(f"Unsupported media format: {fmt!r}")
    if not raw_mp4.is_file() or raw_mp4.stat().st_size <= 0:
        raise FileNotFoundError(f"Missing raw video: {raw_mp4}")

    ffmpeg = resolve_ffmpeg_exe()
    stage_dir = _win_stage_base_wsl() / uuid.uuid4().hex[:10]
    stage_dir.mkdir(parents=True, exist_ok=True)
    staged_in = stage_dir / raw_mp4.name
    staged_out = stage_dir / f"out.{fmt}"
    try:
        shutil.copy2(raw_mp4, staged_in)
        win_in = _to_ffmpeg_path(staged_in)
        win_out = _to_ffmpeg_path(staged_out)

        cmd = [ffmpeg, "-y", "-v", "error"]
        if start_sec > 0:
            cmd.extend(["-ss", f"{start_sec:.3f}"])
        cmd.extend(["-i", win_in])
        if duration_sec is not None and duration_sec > 0:
            cmd.extend(["-t", f"{duration_sec:.3f}"])

        if fmt == "mp4":
            cmd.extend([
                "-vf",
                "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                "-c:v",
                "libx264",
                "-preset",
                "fast",
                "-crf",
                "23",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
            ])
        else:
            gif_fps = min(fps, 18)
            cmd.extend([
                "-vf",
                f"fps={gif_fps},scale=min(720\\,trunc(iw/2)*2):-1:flags=lanczos,"
                "split[s0][s1];[s0]palettegen=max_colors=192:stats_mode=diff[p];"
                "[s1][p]paletteuse=dither=bayer:bayer_scale=5",
            ])
        cmd.append(win_out)
        win_cwd = "/mnt/c" if ffmpeg.lower().endswith(".exe") else None
        res = subprocess.run(
            cmd,
            cwd=win_cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=90.0,
        )
        if res.returncode != 0:
            raise RuntimeError(f"ffmpeg transcode failed ({fmt}): {res.stderr.strip()}")

        out_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(staged_out, out_path)
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)

    ok, err, w, h = verify_media_stream(out_path)
    measured_ms = _probe_media_duration_ms(out_path) if ok else None
    dur_ms = measured_ms if measured_ms is not None else int((duration_sec or 1.5) * 1000)
    sheet_paths: tuple[Path, ...] = ()
    motion_metrics: dict[str, Any] = {}
    if sheet_dir is not None and ok:
        from .storyboard import build_storyboard_from_media

        sheets, motion_metrics = build_storyboard_from_media(
            out_path,
            sheet_dir,
            direction=direction,
        )
        sheet_paths = tuple(sheets)
    return EncodedArtifact(
        path=out_path,
        fmt=fmt,
        width=w,
        height=h,
        bytes=out_path.stat().st_size if out_path.is_file() else 0,
        duration_ms=dur_ms,
        decode_verified=ok,
        decode_error=err,
        sheet_paths=sheet_paths,
        motion_metrics=motion_metrics,
    )
