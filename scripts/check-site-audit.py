#!/usr/bin/env python3
"""Keep npm's high/critical gate, with one expiring build-only advisory exception."""
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys

ADVISORY = "https://github.com/advisories/GHSA-fc5q-39xc-vjpf"
EXPIRES = datetime(2026, 12, 2, tzinfo=timezone.utc)
SITE = Path(__file__).resolve().parents[1] / "apps/site"


def only_accepted_advisory(report, now):
    if now >= EXPIRES or report.get("auditReportVersion") != 2 or "error" in report:
        return False
    rows = report.get("vulnerabilities", {})
    counts = report.get("metadata", {}).get("vulnerabilities", {})
    high = {name for name, row in rows.items() if row.get("severity") == "high"}
    if not high or counts.get("high") != len(high) or counts.get("critical") != 0:
        return False

    def accepted(name, path):
        if name in path or name not in rows:
            return False
        row = rows[name]
        causes = row.get("via")
        if row.get("severity") == "critical" or not isinstance(causes, list) or not causes:
            return False
        for cause in causes:
            if isinstance(cause, str):
                if not accepted(cause, path | {name}):
                    return False
            elif not (isinstance(cause, dict) and name == "picomatch"
                      and cause.get("dependency") == name and cause.get("url") == ADVISORY
                      and cause.get("severity") == "high" and cause.get("range") == "<=4.0.7"):
                return False
        return True

    return all(accepted(name, set()) for name in high)


def main():
    audit = subprocess.run(["npm", "audit", "--audit-level=high", "--json"], cwd=SITE,
                           stdout=subprocess.PIPE, text=True)
    if audit.returncode == 0:
        print("npm audit passed.")
        return 0
    print(audit.stdout)
    if audit.returncode == 1 and only_accepted_advisory(json.loads(audit.stdout), datetime.now(timezone.utc)):
        print(f"Accepted build-only {ADVISORY} until {EXPIRES.isoformat()}.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
