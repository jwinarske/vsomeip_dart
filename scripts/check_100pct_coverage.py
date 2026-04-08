#!/usr/bin/env python3
# check_100pct_coverage.py — fail if any covered file under lib/src/ has
# less than 100% line coverage.
#
# Reads an LCOV info file (from `dart test --coverage` → `format_coverage`)
# and prints a per-file table. Exits non-zero if any file is below 100%.
#
# Usage:
#   dart pub global activate coverage
#   dart test --coverage=coverage
#   dart pub global run coverage:format_coverage \
#       --lcov --in=coverage --out=coverage/lcov.info \
#       --report-on=lib --packages=.dart_tool/package_config.json
#   python3 scripts/check_100pct_coverage.py coverage/lcov.info
#
# Files matching --exclude (substring match) are skipped — used for
# generated code, examples, etc.

import argparse
import re
import sys
from pathlib import Path

DEFAULT_EXCLUDES = (
    'lib/generated/',
    'lib/src/vsomeip_dart.dart',  # barrel re-exports only
    '.g.dart',
)


def parse_lcov(path: Path):
    """Yield (source_file, lines_found, lines_hit) tuples from an LCOV file."""
    cur = None
    found = 0
    hit = 0
    with path.open() as f:
        for line in f:
            line = line.rstrip()
            if line.startswith('SF:'):
                cur = line[3:]
                found = 0
                hit = 0
            elif line.startswith('LF:'):
                found = int(line[3:])
            elif line.startswith('LH:'):
                hit = int(line[3:])
            elif line == 'end_of_record' and cur is not None:
                yield (cur, found, hit)
                cur = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('lcov', type=Path, help='Path to lcov.info')
    ap.add_argument('--prefix', default='lib/src/',
                    help='Only check files whose path contains this prefix')
    ap.add_argument('--exclude', action='append', default=list(DEFAULT_EXCLUDES),
                    help='Substrings to exclude (repeatable)')
    args = ap.parse_args()

    if not args.lcov.exists():
        print(f'error: {args.lcov} does not exist', file=sys.stderr)
        sys.exit(2)

    failures = []
    checked = 0
    for src, lf, lh in parse_lcov(args.lcov):
        if args.prefix and args.prefix not in src:
            continue
        if any(ex in src for ex in args.exclude):
            continue
        checked += 1
        pct = (lh / lf * 100.0) if lf > 0 else 100.0
        marker = ' ' if pct >= 100.0 else '!'
        print(f'  {marker} {pct:6.2f}%  {lh:5d}/{lf:<5d}  {src}')
        if pct < 100.0:
            failures.append((src, pct, lh, lf))

    print()
    print(f'Checked {checked} files under {args.prefix!r}')

    if failures:
        print(f'\nFAIL: {len(failures)} file(s) below 100%:')
        for src, pct, lh, lf in failures:
            print(f'  {pct:6.2f}%  ({lh}/{lf})  {src}')
        sys.exit(1)

    print('OK: 100% line coverage')
    sys.exit(0)


if __name__ == '__main__':
    main()
