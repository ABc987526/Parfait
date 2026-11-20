"""UX4-compatible contact sheets (`sheet-NN.png`) & pixel-diff motion analysis."""

from __future__ import annotations

import functools
import io
import re
import shutil
import struct
import subprocess
import uuid
from pathlib import Path
from typing import Any

from PIL import Image, ImageChops, ImageDraw, ImageFont

from .encoder import _to_ffmpeg_path, _win_stage_base_wsl, resolve_ffmpeg_exe

_FPS_RE = re.compile(r"(\d+(?:\.\d+)?)\s*fps\b")
_DEJAVU_BOLD = Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf")

DEFAULT_TILE_WIDTH = 300
DEFAULT_DIFF_THRESHOLD = 16
DEFAULT_MAX_SHEET_FRAMES = 30


@functools.lru_cache(maxsize=4)
def _load_badge_font(size: int = 13) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    if _DEJAVU_BOLD.is_file():
        try:
            return ImageFont.truetype(str(_DEJAVU_BOLD), size=size)
        except Exception:
            pass
    return ImageFont.load_default(size=size)


def _resize_thumb(im: Image.Image, width: int = DEFAULT_TILE_WIDTH) -> Image.Image:
    rgb = im.convert("RGB")
    if rgb.width <= 0 or rgb.height <= 0:
        return rgb
    target_h = max(1, round(rgb.height * width / rgb.width))
    if rgb.width == width and rgb.height == target_h:
        return rgb
    return rgb.resize((width, target_h), Image.Resampling.BILINEAR)


def changed_pixel_ratio(
    thumb_a: Image.Image,
    thumb_b: Image.Image,
    threshold: int = DEFAULT_DIFF_THRESHOLD,
) -> float:
    """Return share of pixels (0.0..1.0) where any RGB channel differs by > *threshold*."""
    if thumb_a.size != thumb_b.size:
        thumb_b = thumb_b.resize(thumb_a.size, Image.Resampling.BILINEAR)
    diff = ImageChops.difference(thumb_a, thumb_b)
    r, g, b = diff.split()
    mx = ImageChops.lighter(ImageChops.lighter(r, g), b)
    hist = mx.histogram()
    changed = sum(hist[threshold + 1 :])
    total = max(1, thumb_a.width * thumb_a.height)
    return changed / total


def analyze_thumbnails(
    thumbs: list[Image.Image],
    timestamps_ms: list[int],
    *,
    direction: str = "one_way",
) -> tuple[list[float], dict[str, Any]]:
    """Compute frame-to-frame pixel diffs and objective motion flags across all frames."""
    n = len(thumbs)
    if n == 0:
        return [], {
            "frame_count": 0,
            "duration_ms": 0,
            "max_change_pct": 0.0,
            "mean_change_pct": 0.0,
            "start_end_diff_pct": 0.0,
            "spike_frames": [],
            "motion_flags": ["empty_capture"],
        }

    ratios = [0.0]
    for i in range(1, n):
        ratios.append(changed_pixel_ratio(thumbs[i - 1], thumbs[i]))

    max_change_pct = round(max(ratios) * 100.0, 2)
    mean_change_pct = round((sum(ratios[1:]) / max(1, n - 1)) * 100.0, 2)
    start_end_diff_pct = round(changed_pixel_ratio(thumbs[0], thumbs[-1]) * 100.0, 2)

    # Detect isolated A -> B -> A single-frame flashes only on dense captures.
    spike_frames: list[int] = []
    if n >= 8:
        for i in range(1, n - 1):
            if ratios[i] >= 0.03 and ratios[i + 1] >= 0.03:
                span_diff = changed_pixel_ratio(thumbs[i - 1], thumbs[i + 1])
                if span_diff <= 0.008 and span_diff < min(ratios[i], ratios[i + 1]) * 0.35:
                    spike_frames.append(i)

    motion_flags: list[str] = []
    if max_change_pct <= 0.02:
        motion_flags.append("zero_change")
    if direction == "two_way" and max_change_pct > 0.02 and start_end_diff_pct >= 1.5:
        motion_flags.append("two_way_not_restored")
    if spike_frames:
        motion_flags.append("single_frame_spike")

    dur_ms = int(timestamps_ms[-1] - timestamps_ms[0]) if len(timestamps_ms) >= 2 else 0
    return ratios, {
        "frame_count": n,
        "duration_ms": max(0, dur_ms),
        "max_change_pct": max_change_pct,
        "mean_change_pct": mean_change_pct,
        "start_end_diff_pct": start_end_diff_pct,
        "spike_frames": spike_frames,
        "motion_flags": motion_flags,
    }


