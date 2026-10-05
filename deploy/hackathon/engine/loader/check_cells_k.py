#!/usr/bin/env python3
"""k-anonymity gate for the bank_cells export (engine host loader).

Input: an NDJSON file, one aggregate cell per line: {metric, dims, half, period, numerator, denominator}.
Fails (exit 3) when ANY cell has denominator < K_MIN, a count that is not a non-negative integer, numerator > denominator, or a key
outside the allowed set (no ids, no free text). Nothing is written or deleted: a failing gate fails the RUN, not the data.
Prints counts only, never cell contents. Stdlib only.
"""
from __future__ import annotations

import json
import sys

ALLOWED = {"metric", "dims", "half", "period", "numerator", "denominator"}
K_MIN = 10


def check(lines, k_min: int = K_MIN) -> dict:
    rows = low = bad_keys = bad_counts = bad_json = 0
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        rows += 1
        try:
            cell = json.loads(raw)
        except ValueError:
            bad_json += 1
            continue
        if not isinstance(cell, dict) or set(cell) - ALLOWED or not {"metric", "numerator", "denominator"} <= set(cell):
            bad_keys += 1
            continue
        n, d = cell["numerator"], cell["denominator"]
        if not (isinstance(n, int) and isinstance(d, int) and not isinstance(n, bool) and not isinstance(d, bool)) or n < 0 or d < 0 or n > d:
            bad_counts += 1
            continue
        if d < k_min:
            low += 1
    return {"rows": rows, "below_k": low, "bad_keys": bad_keys, "bad_counts": bad_counts, "bad_json": bad_json, "k_min": k_min}


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check_cells_k.py <cells.ndjson>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as fh:
        report = check(fh)
    print(json.dumps(report, sort_keys=True))
    if report["rows"] == 0:
        print("gate failed: empty cells file", file=sys.stderr)
        return 3
    if report["below_k"] or report["bad_keys"] or report["bad_counts"] or report["bad_json"]:
        print("gate failed: cells below k, unexpected keys or malformed counts; nothing was published", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
