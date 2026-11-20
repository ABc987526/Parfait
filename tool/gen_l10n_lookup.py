#!/usr/bin/env python3
"""Generate the dynamic-key lookup over AppLocalizations (child C / C6).

The widget layer has a few genuinely dynamic call sites (widget titleKey
params, enum labelKeys, error-code maps). They resolve through the
generated `l10nLookup` switch; unknown keys fall back to the key itself,
matching the legacy ReplicaStrings table fallback.

Run after `flutter gen-l10n` whenever the ARB keys change:
  python3 tool/gen_l10n_lookup.py
Verify in CI without writing:
  python3 tool/gen_l10n_lookup.py --check
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARB = ROOT / 'lib' / 'l10n' / 'app_zh.arb'
OUT = ROOT / 'lib' / 'l10n' / 'lookup.dart'


def _render() -> tuple[str, int]:
    arb = json.loads(ARB.read_text(encoding='utf-8'))
    cases = []
    for key in sorted(arb):
        if key.startswith('@'):
            continue
        if re.findall(r'\{(\w+)\}', arb[key]):
            continue
        cases.append(f"  '{key}' => l10n.{key},")
    body = '\n'.join(cases)
    raw = (
        "import 'package:flutter/widgets.dart';\n\n"
        "import 'app_localizations.dart';\n"
        "import '../core/i18n/replica_language.dart';\n\n"
        "/// Locale access for the legacy language enum (onboarding previews).\n"
        "extension ReplicaLanguageLocale on ReplicaLanguage {\n"
        "  Locale get locale => parseAppLocale(tag);\n"
        "}\n\n"
        "/// Converts a BCP-47 tag ('zh-CN') into a [Locale].\n"
        "Locale parseAppLocale(String tag) {\n"
        "  final parts = tag.replaceAll('_', '-').split('-');\n"
        "  return Locale(parts.first, parts.length > 1 ? parts[1] : null);\n"
        "}\n\n"
        "/// Dynamic key lookup for call sites that cannot statically name their\n"
        "/// message (C6). Unknown keys return the key itself.\n"
        "String l10nLookup(AppLocalizations l10n, String key) => switch (key) {\n"
        f"{body}\n"
        "  _ => key,\n"
        "};\n\n"
        "/// Lookup against an explicit locale (language picker previews).\n"
        "String l10nLookupFor(Locale locale, String key) =>\n"
        "    l10nLookup(lookupAppLocalizations(locale), key);\n"
    )
    dart_bin = shutil.which('dart')
    if dart_bin:
        formatted = subprocess.run(
            [dart_bin, 'format'],
            input=raw,
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        return formatted, len(cases)
    raise RuntimeError(
        '`dart` not found on PATH; run with Flutter/Dart SDK available '
        'so generated output matches dart format.'
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--check',
        action='store_true',
        help='Fail if lib/l10n/lookup.dart is out of date.',
    )
    args = parser.parse_args()

    rendered, count = _render()
    if args.check:
        if not OUT.exists():
            print(f'Missing generated file: {OUT.relative_to(ROOT)}', file=sys.stderr)
            return 1
        disk = OUT.read_text(encoding='utf-8')
        if disk != rendered:
            print(
                f'Out of date: {OUT.relative_to(ROOT)} '
                '(run `python3 tool/gen_l10n_lookup.py`)',
                file=sys.stderr,
            )
            return 1
        print(f'{OUT.relative_to(ROOT)}: up to date ({count} keys)')
        return 0

    OUT.write_text(rendered, encoding='utf-8')
    print(f'{OUT.relative_to(ROOT)}: {count} keys')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
