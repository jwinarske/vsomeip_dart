#!/usr/bin/env python3
# check_min_coverage.py — fail if overall line coverage from an LCOV file
# is below a configurable minimum percentage.
#
# Used by CI to enforce the C++ side's 95% target. The Dart side uses
# check_100pct_coverage.py instead, which is stricter.
#
# Usage:
#   python3 scripts/check_min_coverage.py coverage.lcov --min 95
#   python3 scripts/check_min_coverage.py coverage.lcov --min 95 --prefix src/
#
# Excludes test/, generated/, and dart_api_dl* by default.

import argparse
import sys
from pathlib import Path

DEFAULT_EXCLUDES = (
    'src/test/',
    'src/dart_api_dl',
    'generated/',
    '/usr/',
    'gtest',
)


def parse_lcov(path: Path):
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
    ap.add_argument('lcov', type=Path)
    ap.add_argument('--min', type=float, default=95.0,
                    help='Minimum acceptable overall coverage percentage')
    ap.add_argument('--prefix', default='',
                    help='Only count files whose path contains this prefix')
    ap.add_argument('--exclude', action='append', default=list(DEFAULT_EXCLUDES),
                    help='Substrings to exclude (repeatable)')
    args = ap.parse_args()

    if not args.lcov.exists():
        print(f'error: {args.lcov} does not exist', file=sys.stderr)
        sys.exit(2)

    total_lf = 0
    total_lh = 0
    files = 0
    for src, lf, lh in parse_lcov(args.lcov):
        if args.prefix and args.prefix not in src:
            continue
        if any(ex in src for ex in args.exclude):
            continue
        total_lf += lf
        total_lh += lh
        files += 1

    if total_lf == 0:
        print('error: no lines counted (check --prefix / --exclude)', file=sys.stderr)
        sys.exit(2)

    pct = total_lh / total_lf * 100.0
    print(f'Lines hit:    {total_lh}')
    print(f'Lines found:  {total_lf}')
    print(f'Files:        {files}')
    print(f'Coverage:     {pct:.2f}% (min {args.min:.2f}%)')

    if pct + 1e-9 < args.min:
        print(f'\nFAIL: coverage {pct:.2f}% is below minimum {args.min:.2f}%')
        sys.exit(1)

    print('OK')
    sys.exit(0)


if __name__ == '__main__':
    main()
