"""Artifact manifest schema, strict anti-spoofing validator, and coverage reports."""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

APPLE_SIM_PLATFORMS = frozenset({"iphone", "ipad", "macos"})
REAL_OS_PLATFORMS = frozenset({"windows", "android_avd", "linux"})
ALL_PLATFORMS = ("windows", "android_avd", "linux", "iphone", "ipad", "macos")

VALID_EVIDENCE_KINDS = frozenset({
    "native_os_recording",
    "widget_tester_simulation",
    "not_applicable",
    "skipped",
})

VALID_CAPTURE_MODES = frozenset({
    "win32_hidden_desktop",
    "win32_foreground_sendinput",
    "adb_screenrecord",
    "x11_window_capture",
    "flutter_test_film_recorder",
    "skipped_foreground_only",
    "not_applicable",
})

VALID_STATUSES = frozenset({
    "ok",
    "recorded_with_anomaly",
    "failed",
    "skipped_foreground_only",
    "not_applicable",
})

APPLE_REQUIRED_BLIND_SPOTS = [
    "os_native_window_border",
    "macos_system_menubar",
    "native_platform_webview",
]


def default_artifacts_root() -> Path:
    env_dir = os.environ.get("PARFAIT_WORKBENCH_ARTIFACTS", "").strip()
    if env_dir:
        return Path(env_dir).expanduser().resolve()
    return (Path.home() / ".local" / "share" / "parfait-dev-workbench" / "artifacts").resolve()


def resolve_run_dir(root: Path | None = None, run_id: str | None = None) -> Path:
    base = (root or default_artifacts_root()).resolve()
    if run_id:
        run_dir = base / "runs" / run_id
    else:
        latest = base / "latest"
        if latest.exists():
            run_dir = latest.resolve()
        else:
            stamp = time.strftime("%Y%m%d-%H%M%S")
            run_dir = base / "runs" / stamp
    return run_dir


def update_latest_pointer(root: Path, run_dir: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    latest = root / "latest"
    if latest.is_symlink() or latest.is_file():
        latest.unlink()
    elif latest.is_dir():
        return
    try:
        latest.symlink_to(run_dir)
    except OSError:
        pass


def git_head_sha(repo_root: Path) -> str:
    try:
        res = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(repo_root),
            capture_output=True,
            text=True,
            timeout=5.0,
            check=True,
        )
        return res.stdout.strip()
    except Exception:
        return "unknown"


