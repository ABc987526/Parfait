#!/usr/bin/env python3
"""Unified 5-platform catalog recording orchestrator & manifest verifier."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dev_workbench.recorders.android_recorder import run_android_recording
from dev_workbench.recorders.apple_sim_recorder import SIM_TARGETS, run_apple_sim_recording
from dev_workbench.recorders.common import ManagedWorkbenchServer, REPO_ROOT
from dev_workbench.recorders.linux_recorder import run_linux_recording
from dev_workbench.recorders.manifest import (
    ALL_PLATFORMS,
    default_artifacts_root,
    git_head_sha,
    resolve_run_dir,
    save_manifest_and_reports,
    update_latest_pointer,
    validate_manifest_data,
)
from dev_workbench.recorders.storyboard import attach_sheets_to_run, extract_media_frames
from dev_workbench.recorders.windows_recorder import run_windows_recording
from dev_workbench.verify_catalog import verify_catalog


def _verify_existing_manifest(run_dir: Path) -> int:
    manifest_file = run_dir / "manifest.json"
    if not manifest_file.is_file():
        print(f"ERROR: manifest.json not found in {run_dir}", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    ok, errors = validate_manifest_data(manifest, run_dir, require_files=True)
    if not ok:
        print(f"Manifest validation FAILED ({len(errors)} error(s)):", file=sys.stderr)
        for err in errors[:30]:
            print(f"  - {err}", file=sys.stderr)
        return 1
    recs = manifest.get("records", [])
    by_plat: dict[str, int] = {}
    for r in recs:
        p = str(r.get("platform"))
        by_plat[p] = by_plat.get(p, 0) + 1
    print(f"Manifest OK ({run_dir}): {len(recs)} records across {by_plat}")
    return 0


def _build_sheets_for_run(
    run_dir: Path,
    *,
    force: bool = False,
    max_sheet_frames: int = 30,
    catalog_ids: set[str] | None = None,
    platforms: set[str] | None = None,
) -> int:
    manifest_file = run_dir / "manifest.json"
    if not manifest_file.is_file():
        print(f"ERROR: manifest.json not found in {run_dir}", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    summary = attach_sheets_to_run(
        run_dir,
        manifest,
        force=force,
        max_sheet_frames=max_sheet_frames,
        catalog_ids=catalog_ids,
        platforms=platforms,
    )
    m_path, r_json, r_md = save_manifest_and_reports(run_dir, manifest)
    print(
        f"[sheets] processed={summary['processed']} skipped={summary['skipped']} "
        f"errors={len(summary['errors'])} -> {m_path}, {r_json}, {r_md}",
        flush=True,
    )
    for err in summary["errors"][:20]:
        print(f"  [sheet-err] {err}", file=sys.stderr)
    if summary["errors"]:
        return 1
    return _verify_existing_manifest(run_dir)


def _extract_frames_for_target(
    run_dir: Path,
    target: str,
    *,
    start_sec: float = 0.0,
    duration_sec: float | None = None,
) -> int:
    if "/" not in target:
        print("ERROR: --extract-frames expects <platform>/<catalog_id>", file=sys.stderr)
        return 2
    plat, cid = target.split("/", 1)
    manifest_file = run_dir / "manifest.json"
    if not manifest_file.is_file():
        print(f"ERROR: manifest.json not found in {run_dir}", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    rec = next(
        (r for r in manifest.get("records", []) if r.get("platform") == plat and r.get("catalog_id") == cid),
        None,
    )
    if rec is None or not rec.get("artifact_relpath"):
        print(f"ERROR: no artifact found for {plat}/{cid} in {manifest_file}", file=sys.stderr)
        return 1
    media_path = run_dir / str(rec["artifact_relpath"])
    out_dir = run_dir / "frames" / plat / cid
    written = extract_media_frames(
        media_path,
        out_dir,
        start_sec=start_sec,
        duration_sec=duration_sec,
    )
    print(f"[frames] extracted {len(written)} full-res PNGs into {out_dir}", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Parfait 5-Platform Dynamic Catalog Recorder")
    parser.add_argument(
        "--platforms",
        default="windows,android_avd,linux,iphone,ipad,macos",
        help="Comma-separated platforms to record",
    )
    parser.add_argument("--all-default", action="store_true", help="Record all 6 presets across real OS + Apple sims")
    parser.add_argument("--with-windows-foreground-shell", action="store_true", help="Include 3 opt-in Default desktop Win32 shell recordings")
    parser.add_argument("--skip-android-rebuild", action="store_true", help="Reuse already built Android .dev debug APK")
    parser.add_argument("--catalog-ids", default="", help="Optional comma-separated subset of catalog IDs")
    parser.add_argument("--run-id", default="", help="Existing or new run ID under artifacts root")
    parser.add_argument("--artifacts-root", type=Path, default=None)
    parser.add_argument("--verify-manifest", action="store_true", help="Verify manifest.json + artifact files and exit")
    parser.add_argument("--build-sheets", action="store_true", help="Generate UX4-style contact sheets & motion metrics for an existing run")
    parser.add_argument("--force-sheets", action="store_true", help="Force rebuild sheets even if already present")
    parser.add_argument("--max-sheet-frames", type=int, default=30, help="Max frames per contact sheet (0 = all frames)")
    parser.add_argument("--extract-frames", default="", help="Extract full-res frames for <platform>/<catalog_id>")
    parser.add_argument("--start-sec", type=float, default=0.0, help="Optional start offset for --extract-frames")
    parser.add_argument("--duration-sec", type=float, default=None, help="Optional duration for --extract-frames")
    parser.add_argument("--port", type=int, default=18490, help="Loopback server port (default 18490 for AVD 10.0.2.2)")
    args = parser.parse_args(argv)

    art_root = (args.artifacts_root or default_artifacts_root()).resolve()
    if args.verify_manifest:
        run_dir = resolve_run_dir(art_root, args.run_id or None)
        return _verify_existing_manifest(run_dir)
    if args.extract_frames:
        run_dir = resolve_run_dir(art_root, args.run_id or None)
        return _extract_frames_for_target(
            run_dir,
            args.extract_frames.strip(),
            start_sec=args.start_sec,
            duration_sec=args.duration_sec,
        )
    if args.build_sheets:
        run_dir = resolve_run_dir(art_root, args.run_id or None)
        id_filter = {s.strip() for s in args.catalog_ids.split(",") if s.strip()} if args.catalog_ids else None
        plat_filter = (
            {p.strip() for p in args.platforms.split(",") if p.strip()}
            if args.platforms != "windows,android_avd,linux,iphone,ipad,macos"
            else None
        )
        return _build_sheets_for_run(
            run_dir,
            force=args.force_sheets,
            max_sheet_frames=args.max_sheet_frames,
            catalog_ids=id_filter,
            platforms=plat_filter,
        )

    ok_cat, errs_cat, summary_cat = verify_catalog()
    if not ok_cat:
        print("Catalog verification failed before recording:", file=sys.stderr)
        for e in errs_cat:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(
        f"[catalog] Verified {summary_cat['canonical_routes']} routes -> "
        f"{summary_cat['catalog_items']} catalog items.",
        flush=True,
    )

    run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S")
    run_dir = art_root / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    selected_platforms = list(ALL_PLATFORMS) if args.all_default else [
        p.strip() for p in args.platforms.split(",") if p.strip()
    ]
    for p in selected_platforms:
        if p not in ALL_PLATFORMS:
            parser.error(f"Unknown platform {p!r}; valid={ALL_PLATFORMS}")

    id_filter = {s.strip() for s in args.catalog_ids.split(",") if s.strip()} if args.catalog_ids else None

    # Merge with existing manifest if updating an existing run_id selectively
    existing_map: dict[tuple[str, str], dict[str, Any]] = {}
    manifest_file = run_dir / "manifest.json"
    if manifest_file.is_file():
        old = json.loads(manifest_file.read_text(encoding="utf-8"))
        for rec in old.get("records", []):
            existing_map[(str(rec.get("catalog_id")), str(rec.get("platform")))] = rec

    all_new: list[dict[str, Any]] = []
    real_targets = [p for p in selected_platforms if p not in SIM_TARGETS]
    apple_targets = tuple(p for p in selected_platforms if p in SIM_TARGETS)

    if real_targets:
        need_avd = "android_avd" in real_targets
        with ManagedWorkbenchServer(
            port=args.port,
            artifacts_dir=run_dir,
            allow_emulator_host=need_avd,
        ) as srv:
            wb = srv.client()
            if "windows" in real_targets:
                print("[windows] Starting real Win32 OS dynamic recording...", flush=True)
                all_new.extend(
                    run_windows_recording(
                        wb,
                        srv.url,
                        srv.token,
                        run_dir,
                        with_foreground_shell=args.with_windows_foreground_shell,
                        catalog_ids=id_filter,
                    )
                )
            if "linux" in real_targets:
                print("[linux] Starting real Xvfb GTK dynamic recording...", flush=True)
                all_new.extend(
                    run_linux_recording(
                        wb,
                        srv.url,
                        srv.token,
                        run_dir,
                        catalog_ids=id_filter,
                    )
                )
            if "android_avd" in real_targets:
                print("[android_avd] Starting real KVM AVD dynamic recording...", flush=True)
                all_new.extend(
                    run_android_recording(
                        wb,
                        srv.bound_port,
                        srv.token,
                        run_dir,
                        rebuild_apk=not args.skip_android_rebuild,
                        catalog_ids=id_filter,
                    )
                )

    if apple_targets:
        print(f"[apple-sim] Starting WidgetTester simulation for {apple_targets}...", flush=True)
        all_new.extend(
            run_apple_sim_recording(
                run_dir,
                platforms=apple_targets,
                catalog_ids=id_filter,
            )
        )

    for rec in all_new:
        existing_map[(str(rec["catalog_id"]), str(rec["platform"]))] = rec

    merged_records = sorted(
        existing_map.values(),
        key=lambda r: (str(r.get("platform")), str(r.get("catalog_id"))),
    )
    manifest = {
        "schema_version": 1,
        "run_id": run_id,
        "git_head": git_head_sha(REPO_ROOT),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "records": merged_records,
    }
    m_path, r_json, r_md = save_manifest_and_reports(run_dir, manifest)
    update_latest_pointer(art_root, run_dir)
    print(f"[done] Wrote {m_path}, {r_json}, {r_md}", flush=True)
    return _verify_existing_manifest(run_dir)


if __name__ == "__main__":
    raise SystemExit(main())