def select_sheet_indices(
    ratios: list[float],
    spike_frames: list[int],
    *,
    max_frames: int = DEFAULT_MAX_SHEET_FRAMES,
) -> list[int]:
    """Select chronological frame indices preserving start, end, spikes, peaks, and uniform fill."""
    n = len(ratios)
    if n == 0:
        return []
    if max_frames <= 0 or n <= max_frames:
        return list(range(n))

    selected: set[int] = {0, n - 1}
    for sp in spike_frames:
        for cand in (sp - 1, sp, sp + 1):
            if 0 <= cand < n and len(selected) < max_frames:
                selected.add(cand)

    # Local change peaks so transition boundaries never disappear during uniform sampling.
    peaks = [
        i
        for i in range(1, n - 1)
        if ratios[i] > 0.0003 and ratios[i] >= ratios[i - 1] and ratios[i] >= ratios[i + 1]
    ]
    peaks.sort(key=lambda idx: ratios[idx], reverse=True)
    for pk in peaks[:12]:
        if len(selected) >= max_frames:
            break
        selected.add(pk)

    remaining = max_frames - len(selected)
    if remaining > 0:
        # Uniformly distribute remaining slots across the full frame span.
        step = (n - 1) / float(remaining + 1)
        for k in range(1, remaining + 1):
            anchor = min(n - 1, max(0, round(k * step)))
            if anchor not in selected:
                selected.add(anchor)
                continue
            # Probe nearest unused neighbor to preserve uniform spacing.
            for delta in range(1, n):
                if anchor + delta < n and (anchor + delta) not in selected:
                    selected.add(anchor + delta)
                    break
                if anchor - delta >= 0 and (anchor - delta) not in selected:
                    selected.add(anchor - delta)
                    break

    return sorted(selected)[:max_frames]


