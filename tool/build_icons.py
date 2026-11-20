#!/usr/bin/env python3
"""Compile 24x24 SVGs under tool/icons/svg/ into assets/icon.ttf and lib/app/icons/app_icons.dart."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.areaPen import AreaPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import SVGPath
import pathops
from picosvg.svg import SVG

ROOT = Path(__file__).resolve().parent.parent
SVG_DIR = ROOT / 'tool' / 'icons' / 'svg'
FONT_OUT = ROOT / 'assets' / 'icon.ttf'
DART_OUT = ROOT / 'lib' / 'app' / 'icons' / 'app_icons.dart'

UPM = 960
SCALE = UPM / 24.0
PUA_START = 0xE900

# Directional icons mirror cleanly in RTL layouts.
RTL_MIRROR_ICONS = frozenset({
    'backup',
    'external_link',
    'file_import',
    'history',
    'layout_three_col',
    'layout_two_col',
    'send',
    'sidebar_collapse',
    'sidebar_expand',
    'undo',
})

DART_KEYWORDS = frozenset({
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'false', 'final', 'finally', 'for', 'Function',
    'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is',
    'late', 'library', 'mixin', 'new', 'null', 'of', 'on', 'operator',
    'part', 'required', 'rethrow', 'return', 'sealed', 'set', 'show',
    'static', 'super', 'switch', 'sync', 'this', 'throw', 'true', 'try',
    'type', 'typedef', 'var', 'void', 'when', 'with', 'while', 'yield',
})


def snake_to_camel(name: str) -> str:
  parts = name.split('_')
  camel = parts[0] + ''.join(p[:1].upper() + p[1:] for p in parts[1:] if p)
  if camel in DART_KEYWORDS:
    return f'{camel}Icon'
  return camel


def _svg_path_to_pathops(d: str) -> pathops.Path:
  p = pathops.Path()
  pen = p.getPen()
  SVGPath.fromstring(
      f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
      f'<path d="{d}"/></svg>'
  ).draw(pen)
  return pathops.simplify(p, fix_winding=True)


def svg_to_tt_glyph(svg_path: Path):
  raw = svg_path.read_text(encoding='utf-8')
  if 'viewBox="0 0 24 24"' not in raw:
    raise ValueError(f'{svg_path}: expected viewBox="0 0 24 24"')

  pico = SVG.fromstring(raw).topicosvg(ndigits=4)
  paths: list[pathops.Path] = []
  for el in pico.svg_root.iter():
    if not el.tag.endswith('path'):
      continue
    fill = el.attrib.get('fill', '')
    d = el.attrib.get('d', '').strip()
    if not d or fill == 'none':
      continue
    sk_path = _svg_path_to_pathops(d)
    if len(list(sk_path)) > 0:
      paths.append(sk_path)

  if not paths:
    raise ValueError(f'{svg_path}: produced no filled contours')

  combined = pathops.Path()
  if len(paths) == 1:
    combined = pathops.simplify(paths[0], fix_winding=True)
  else:
    pathops.union(paths, combined.getPen(), fix_winding=True)
    combined = pathops.simplify(combined, fix_winding=True)

  # Map SVG y-down [0..24] -> TrueType y-up [0..UPM].
  rec = RecordingPen()
  tpen = TransformPen(
      Cu2QuPen(rec, max_err=0.5, reverse_direction=False),
      (SCALE, 0, 0, -SCALE, 0, UPM),
  )
  combined.draw(tpen)

  # TrueType glyf expects outer contours clockwise (AreaPen.value <= 0).
  area_pen = AreaPen()
  rec.replay(area_pen)
  bounds_pen = BoundsPen(None)
  rec.replay(bounds_pen)
  lsb = int(round(bounds_pen.bounds[0])) if bounds_pen.bounds else 0
  tt_pen = TTGlyphPen(None)
  if area_pen.value > 0:
    rec.replay(ReverseContourPen(tt_pen))
  else:
    rec.replay(tt_pen)
  return tt_pen.glyph(), lsb


def build_font(svg_files: list[Path]) -> tuple[bytes, str]:
  import io

  fb = FontBuilder(UPM, isTTF=True)
  glyph_order = ['.notdef']
  cmap: dict[int, str] = {}
  glyf: dict[str, object] = {'.notdef': TTGlyphPen(None).glyph()}
  hmtx: dict[str, tuple[int, int]] = {'.notdef': (UPM, 0)}

  dart_entries: list[tuple[str, int, bool, str]] = []
  for idx, svg_file in enumerate(svg_files):
    stem = svg_file.stem
    if not re.fullmatch(r'[a-z][a-z0-9_]*', stem):
      raise ValueError(f'Invalid SVG filename {svg_file.name}: use snake_case')
    codepoint = PUA_START + idx
    glyph_name = f'uni{codepoint:04X}'
    glyph, lsb = svg_to_tt_glyph(svg_file)
    glyph_order.append(glyph_name)
    cmap[codepoint] = glyph_name
    glyf[glyph_name] = glyph
    hmtx[glyph_name] = (UPM, lsb)
    dart_entries.append((
        snake_to_camel(stem),
        codepoint,
        stem in RTL_MIRROR_ICONS,
        stem,
    ))

  fb.setupGlyphOrder(glyph_order)
  fb.setupCharacterMap(cmap)
  fb.setupGlyf(glyf)
  fb.setupHorizontalMetrics(hmtx)
  fb.setupHorizontalHeader(ascent=UPM, descent=0, lineGap=0)
  fb.setupNameTable({
      'familyName': 'iconFont',
      'styleName': 'Regular',
      'uniqueFontIdentifier': 'Parfait-iconFont-Regular',
      'fullName': 'iconFont',
      'version': 'Version 2.0',
      'psName': 'iconFont',
  })
  fb.setupOS2(
      sTypoAscender=UPM,
      sTypoDescender=0,
      sTypoLineGap=0,
      usWinAscent=UPM,
      usWinDescent=0,
  )
  fb.setupPost()
  # Fixed epoch keeps font bytes deterministic across rebuilds.
  fb.setupHead(unitsPerEm=UPM, created=0, modified=0)

  buf = io.BytesIO()
  fb.save(buf)
  font_bytes = buf.getvalue()

  lines = [
      '// GENERATED CODE - DO NOT EDIT BY HAND.',
      '// Source: tool/icons/svg/*.svg -> python3 tool/build_icons.py',
      '',
      "import 'package:material_ui/material_ui.dart';",
      '',
      '/// Custom unified SVG icon font bundled as `assets/icon.ttf`.',
      'abstract final class AppIcons {',
      "  static const String _fontFamily = 'iconFont';",
      '',
  ]
  for camel, cp, rtl, stem in dart_entries:
    lines.append(f'  // {stem}')
    single = f'  static const {camel} = IconData(0x{cp:04x}, fontFamily: _fontFamily);'
    if not rtl and len(single) <= 80:
      lines.append(single)
    else:
      lines.append(f'  static const {camel} = IconData(')
      lines.append(f'    0x{cp:04x},')
      lines.append('    fontFamily: _fontFamily,')
      if rtl:
        lines.append('    matchTextDirection: true,')
      lines.append('  );')
  # Backward-compatible aliases during/beyond migration where semantic name differs.
  alias_targets = {name for name, _, _, _ in dart_entries}
  if 'newWorks' in alias_targets and 'n' not in alias_targets:
    lines.append('')
    lines.append('  /// Legacy alias for [newWorks].')
    lines.append('  static const IconData n = newWorks;')
  lines.append('}')
  lines.append('')
  dart_src = '\n'.join(lines)
  return font_bytes, dart_src


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument(
      '--check',
      action='store_true',
      help='Fail if generated outputs differ from disk.',
  )
  args = parser.parse_args()

  svg_files = sorted(SVG_DIR.glob('*.svg'))
  if not svg_files:
    print(f'No SVGs found under {SVG_DIR}', file=sys.stderr)
    return 1

  font_bytes, dart_src = build_font(svg_files)
  if args.check:
    ok = True
    if not FONT_OUT.exists() or FONT_OUT.read_bytes() != font_bytes:
      print(f'Out of date: {FONT_OUT}', file=sys.stderr)
      ok = False
    if not DART_OUT.exists() or DART_OUT.read_text(encoding='utf-8') != dart_src:
      print(f'Out of date: {DART_OUT}', file=sys.stderr)
      ok = False
    return 0 if ok else 1

  FONT_OUT.parent.mkdir(parents=True, exist_ok=True)
  DART_OUT.parent.mkdir(parents=True, exist_ok=True)
  FONT_OUT.write_bytes(font_bytes)
  DART_OUT.write_text(dart_src, encoding='utf-8')
  print(f'Built {len(svg_files)} glyphs -> {FONT_OUT.relative_to(ROOT)} & {DART_OUT.relative_to(ROOT)}')
  return 0


if __name__ == '__main__':
  raise SystemExit(main())