def validate_manifest_data(
    manifest: Any,
    run_dir: Path | None = None,
    *,
    require_files: bool = True,
) -> tuple[bool, list[str]]:
    errors: list[str] = []
    if not isinstance(manifest, dict):
        return False, ["manifest must be a JSON object"]
    records = manifest.get("records")
    if not isinstance(records, list):
        return False, ["manifest.records must be a list"]

    seen_pairs: set[tuple[str, str]] = set()
    for idx, rec in enumerate(records):
        if not isinstance(rec, dict):
            errors.append(f"records[{idx}] must be an object")
            continue
        cid = rec.get("catalog_id")
        plat = rec.get("platform")
        ek = rec.get("evidence_kind")
        cm = rec.get("capture_mode")
        st = rec.get("status")
        if not isinstance(cid, str) or not cid:
            errors.append(f"records[{idx}] missing catalog_id")
            continue
        if plat not in ALL_PLATFORMS:
            errors.append(f"{cid}: invalid platform {plat!r}")
            continue
        if (cid, plat) in seen_pairs:
            errors.append(f"Duplicate manifest entry for ({cid}, {plat})")
        seen_pairs.add((cid, plat))

        if ek not in VALID_EVIDENCE_KINDS:
            errors.append(f"{cid}/{plat}: invalid evidence_kind {ek!r}")
        if cm not in VALID_CAPTURE_MODES:
            errors.append(f"{cid}/{plat}: invalid capture_mode {cm!r}")
        if st not in VALID_STATUSES:
            errors.append(f"{cid}/{plat}: invalid status {st!r}")

        if st == "not_applicable":
            if ek != "not_applicable" or cm != "not_applicable":
                errors.append(f"{cid}/{plat}: not_applicable status must set evidence_kind & capture_mode to not_applicable")
            continue

        if st == "skipped_foreground_only":
            if plat != "windows" or ek != "skipped" or cm != "skipped_foreground_only":
                errors.append(f"{cid}/{plat}: invalid skipped_foreground_only metadata")
            continue

        # Enforce strict real-OS vs simulation separation
        if plat in APPLE_SIM_PLATFORMS:
            if ek != "widget_tester_simulation":
                errors.append(
                    f"{cid}/{plat}: Apple platform MUST set evidence_kind='widget_tester_simulation', got {ek!r}"
                )
            if cm != "flutter_test_film_recorder":
                errors.append(
                    f"{cid}/{plat}: Apple platform MUST set capture_mode='flutter_test_film_recorder', got {cm!r}"
                )
            spots = rec.get("known_blind_spots")
            if not isinstance(spots, list) or not spots:
                errors.append(f"{cid}/{plat}: widget_tester_simulation requires non-empty known_blind_spots")
        elif plat in REAL_OS_PLATFORMS:
            if ek != "native_os_recording":
                errors.append(
                    f"{cid}/{plat}: real OS target MUST set evidence_kind='native_os_recording', got {ek!r}"
                )

        if st in ("ok", "recorded_with_anomaly"):
            rel = rec.get("artifact_relpath")
            if not isinstance(rel, str) or not rel:
                errors.append(f"{cid}/{plat}: status={st} requires non-empty artifact_relpath")
            else:
                if plat in APPLE_SIM_PLATFORMS and not (rel.endswith(".sim.mp4") or rel.endswith(".sim.gif")):
                    errors.append(
                        f"{cid}/{plat}: simulated artifact filename MUST end with '.sim.mp4' or '.sim.gif', got {rel!r}"
                    )
                if require_files and run_dir is not None:
                    fpath = (run_dir / rel).resolve()
                    if not fpath.is_relative_to(run_dir.resolve()):
                        errors.append(f"{cid}/{plat}: artifact path escapes run_dir: {rel}")
                    elif not fpath.is_file() or fpath.stat().st_size <= 0:
                        errors.append(f"{cid}/{plat}: artifact missing or empty: {fpath}")
            if not rec.get("decode_verified"):
                errors.append(f"{cid}/{plat}: artifact decode_verified is False")
            sheet_rels = rec.get("sheet_relpaths")
            if sheet_rels is not None:
                if not isinstance(sheet_rels, list):
                    errors.append(f"{cid}/{plat}: sheet_relpaths must be a list")
                elif require_files and run_dir is not None:
                    for srel in sheet_rels:
                        if not isinstance(srel, str) or not srel:
                            errors.append(f"{cid}/{plat}: invalid sheet_relpath {srel!r}")
                            continue
                        spath = (run_dir / srel).resolve()
                        if not spath.is_relative_to(run_dir.resolve()):
                            errors.append(f"{cid}/{plat}: sheet path escapes run_dir: {srel}")
                        elif not spath.is_file() or spath.stat().st_size <= 0:
                            errors.append(f"{cid}/{plat}: sheet missing or empty: {spath}")

    return len(errors) == 0, errors


def storyboard_record_fields(
    sheet_paths: tuple[Path, ...] | list[Path],
    motion_metrics: dict[str, Any] | None,
    run_dir: Path,
) -> dict[str, Any]:
    """Build optional `sheet_relpaths` and `motion_metrics` manifest fields."""
    fields: dict[str, Any] = {}
    if sheet_paths:
        fields["sheet_relpaths"] = [p.relative_to(run_dir).as_posix() for p in sheet_paths]
    if motion_metrics:
        fields["motion_metrics"] = motion_metrics
    return fields


def build_coverage_report(manifest: dict[str, Any]) -> dict[str, Any]:
    records = manifest.get("records", [])
    per_platform: dict[str, dict[str, int]] = {}
    anomalies: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    motion_anomalies: list[dict[str, Any]] = []
    audit_findings: dict[str, list[dict[str, Any]]] = {}

    for rec in records:
        plat = str(rec.get("platform", "unknown"))
        st = str(rec.get("status", "unknown"))
        bucket = per_platform.setdefault(
            plat,
            {
                "ok": 0,
                "recorded_with_anomaly": 0,
                "failed": 0,
                "skipped_foreground_only": 0,
                "not_applicable": 0,
                "total": 0,
            },
        )
        bucket[st] = bucket.get(st, 0) + 1
        bucket["total"] += 1

        if st == "recorded_with_anomaly":
            anomalies.append({
                "catalog_id": rec.get("catalog_id"),
                "platform": plat,
                "capture_mode": rec.get("capture_mode"),
                "artifact_relpath": rec.get("artifact_relpath"),
                "diagnostics": rec.get("diagnostics", {}),
            })
        elif st == "failed":
            failures.append({
                "catalog_id": rec.get("catalog_id"),
                "platform": plat,
                "capture_mode": rec.get("capture_mode"),
                "diagnostics": rec.get("diagnostics", {}),
            })

        mm = rec.get("motion_metrics")
        if isinstance(mm, dict) and mm.get("motion_flags"):
            motion_anomalies.append({
                "catalog_id": rec.get("catalog_id"),
                "platform": plat,
                "direction": rec.get("direction"),
                "artifact_relpath": rec.get("artifact_relpath"),
                "sheet_relpaths": rec.get("sheet_relpaths", []),
                "motion_flags": mm.get("motion_flags", []),
                "max_change_pct": mm.get("max_change_pct"),
                "start_end_diff_pct": mm.get("start_end_diff_pct"),
            })

        cand = rec.get("audit_candidate")
        if cand:
            audit_findings.setdefault(str(cand), []).append({
                "catalog_id": rec.get("catalog_id"),
                "platform": plat,
                "evidence_kind": rec.get("evidence_kind"),
                "capture_mode": rec.get("capture_mode"),
                "status": st,
                "artifact_relpath": rec.get("artifact_relpath"),
                "diagnostics": rec.get("diagnostics", {}),
            })

    return {
        "schema_version": 1,
        "run_id": manifest.get("run_id"),
        "git_head": manifest.get("git_head"),
        "generated_at": manifest.get("generated_at"),
        "per_platform": per_platform,
        "anomalies_count": len(anomalies),
        "failures_count": len(failures),
        "motion_anomalies_count": len(motion_anomalies),
        "anomalies": anomalies,
        "failures": failures,
        "motion_anomalies": motion_anomalies,
        "audit_candidates": audit_findings,
    }


