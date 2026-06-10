#!/usr/bin/env python3
"""
RLS Guard — fails CI if any *new* CREATE TABLE public.<name> in this PR
does not enable RLS in the same migration.

Why: Migrations 029 and 030 enabled RLS but forgot to write owner-policies
(later patched in 052). This guard catches the inverse mistake — a new
public table landing without RLS at all — at PR time, before the table is
ever created in production.

Logic:
  1. Find all .sql files in migrations/ touched by this PR (or all of them
     when running locally with --all).
  2. For each file, parse out every CREATE TABLE [IF NOT EXISTS] public.X
     statement.
  3. Confirm the same file (case-insensitive) contains:
        ALTER TABLE [public.]X ENABLE ROW LEVEL SECURITY
     plus at least one CREATE POLICY [...] ON [public.]X.
  4. Allow-list: tables explicitly tagged with `-- rls-guard: skip` on the
     CREATE TABLE line (use sparingly — for things like `plan_limits`
     that are public catalogs handled by an "auth_read all" policy).

Exit codes:
  0 — all good
  1 — at least one violation found
  2 — internal error (couldn't read a file etc.)

Designed to be cheap, dependency-free, and stable. No regex Olympics.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import List, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS_DIR = REPO_ROOT / "migrations"

# Match `CREATE TABLE [IF NOT EXISTS] [public.]<name>` capturing the table name.
# Tolerates surrounding whitespace and the optional schema qualifier.
CREATE_TABLE_RE = re.compile(
    r"create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_][a-z0-9_]*)",
    re.IGNORECASE,
)
ENABLE_RLS_RE = re.compile(
    r"alter\s+table\s+(?:public\.)?{name}\s+enable\s+row\s+level\s+security",
    re.IGNORECASE,
)
CREATE_POLICY_RE = re.compile(
    r"create\s+policy\s+[\"']?[\w]+[\"']?\s+on\s+(?:public\.)?{name}\b",
    re.IGNORECASE,
)
SKIP_MARKER = "rls-guard: skip"


def find_violations(sql_path: Path) -> List[Tuple[str, str]]:
    """Return list of (table_name, reason) violations for a single SQL file."""
    try:
        text = sql_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"::error file={sql_path}::Could not read: {exc}", file=sys.stderr)
        return [("<read-error>", str(exc))]

    violations: List[Tuple[str, str]] = []

    for match in CREATE_TABLE_RE.finditer(text):
        # Slice the line containing the CREATE TABLE so we can check for
        # the "skip" marker on the same line.
        line_start = text.rfind("\n", 0, match.start()) + 1
        line_end = text.find("\n", match.end())
        if line_end == -1:
            line_end = len(text)
        create_line = text[line_start:line_end]

        if SKIP_MARKER in create_line.lower():
            continue

        table = match.group(1).lower()

        # Skip clearly non-user-data tables (CTEs, temporary helpers, etc.).
        # We only police public-schema tables — pg-internal / extension /
        # private-schema tables are out of scope.
        if table.startswith("pg_") or table.startswith("_"):
            continue

        rls_re = re.compile(ENABLE_RLS_RE.pattern.replace("{name}", re.escape(table)), re.IGNORECASE)
        pol_re = re.compile(CREATE_POLICY_RE.pattern.replace("{name}", re.escape(table)), re.IGNORECASE)

        if not rls_re.search(text):
            violations.append((table, "missing `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`"))
            continue

        if not pol_re.search(text):
            violations.append((table, "RLS enabled but no `CREATE POLICY ... ON` in same file"))

    return violations


def main() -> int:
    parser = argparse.ArgumentParser(description="Fail if a new public table lacks RLS + at least one policy.")
    parser.add_argument(
        "--files",
        nargs="*",
        default=None,
        help="Specific SQL files to check. If omitted, checks all migrations/*.sql.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Force-check every migration (use locally; CI passes --files from the diff).",
    )
    args = parser.parse_args()

    if args.files:
        targets = [Path(f) for f in args.files if f.endswith(".sql")]
    else:
        targets = sorted(MIGRATIONS_DIR.glob("*.sql"))

    if not targets:
        print("rls-guard: no SQL files to check, OK.")
        return 0

    total_violations = 0
    for path in targets:
        if not path.exists():
            # Files in a PR diff can be deleted — that's fine, nothing to check.
            continue
        violations = find_violations(path)
        for table, reason in violations:
            total_violations += 1
            # GitHub Actions annotation format — surfaces inline on the PR.
            rel = path.relative_to(REPO_ROOT) if path.is_absolute() else path
            print(f"::error file={rel}::Table `{table}` — {reason}")

    if total_violations == 0:
        print(f"rls-guard: OK — {len(targets)} migration file(s) checked, no violations.")
        return 0

    print(
        f"\nrls-guard: FAIL — {total_violations} violation(s) found.\n"
        "Every CREATE TABLE in a public schema must include in the SAME migration:\n"
        "  1. ALTER TABLE <name> ENABLE ROW LEVEL SECURITY;\n"
        "  2. At least one CREATE POLICY ... ON <name> ...;\n"
        "Use `-- rls-guard: skip` on the CREATE TABLE line for justified exceptions.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
