"""Apple (iOS & macOS) WidgetTester simulation dynamic recorder."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from typing import Any

from .common import REPO_ROOT, load_catalog
from .encoder import encode_frames_to_media
from .manifest import APPLE_REQUIRED_BLIND_SPOTS, storyboard_record_fields

SIM_TARGETS = ("iphone", "ipad", "macos")


def run_apple_sim_recording(
    run_dir: Path,
    *,
    platforms: tuple[str, ...] = SIM_TARGETS,
    catalog_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    """Run `test/review/films_catalog_sim.dart` under 6G memory cap and encode `.sim.*` artifacts."""
    items = load_catalog()
    if catalog_ids is not None:
        items = [it for it in items if it["id"] in catalog_ids]

    # Ensure review fonts exist (requires flutter on PATH for MaterialIcons)
    review_out = Path(os.environ.get("PARFAIT_REVIEW_OUT", str(Path.home() / "parfait-ux4-review")))
    base_env = os.environ.copy()
    base_env["PATH"] = f"/opt/flutter-3.47.9/bin:/usr/bin:/bin:{base_env.get('PATH', '')}"
    fonts_res = subprocess.run(
        ["python3", str(REPO_ROOT / "tool" / "fetch_review_fonts.py"), str(review_out / "fonts")],
        cwd=str(REPO_ROOT),
        env=base_env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60.0,
    )
    if fonts_res.returncode != 0:
        raise RuntimeError(
            f"fetch_review_fonts.py failed (exit={fonts_res.returncode}):\n"
            f"{fonts_res.stdout}\n{fonts_res.stderr}"
        )

    records: list[dict[str, Any]] = []
    for plat in platforms:
        if plat not in SIM_TARGETS:
            raise ValueError(f"Unsupported Apple sim target: {plat!r}")

        required_items: list[dict[str, Any]] = []
        for it in items:
            rule = str((it.get("platforms") or {}).get(plat, "not_applicable:missing"))
            if rule == "required":
                required_items.append(it)
            else:
                records.append({
                    "catalog_id": it["id"],
                    "module": it.get("module"),
                    "route_template": it.get("route_template"),
                    "shell_layer": it.get("shell_layer"),
                    "audit_candidate": it.get("audit_candidate"),
                    "direction": it.get("direction"),
                    "platform": plat,
                    "evidence_kind": "not_applicable",
                    "capture_mode": "not_applicable",
                    "status": "not_applicable",
                    "artifact_relpath": None,
                    "decode_verified": False,
                    "diagnostics": {"reason": rule},
                    "known_blind_spots": [],
                })

        if not required_items:
            continue

        sim_run_stamp = f"catalog-sim-{plat}-{uuid.uuid4().hex[:8]}"
        env = os.environ.copy()
        env["PATH"] = f"/opt/flutter-3.47.9/bin:/usr/bin:/bin:{env.get('PATH', '')}"
        env["PARFAIT_REVIEW_OUT"] = str(review_out)
        env["PARFAIT_REVIEW_RUN"] = sim_run_stamp
        env["PARFAIT_REVIEW_DEVICE"] = plat
        if catalog_ids:
            env["PARFAIT_CATALOG_ID"] = ",".join(sorted(catalog_ids))

        # Run inside systemd-run 6G memory cap per repo rules
        cmd = [
            "systemd-run",
            "--scope",
            "--quiet",
            "-p",
            "MemoryMax=6G",
            "-p",
            "MemorySwapMax=0",
            "/opt/flutter-3.47.9/bin/flutter",
            "test",
            "--no-pub",
            "--concurrency=2",
            "-r",
            "failures-only",
            "test/review/films_catalog_sim.dart",
        ]
        res = subprocess.run(
            cmd,
            cwd=str(REPO_ROOT),
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=900.0,
        )
        # Do not silently pass if OOM killed or Did not complete
        combined = f"{res.stdout}\n{res.stderr}"
        if "did not complete" in combined or "No tests ran." in combined:
            raise RuntimeError(f"Apple sim test suite incomplete on {plat}:\n{combined[-1500:]}")

        dev_dir = review_out / "runs" / sim_run_stamp / plat
        try:
            for it in required_items:
                cid = it["id"]
                film_dir = dev_dir / "films" / cid
                png_paths = sorted(film_dir.glob("f*.png")) if film_dir.is_dir() else []
                sim_meta_path = film_dir / "sim_result.json"
                sim_meta: dict[str, Any] = (
                    json.loads(sim_meta_path.read_text(encoding="utf-8"))
                    if sim_meta_path.is_file()
                    else {}
                )
                anomaly = sim_meta.get("anomaly")

                if not png_paths:
                    records.append({
                        "catalog_id": cid,
                        "module": it.get("module"),
                        "route_template": it.get("route_template"),
                        "shell_layer": it.get("shell_layer"),
                        "audit_candidate": it.get("audit_candidate"),
                        "direction": it.get("direction"),
                        "platform": plat,
                        "evidence_kind": "widget_tester_simulation",
                        "capture_mode": "flutter_test_film_recorder",
                        "status": "failed",
                        "artifact_relpath": None,
                        "decode_verified": False,
                        "route_before": sim_meta.get("route_before", ""),
                        "route_after": sim_meta.get("route_after", ""),
                        "diagnostics": {
                            "error": anomaly or f"No PNG frames rendered (exit={res.returncode})",
                        },
                        "known_blind_spots": list(APPLE_REQUIRED_BLIND_SPOTS),
                    })
                    continue

                frames = [p.read_bytes() for p in png_paths]
                fmt = str(it.get("format", "gif"))
                rel = f"{plat}/{cid}.sim.{fmt}"
                out_path = run_dir / rel
                sheet_dir = run_dir / "sheets" / plat / cid
                art = encode_frames_to_media(
                    frames,
                    out_path,
                    fmt,
                    fps=20,
                    sheet_dir=sheet_dir,
                    direction=str(it.get("direction") or "one_way"),
                )
                st = "ok"
                if not art.decode_verified:
                    st = "failed"
                elif anomaly:
                    st = "recorded_with_anomaly"

                records.append({
                    "catalog_id": cid,
                    "module": it.get("module"),
                    "route_template": it.get("route_template"),
                    "shell_layer": it.get("shell_layer"),
                    "audit_candidate": it.get("audit_candidate"),
                    "direction": it.get("direction"),
                    "platform": plat,
                    "evidence_kind": "widget_tester_simulation",
                    "capture_mode": "flutter_test_film_recorder",
                    "status": st,
                    "artifact_relpath": rel,
                    "format": fmt,
                    "width": art.width,
                    "height": art.height,
                    "bytes": art.bytes,
                    "duration_ms": art.duration_ms,
                    "decode_verified": art.decode_verified,
                    "route_before": sim_meta.get("route_before", ""),
                    "route_after": sim_meta.get("route_after", ""),
                    "diagnostics": {
                        "sim_device": sim_meta.get("device", plat),
                        "frame_count": len(frames),
                        **({"anomaly": anomaly} if anomaly else {}),
                        **({"decode_error": art.decode_error} if art.decode_error else {}),
                    },
                    "known_blind_spots": list(APPLE_REQUIRED_BLIND_SPOTS),
                    **storyboard_record_fields(art.sheet_paths, art.motion_metrics, run_dir),
                })
        finally:
            run_root = review_out / "runs" / sim_run_stamp
            if run_root.exists():
                shutil.rmtree(run_root, ignore_errors=True)

    return records