def render_contact_sheets(
    thumbs: list[Image.Image],
    timestamps_ms: list[int],
    ratios: list[float],
    spike_frames: list[int],
    out_dir: Path,
    *,
    max_frames: int = DEFAULT_MAX_SHEET_FRAMES,
    columns: int = 6,
    rows: int = 5,
    gap: int = 6,
) -> list[Path]:
    """Write `sheet-00.png` (and further pages if needed) styled like `FilmRecorder.write()`."""
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("sheet-*.png"):
        old.unlink()

    indices = select_sheet_indices(ratios, spike_frames, max_frames=max_frames)
    if not indices:
        return []

    font = _load_badge_font(13)
    spike_set = set(spike_frames)
    header_h = 22
    tiles: list[Image.Image] = []
    for idx in indices:
        src = thumbs[idx]
        # Place the timestamp/diff strip above the frame so top-edge window chrome (SC-W1/W4) is never occluded.
        tile = Image.new("RGB", (src.width, src.height + header_h), (12, 12, 12))
        tile.paste(src, (0, header_h))
        draw = ImageDraw.Draw(tile)
        tag = "!" if idx in spike_set else ""
        label = f"#{idx}{tag}  {timestamps_ms[idx]}ms  {ratios[idx] * 100.0:.1f}%"
        draw.text((6, 4), label, font=font, fill=(255, 255, 0))
        tiles.append(tile)

    tile_w, tile_h = tiles[0].size
    per_page = columns * rows
    written: list[Path] = []
    for page_idx, start in enumerate(range(0, len(tiles), per_page)):
        page_tiles = tiles[start : start + per_page]
        page_rows = (len(page_tiles) + columns - 1) // columns
        canvas_w = columns * tile_w + (columns + 1) * gap
        canvas_h = page_rows * tile_h + (page_rows + 1) * gap
        sheet = Image.new("RGB", (canvas_w, canvas_h), (24, 24, 24))
        for pos, tile in enumerate(page_tiles):
            dst_x = gap + (pos % columns) * (tile_w + gap)
            dst_y = gap + (pos // columns) * (tile_h + gap)
            sheet.paste(tile, (dst_x, dst_y))
        sheet_path = out_dir / f"sheet-{page_idx:02d}.png"
        sheet.save(sheet_path, format="PNG")
        written.append(sheet_path)
    return written


def build_storyboard_from_frame_bytes(
    frames: list[bytes],
    out_dir: Path,
    *,
    fps: float,
    direction: str = "one_way",
    max_sheet_frames: int = DEFAULT_MAX_SHEET_FRAMES,
    tile_width: int = DEFAULT_TILE_WIDTH,
) -> tuple[list[Path], dict[str, Any]]:
    """Build contact sheets + motion metrics directly from encoded in-memory PNG/BMP bytes."""
    thumbs: list[Image.Image] = []
    for raw in frames:
        with Image.open(io.BytesIO(raw)) as im:
            thumbs.append(_resize_thumb(im, width=tile_width))
    eff_fps = max(0.5, float(fps))
    timestamps = [round(i * 1000.0 / eff_fps) for i in range(len(thumbs))]
    ratios, metrics = analyze_thumbnails(thumbs, timestamps, direction=direction)
    metrics["sample_fps"] = round(eff_fps, 2)
    sheets = render_contact_sheets(
        thumbs,
        timestamps,
        ratios,
        metrics["spike_frames"],
        out_dir,
        max_frames=max_sheet_frames,
    )
    return sheets, metrics


def build_storyboard_from_frame_paths(
    frame_paths: list[Path],
    out_dir: Path,
    *,
    fps: float,
    direction: str = "one_way",
    max_sheet_frames: int = DEFAULT_MAX_SHEET_FRAMES,
    tile_width: int = DEFAULT_TILE_WIDTH,
) -> tuple[list[Path], dict[str, Any]]:
    """Build contact sheets + motion metrics from ordered PNG/BMP files on disk."""
    thumbs: list[Image.Image] = []
    for path in frame_paths:
        with Image.open(path) as im:
            thumbs.append(_resize_thumb(im, width=tile_width))
    eff_fps = max(0.5, float(fps))
    timestamps = [round(i * 1000.0 / eff_fps) for i in range(len(thumbs))]
    ratios, metrics = analyze_thumbnails(thumbs, timestamps, direction=direction)
    metrics["sample_fps"] = round(eff_fps, 2)
    sheets = render_contact_sheets(
        thumbs,
        timestamps,
        ratios,
        metrics["spike_frames"],
        out_dir,
        max_frames=max_sheet_frames,
    )
    return sheets, metrics


def _decode_gif_thumbs(
    gif_path: Path,
    *,
    tile_width: int = DEFAULT_TILE_WIDTH,
) -> tuple[list[Image.Image], list[int], float]:
    thumbs: list[Image.Image] = []
    timestamps: list[int] = []
    elapsed = 0
    with Image.open(gif_path) as im:
        n_frames = max(1, int(getattr(im, "n_frames", 1)))
        for idx in range(n_frames):
            im.seek(idx)
            thumbs.append(_resize_thumb(im, width=tile_width))
            timestamps.append(elapsed)
            dur = int(im.info.get("duration", 50) or 50)
            elapsed += max(10, dur)
    avg_fps = round((len(thumbs) * 1000.0 / max(1, elapsed)), 2) if elapsed > 0 else 10.0
    return thumbs, timestamps, avg_fps


def _probe_video_fps(ffmpeg: str, win_in: str, win_cwd: str | None) -> float:
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
    for line in (info.stderr or "").splitlines():
        if "Video:" in line:
            m = _FPS_RE.search(line)
            if m:
                val = float(m.group(1))
                if 0.5 <= val <= 240.0:
                    return val
    return 15.0


def _parse_bmp_stream(buf: bytes) -> list[Image.Image]:
    frames: list[Image.Image] = []
    pos = 0
    total = len(buf)
    while pos + 6 <= total and buf[pos : pos + 2] == b"BM":
        sz = struct.unpack_from("<I", buf, pos + 2)[0]
        if sz <= 14 or pos + sz > total:
            break
        with Image.open(io.BytesIO(buf[pos : pos + sz])) as im:
            frames.append(im.convert("RGB"))
        pos += sz
    return frames


def _decode_mp4_thumbs(
    mp4_path: Path,
    *,
    tile_width: int = DEFAULT_TILE_WIDTH,
    sample_fps: float = 15.0,
) -> tuple[list[Image.Image], list[int], float]:
    ffmpeg = resolve_ffmpeg_exe()
    stage_dir: Path | None = None
    target = mp4_path
    try:
        if ffmpeg.lower().endswith(".exe") and not str(mp4_path).startswith("/mnt/"):
            stage_dir = _win_stage_base_wsl() / uuid.uuid4().hex[:10]
            stage_dir.mkdir(parents=True, exist_ok=True)
            target = stage_dir / mp4_path.name
            shutil.copy2(mp4_path, target)

        win_in = _to_ffmpeg_path(target)
        win_cwd = "/mnt/c" if ffmpeg.lower().endswith(".exe") else None
        src_fps = _probe_video_fps(ffmpeg, win_in, win_cwd)
        eff_fps = max(1.0, min(src_fps, sample_fps))

        res = subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-i",
                win_in,
                "-vf",
                f"fps={eff_fps:.3f},scale={tile_width}:-2:flags=bilinear",
                "-f",
                "image2pipe",
                "-vcodec",
                "bmp",
                "-",
            ],
            cwd=win_cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=60.0,
        )
        if res.returncode != 0:
            raise RuntimeError(
                f"ffmpeg decode failed for {mp4_path.name}: "
                f"{res.stderr.decode('utf-8', errors='replace').strip()}"
            )
        thumbs = _parse_bmp_stream(res.stdout)
        timestamps = [round(i * 1000.0 / eff_fps) for i in range(len(thumbs))]
        return thumbs, timestamps, round(eff_fps, 2)
    finally:
        if stage_dir is not None:
            shutil.rmtree(stage_dir, ignore_errors=True)


