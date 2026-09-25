#!/usr/bin/env python3
"""Read-only runner inventory. Does not install tools, fetch dependencies, or read secrets."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def probe(args):
    try:
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=5)
        return {"ok": result.returncode == 0, "output": result.stdout.strip()[:500]}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": type(error).__name__}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-macos", action="store_true", help="Exit 77 without a Mac/Xcode toolchain")
    args = parser.parse_args()
    system = platform.system()
    head = probe(["git", "rev-parse", "HEAD"])
    status = probe(["git", "status", "--porcelain"])
    report = {
        "platform": system,
        "python": platform.python_version(),
        "head": head,
        "dirty": bool(status.get("output")) if status["ok"] else None,
        "toolsPresent": {name: shutil.which(name) is not None for name in ("git", "python3", "gh", "rg")},
        "portableChecks": [
            "python3 -m unittest discover -s scripts -p 'test_*.py'",
            "python3 scripts/check-no-feedback.py",
            "git diff --check",
        ],
        "macValidation": "Not run. Jot needs Apple SDKs; Linux Swift cannot build the current package.",
        "networkAndGitHubAccess": "Not tested; check only the assigned repository through the runner's GitHub tools.",
    }
    ready = head["ok"] and status["ok"]
    if args.require_macos:
        if system == "Darwin":
            report["xcode"] = probe(["xcodebuild", "-version"])
            report["swiftCompiler"] = probe(["xcrun", "--find", "swiftc"])
            ready = ready and report["xcode"]["ok"] and report["swiftCompiler"]["ok"]
        else:
            ready = False
        report["macPreflight"] = "tools-present; SDK/build/runtime still unverified" if ready else "unavailable"
    print(json.dumps(report, indent=2))
    return 0 if ready else (77 if args.require_macos else 1)


if __name__ == "__main__":
    sys.exit(main())
