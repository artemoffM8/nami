#!/usr/bin/env python3
"""Measure the existing Xcode-free verifier without modifying the app.

This is a verifier wall-clock measurement, NOT an iOS runtime benchmark.
The command returns nonzero if verification fails or times out.
"""
import argparse
import json
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    command = [sys.executable, "Tools/verify_project.py"]
    started = time.perf_counter_ns()
    try:
        run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                             timeout=args.timeout, check=False)
        elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
        record = {
            "schema_version": 1,
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "measurement": "verifier_wall_clock",
            "duration_ms": round(elapsed_ms, 3),
            "exit_code": run.returncode,
            "python": platform.python_version(),
            "platform": platform.platform(),
            "command": command,
        }
    except subprocess.TimeoutExpired:
        print("Verifier timed out", file=sys.stderr)
        return 124
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))
    if run.stdout:
        print(run.stdout, end="")
    if run.stderr:
        print(run.stderr, file=sys.stderr, end="")
    return run.returncode

if __name__ == "__main__":
    raise SystemExit(main())