def build_storyboard_from_media(
    media_path: Path,
    out_dir: Path,
    *,
    direction: str = "one_way",
    max_sheet_frames: int = DEFAULT_MAX_SHEET_FRAMES,
    tile_width: int = DEFAULT_TILE_WIDTH,
    mp4_sample_fps: float = 15.0,
) -> tuple[list[Path], dict[str, Any]]:
    """Decode an existing `.gif` or `.mp4` and write `sheet-NN.png` + motion metrics."""
    ext = media_path.suffix.lower()
    if ext == ".gif":
        thumbs, timestamps, eff_fps = _decode_gif_thumbs(media_path, tile_width=tile_width)
    elif ext in (".mp4", ".webm", ".mov"):
        thumbs, timestamps, eff_fps = _decode_mp4_thumbs(
            media_path,
            tile_width=tile_width,
            sample_fps=mp4_sample_fps,
        )
    else:
        raise ValueError(f"Unsupported media extension for storyboard: {media_path.suffix!r}")

    ratios, metrics = analyze_thumbnails(thumbs, timestamps, direction=direction)
    metrics["sample_fps"] = eff_fps
    sheets = render_contact_sheets(
        thumbs,
        timestamps,
        ratios,
        metrics["spike_frames"],
        out_dir,
        max_frames=max_sheet_frames,
    )
    return sheets, metrics


