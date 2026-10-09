#!/usr/bin/env python3
"""Hosted, temporary compile controls for the native musl path-gate change."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def command(arguments, log):
    started = time.monotonic()
    with log.open("w") as output:
        result = subprocess.run(arguments, stdout=output, stderr=subprocess.STDOUT)
    return {"exit_code": result.returncode, "seconds": round(time.monotonic() - started, 3)}


def gate(script, paths, destination):
    destination.write_text("")
    environment = dict(os.environ, GITHUB_OUTPUT=str(destination))
    result = subprocess.run(["bash", str(script), str(paths)], env=environment,
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    fields = dict(line.split("=", 1) for line in destination.read_text().splitlines())
    return fields["linux-musl-build"] == "true"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if revision != args.expected_head:
        raise RuntimeError("Unexpected production revision")
    old_gate = output / "baseline-gate.sh"
    old_gate.write_bytes(subprocess.check_output(
        ["git", "show", f"{args.baseline}:Scripts/ci_linux_musl_build_gate.sh"]))
    new_gate = Path("Scripts/ci_linux_musl_build_gate.sh").resolve()
    compile_musl = ["swift", "build", "-c", "release", "--product", "CodexBarCLI",
                    "--swift-sdk", os.environ["SWIFT_STATIC_LINUX_SDK"],
                    "--triple", os.environ["SWIFT_STATIC_LINUX_SDK_TRIPLE"]]
    marker = "CI_NATIVE_GATE_NEGATIVE_CONTROL"
    linux_only_failure = ("\n#if defined(__linux__)\n#include <features.h>\n"
                          "#if !defined(__GLIBC__)\n#error " + marker +
                          "\n#endif\n#endif\n").encode()
    cases = [
        ("quickjs-source", Path("Sources/CQuickJS/quickjs.c"), linux_only_failure),
        ("quickjs-header", Path("Sources/CQuickJS/include/quickjs.h"), linux_only_failure),
        ("sqlite-module", Path("Sources/CSQLite3/module.modulemap"), None),
        ("sqlite-shim", Path("Sources/CSQLite3/shim.h"), ("#error " + marker + "\n").encode()),
    ]
    results = {"production_head": revision, "baseline_head": args.baseline,
               "production_gate_sha256": sha256(new_gate.read_bytes()), "cases": []}
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--"], check=True)
    for name, path, prefix in cases:
        original = path.read_bytes()
        paths = output / f"{name}.paths"
        try:
            if prefix is None:
                if b'"shim.h"' not in original:
                    raise RuntimeError("Unexpected SQLite module-map header")
                changed = original.replace(b'"shim.h"', ('"' + marker + '.h"').encode(), 1)
            else:
                changed = prefix + original
            path.write_bytes(changed)
            actual_changes = subprocess.check_output(["git", "diff", "--name-status", "HEAD"], text=True)
            if actual_changes != f"M\t{path.as_posix()}\n":
                raise RuntimeError("Control changed unexpected tracked inputs")
            paths.write_text(actual_changes)
            before = gate(old_gate, paths, output / f"{name}-before.output")
            after = gate(new_gate, paths, output / f"{name}-after.output")
            if before or not after:
                raise RuntimeError(f"{name}: expected old skip and fixed requirement")
            record = {"case": name, "path": path.as_posix(), "baseline_required": before,
                      "fixed_required": after, "original_sha256": sha256(original)}
            if name.startswith("quickjs"):
                native = command(["swift", "build", "-c", "release", "--target", "CQuickJS"],
                                 output / f"{name}-glibc.log")
                record["glibc_native_target"] = native
                if native["exit_code"]:
                    raise RuntimeError(f"{name}: conditional control unexpectedly fails glibc")
            compiled = command(compile_musl, output / f"{name}-musl.log")
            record["musl_cli"] = compiled
            if compiled["exit_code"] == 0 or marker not in (output / f"{name}-musl.log").read_text():
                raise RuntimeError(f"{name}: expected the injected native-input compile failure")
            results["cases"].append(record)
            print(json.dumps(record), flush=True)
        finally:
            path.write_bytes(original)
            subprocess.run(["git", "diff", "--exit-code", "HEAD", "--"], check=True)
            (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    # The initial workflow step proved the clean complete CLI. Repeat after controls
    # to prove that all mutated inputs were restored and still build together.
    restored = command(compile_musl, output / "restored-clean-cli.log")
    results["restored_clean_cli"] = restored
    results["success"] = restored["exit_code"] == 0 and len(results["cases"]) == len(cases)
    (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    if not results["success"]:
        raise RuntimeError("Restored production CLI failed")


if __name__ == "__main__":
    main()
