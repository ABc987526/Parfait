#!/usr/bin/env python3
"""Splits the Flutter test suite into CI shards of whole files.

`flutter test --total-shards` splits the cases inside every file, so each
shard compiles and loads nearly the whole suite. Here each shard gets
whole files instead and compiles only those. Files are balanced greedily
by their recorded duration (tool/test_durations.json); a file without a
record weighs the median.

Usage:
  python3 tool/test_shards.py --shards N --index I  print shard I's files
  python3 tool/test_shards.py --shards N --check    every file in one shard
  python3 tool/test_shards.py --record LOG          refresh the durations
      from `flutter test --reporter json > LOG`

Exit status is 1 when --check finds a missing or duplicated file.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DURATIONS = REPO / 'tool/test_durations.json'
TEST_GLOB = 'test/*_test.dart'
_TAGS_RE = re.compile(r'@Tags\s*\(\s*\[([^\]]*)\]\s*\)', re.DOTALL)
_STRING_RE = re.compile(r"""['"]([^'"]+)['"]""")


def file_tags(rel_path: str) -> set[str]:
    """File-level @Tags([...]) declared before the first import/declaration."""
    text = (REPO / rel_path).read_text(encoding='utf-8')
    header_lines: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(('import ', 'export ', 'part ', 'void ', 'class ')):
            break
        header_lines.append(line)
    header = '\n'.join(header_lines)
    tags: set[str] = set()
    for match in _TAGS_RE.finditer(header):
        tags.update(_STRING_RE.findall(match.group(1)))
    return tags


def test_files(
    exclude_tags: set[str] | None = None,
    only_tags: set[str] | None = None,
) -> list[str]:
    """The files a bare `flutter test` runs, as repo-relative paths."""
    out = subprocess.run(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard',
         '--', TEST_GLOB],
        cwd=REPO, check=True, capture_output=True, text=True,
    ).stdout
    files = sorted(line for line in out.splitlines() if (REPO / line).exists())
    if not exclude_tags and not only_tags:
        return files
    selected: list[str] = []
    for f in files:
        tags = file_tags(f)
        if exclude_tags and (tags & exclude_tags):
            continue
        if only_tags and not (tags & only_tags):
            continue
        selected.append(f)
    return selected


def load_durations() -> dict[str, float]:
    if not DURATIONS.exists():
        return {}
    return json.loads(DURATIONS.read_text())


def assign(files: list[str], durations: dict[str, float],
           shards: int) -> list[list[str]]:
    """Longest first onto the lightest shard; ties break by path, index."""
    known = [durations[f] for f in files if f in durations]
    default = statistics.median(known) if known else 1.0
    weight = {f: durations.get(f, default) for f in files}
    loads = [0.0] * shards
    result: list[list[str]] = [[] for _ in range(shards)]
    for f in sorted(files, key=lambda f: (-weight[f], f)):
        k = min(range(shards), key=lambda k: (loads[k], k))
        loads[k] += weight[f]
        result[k].append(f)
    return [sorted(shard) for shard in result]


def main_index(
    shards: int,
    index: int,
    exclude_tags: set[str],
    only_tags: set[str],
) -> int:
    if not 0 <= index < shards:
        print(f'error: --index {index} is outside 0..{shards - 1}',
              file=sys.stderr)
        return 1
    files = assign(
        test_files(exclude_tags=exclude_tags, only_tags=only_tags),
        load_durations(),
        shards,
    )[index]
    print('\n'.join(files))
    return 0


def main_check(
    shards: int,
    exclude_tags: set[str],
    only_tags: set[str],
    warn_unrecorded: int,
    max_unrecorded: int | None,
) -> int:
    all_files = test_files()
    files = test_files(exclude_tags=exclude_tags, only_tags=only_tags)
    durations = load_durations()
    split = assign(files, durations, shards)
    seen: dict[str, int] = {}
    errors = []
    for k, shard in enumerate(split):
        if not shard:
            errors.append(f'shard {k} is empty')
        for f in shard:
            if f in seen:
                errors.append(f'{f} is in shards {seen[f]} and {k}')
            seen[f] = k
            if any(c.isspace() for c in f):
                errors.append(f'{f}: whitespace in a test path')
    for f in sorted(set(files) - set(seen)):
        errors.append(f'{f} is in no shard')
    unrecorded = [f for f in all_files if f not in durations]
    stale = sorted(set(durations) - set(all_files))
    if max_unrecorded is not None and len(unrecorded) > max_unrecorded:
        errors.append(
            f'{len(unrecorded)} files without a recorded duration '
            f'(max {max_unrecorded}); refresh with --record'
        )
    for error in errors:
        print(f'error: {error}', file=sys.stderr)
    if unrecorded or stale:
        level = 'warning' if len(unrecorded) > warn_unrecorded else 'note'
        print(f'{level}: {len(unrecorded)} files without a recorded duration, '
              f'{len(stale)} stale records; refresh with --record',
              file=sys.stderr)
    for k, shard in enumerate(split):
        total = sum(durations.get(f, 0.0) for f in shard)
        print(f'shard {k}: {len(shard)} files, {total:.0f}s recorded')
    return 1 if errors else 0


def _parse_log_durations(log: Path) -> dict[str, float]:
    """Per file: from its suite event to its last finished test."""
    paths: dict[int, str] = {}
    start: dict[int, int] = {}
    end: dict[int, int] = {}
    suite_of: dict[int, int] = {}
    for line in log.read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue  # flutter's own banner lines
        kind = event.get('type')
        if kind == 'suite':
            suite = event['suite']
            path = Path(suite['path'])
            if path.is_absolute():
                path = path.relative_to(REPO)
            paths[suite['id']] = path.as_posix()
            start[suite['id']] = event['time']
        elif kind == 'testStart':
            suite_of[event['test']['id']] = event['test']['suiteID']
        elif kind == 'testDone' and event['testID'] in suite_of:
            suite = suite_of[event['testID']]
            end[suite] = max(end.get(suite, 0), event['time'])
    return {
        paths[s]: round((end[s] - start[s]) / 1000, 1)
        for s in paths if s in end and (REPO / paths[s]).exists()
    }


def main_record(logs: list[Path]) -> int:
    """Refresh durations from one or more json logs (first log wins per file)."""
    durations: dict[str, float] = {}
    for log in logs:
        for rel, secs in _parse_log_durations(log).items():
            durations.setdefault(rel, secs)
    if not durations:
        print(f'error: no finished test files in {logs}', file=sys.stderr)
        return 1
    DURATIONS.write_text(json.dumps(dict(sorted(durations.items())),
                                    indent=1) + '\n')
    print(f'recorded {len(durations)} files to {DURATIONS.relative_to(REPO)}')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--shards', type=int)
    parser.add_argument('--index', type=int)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--record', type=Path, nargs='+', metavar='LOG')
    parser.add_argument('--exclude-tag', action='append', default=[])
    parser.add_argument('--only-tag', action='append', default=[])
    parser.add_argument('--warn-unrecorded', type=int, default=10)
    parser.add_argument('--max-unrecorded', type=int, default=None)
    args = parser.parse_args()
    if args.record:
        return main_record(args.record)
    if not args.shards or args.shards < 1:
        parser.error('--shards N (N >= 1) is required')
    exclude_tags = set(args.exclude_tag)
    only_tags = set(args.only_tag)
    if args.check:
        return main_check(
            args.shards,
            exclude_tags=exclude_tags,
            only_tags=only_tags,
            warn_unrecorded=args.warn_unrecorded,
            max_unrecorded=args.max_unrecorded,
        )
    if args.index is None:
        parser.error('--index or --check is required')
    return main_index(
        args.shards,
        args.index,
        exclude_tags=exclude_tags,
        only_tags=only_tags,
    )


if __name__ == '__main__':
    sys.exit(main())