def extract_media_frames(
    media_path: Path,
    out_dir: Path,
    *,
    start_sec: float = 0.0,
    duration_sec: float | None = None,
    fps: float | None = None,
) -> list[Path]:
    """Extract full-resolution PNG frames (`f0000.png`...) for zoomed inspection."""
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("f*.png"):
        old.unlink()

    if media_path.suffix.lower() == ".gif":
        written: list[Path] = []
        with Image.open(media_path) as im:
            n_frames = max(1, int(getattr(im, "n_frames", 1)))
            elapsed = 0.0
            min_step = (1.0 / fps) if (fps is not None and fps > 0) else 0.0
            last_emitted_t: float | None = None
            out_idx = 0
            for idx in range(n_frames):
                im.seek(idx)
                t_sec = elapsed / 1000.0
                dur = max(10, int(im.info.get("duration", 50) or 50))
                elapsed += dur
                if t_sec < start_sec:
                    continue
                if duration_sec is not None and t_sec > start_sec + duration_sec:
                    break
                if min_step > 0 and last_emitted_t is not None and (t_sec - last_emitted_t) < min_step - 1e-6:
                    continue
                dst = out_dir / f"f{out_idx:04d}.png"
                im.convert("RGB").save(dst, format="PNG")
                written.append(dst)
                last_emitted_t = t_sec
                out_idx += 1
        return written

    ffmpeg = resolve_ffmpeg_exe()
    stage_dir = _win_stage_base_wsl() / uuid.uuid4().hex[:10]
    stage_dir.mkdir(parents=True, exist_ok=True)
    try:
        target = media_path
        if ffmpeg.lower().endswith(".exe") and not str(media_path).startswith("/mnt/"):
            target = stage_dir / media_path.name
            shutil.copy2(media_path, target)
        win_in = _to_ffmpeg_path(target)
        win_cwd = "/mnt/c" if ffmpeg.lower().endswith(".exe") else None
        out_pattern = _to_ffmpeg_path(stage_dir / "f%04d.png")

        cmd = [ffmpeg, "-y", "-v", "error"]
        if start_sec > 0:
            cmd.extend(["-ss", f"{start_sec:.3f}"])
        cmd.extend(["-i", win_in])
        if duration_sec is not None and duration_sec > 0:
            cmd.extend(["-t", f"{duration_sec:.3f}"])
        if fps is not None and fps > 0:
            cmd.extend(["-vf", f"fps={fps:.3f}"])
        cmd.extend(["-start_number", "0", out_pattern])

        res = subprocess.run(
            cmd,
            cwd=win_cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60.0,
        )
        if res.returncode != 0:
            raise RuntimeError(f"ffmpeg frame extract failed: {res.stderr.strip()}")

        written = []
        for png in sorted(stage_dir.glob("f*.png")):
            dst = out_dir / png.name
            shutil.copy2(png, dst)
            written.append(dst)
        return written
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


def attach_sheets_to_run(
    run_dir: Path,
    manifest: dict[str, Any],
    *,
    force: bool = False,
    max_sheet_frames: int = DEFAULT_MAX_SHEET_FRAMES,
    catalog_ids: set[str] | None = None,
    platforms: set[str] | None = None,
) -> dict[str, Any]:
    """Generate/refresh `sheets/` & `motion_metrics` on an existing run's manifest records."""
    processed = 0
    skipped = 0
    errors: list[str] = []

    for rec in manifest.get("records", []):
        if not isinstance(rec, dict):
            continue
        if rec.get("status") not in ("ok", "recorded_with_anomaly"):
            continue
        cid = str(rec.get("catalog_id") or "")
        plat = str(rec.get("platform") or "")
        rel = rec.get("artifact_relpath")
        if not cid or not plat or not isinstance(rel, str) or not rel:
            continue
        if catalog_ids is not None and cid not in catalog_ids:
            continue
        if platforms is not None and plat not in platforms:
            continue

        existing_sheets = rec.get("sheet_relpaths")
        if (
            not force
            and isinstance(existing_sheets, list)
            and existing_sheets
            and isinstance(rec.get("motion_metrics"), dict)
            and all((run_dir / str(s)).is_file() for s in existing_sheets)
        ):
            skipped += 1
            continue

        media_path = (run_dir / rel).resolve()
        if not media_path.is_relative_to(run_dir.resolve()) or not media_path.is_file():
            errors.append(f"{plat}/{cid}: missing media {rel}")
            continue

        sheet_dir = run_dir / "sheets" / plat / cid
        try:
            sheets, metrics = build_storyboard_from_media(
                media_path,
                sheet_dir,
                direction=str(rec.get("direction") or "one_way"),
                max_sheet_frames=max_sheet_frames,
            )
            rec["sheet_relpaths"] = [s.relative_to(run_dir).as_posix() for s in sheets]
            rec["motion_metrics"] = metrics
            processed += 1
        except Exception as exc:
            errors.append(f"{plat}/{cid}: {exc}")

    return {"processed": processed, "skipped": skipped, "errors": errors}