def render_coverage_markdown(report: dict[str, Any]) -> str:
    lines = [
        f"# 5-Platform Dynamic Coverage & Gap Report ({report.get('run_id', '-')})",
        "",
        f"- Git HEAD: `{report.get('git_head', 'unknown')}`",
        f"- Generated At: `{report.get('generated_at', '')}`",
        f"- Recorded Anomalies: **{report.get('anomalies_count', 0)}**",
        f"- Hard Failures: **{report.get('failures_count', 0)}**",
        f"- Motion Review Signals: **{report.get('motion_anomalies_count', 0)}**",
        "",
        "## Platform Summary",
        "",
        "| Platform | Evidence Kind | OK | Anomaly | Failed | Opt-in Skipped | N/A | Total |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for plat in ALL_PLATFORMS:
        b = report.get("per_platform", {}).get(plat)
        if not b:
            continue
        kind = "widget_tester_simulation" if plat in APPLE_SIM_PLATFORMS else "native_os_recording"
        lines.append(
            f"| `{plat}` | `{kind}` | {b.get('ok', 0)} | {b.get('recorded_with_anomaly', 0)} | "
            f"{b.get('failed', 0)} | {b.get('skipped_foreground_only', 0)} | "
            f"{b.get('not_applicable', 0)} | {b.get('total', 0)} |"
        )

    lines.extend(["", "## Static Audit Candidates (`SC-W1 ~ SC-W5`)", ""])
    for cand, rows in sorted((report.get("audit_candidates") or {}).items()):
        lines.append(f"### {cand}")
        for row in rows:
            lines.append(
                f"- `{row['platform']}` / `{row['catalog_id']}` -> status=`{row['status']}` "
                f"mode=`{row['capture_mode']}` artifact=`{row.get('artifact_relpath')}` "
                f"diag=`{json.dumps(row.get('diagnostics', {}), ensure_ascii=False)}`"
            )
        lines.append("")

    if report.get("anomalies"):
        lines.extend(["## Recorded Anomalies", ""])
        for a in report["anomalies"]:
            lines.append(
                f"- `{a['platform']}` `{a['catalog_id']}` ({a['artifact_relpath']}): "
                f"`{json.dumps(a['diagnostics'], ensure_ascii=False)}`"
            )
        lines.append("")

    if report.get("failures"):
        lines.extend(["## Failures", ""])
        for f in report["failures"]:
            lines.append(
                f"- `{f['platform']}` `{f['catalog_id']}`: "
                f"`{json.dumps(f['diagnostics'], ensure_ascii=False)}`"
            )
        lines.append("")

    if report.get("motion_anomalies"):
        lines.extend(["## Motion Review Signals", ""])
        for m in report["motion_anomalies"]:
            sheets = m.get("sheet_relpaths") or []
            sheet_ref = sheets[0] if sheets else "-"
            lines.append(
                f"- `{m['platform']}` `{m['catalog_id']}` (`{m.get('direction', '-')}`) "
                f"flags=`{','.join(m.get('motion_flags', []))}` "
                f"max=`{m.get('max_change_pct')}%` end=`{m.get('start_end_diff_pct')}%` "
                f"sheet=`{sheet_ref}`"
            )
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def save_manifest_and_reports(run_dir: Path, manifest: dict[str, Any]) -> tuple[Path, Path, Path]:
    run_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = run_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report = build_coverage_report(manifest)
    report_json = run_dir / "coverage_report.json"
    report_json.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report_md = run_dir / "coverage_report.md"
    report_md.write_text(render_coverage_markdown(report), encoding="utf-8")
    return manifest_path, report_json, report_md
