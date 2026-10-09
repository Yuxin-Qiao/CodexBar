#!/usr/bin/env python3
"""Fork-only repeatability proof for the existing direct test runner."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile

import benchmark_swiftpm_cache as bench
import ci_swiftpm_cache as cache


def frozen_timestamp_probe():
    with tempfile.TemporaryDirectory(prefix="cache-input-behavior-") as temporary:
        root = Path(temporary)
        (root / "Sources/Probe").mkdir(parents=True)
        (root / "Tests/ProbeTests").mkdir(parents=True)
        (root / "Package.swift").write_text(
            '// swift-tools-version: 6.2\nimport PackageDescription\n'
            'let package = Package(name: "Probe", targets: [.target(name: "Probe"),'
            '.testTarget(name: "ProbeTests", dependencies: ["Probe"])])\n'
        )
        source = root / "Sources/Probe/Probe.swift"
        test = root / "Tests/ProbeTests/ProbeTests.swift"
        source.write_text('public func value() -> Int { 41 }\n')
        test.write_text('import XCTest\nimport Probe\nfinal class ProbeTests: XCTestCase { '
                        'func testValue() { print("CI_SENTINEL=\\(Probe.value())"); '
                        'XCTAssertEqual(Probe.value(), 41) } }\n')
        subprocess.run(["git", "init", "--quiet", str(root)], check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)

        def run(name, arguments):
            path = bench.output_root() / name
            with path.open("w") as output:
                subprocess.run(arguments, cwd=root, stdout=output, stderr=subprocess.STDOUT, check=True)
            return path.read_text()

        run("timestamp-cold.log", ["swift", "build", "--build-tests", "--build-system", "native"])
        cache.snapshot(root, cache.DEFAULT_METADATA, "timestamp-probe")
        for path in (source, test):
            previous = path.stat().st_mtime_ns
            path.write_text(path.read_text().replace("41", "42"))
            os.utime(path, ns=(previous, previous))
        restoration = cache.restore(root, cache.DEFAULT_METADATA, "timestamp-probe")
        if restoration["changed"] != 2:
            raise RuntimeError("Both backdated edits must invalidate the cached inputs")
        run("timestamp-rebuild.log", ["swift", "build", "--build-tests", "--build-system", "native"])
        content = run("timestamp-behavior.log", ["swift", "test", "--skip-build", "--filter", "ProbeTests", "--build-system", "native"])
        if "CI_SENTINEL=42" not in content or "CI_SENTINEL=41" in content:
            raise RuntimeError("The compiled program did not execute the modified source")
        bench.update_result(timestamp_probe={"changed_inputs": 2, "compiled_value": 42, "success": True})


def case(seed_context):
    # This explicit transition is confined to the experiment: same toolchain,
    # dependencies and product sources; only the cache helper was hardened.
    restored = cache.restore(bench.ROOT, cache.DEFAULT_METADATA, seed_context)
    if restored.get("fallback") or not restored["restored"]:
        raise RuntimeError("The frozen baseline did not restore")
    current_context = cache.build_context(bench.ROOT, "macos26-arm64")["context"]
    cache.snapshot(bench.ROOT, cache.DEFAULT_METADATA, current_context)
    bench.update_result(mode="direct", workers=2, input_restore=restored, seed_context=seed_context,
                        current_context=current_context, cache_transition="Hardened helper; identical product inputs")
    before = bench.objects()
    bench.measured_command("build", ["swift", "build", "--build-tests"])
    after = bench.objects()
    bench.update_result(object_mtimes_changed=sum(before[name][0] != after[name][0] for name in before.keys() & after.keys()))
    log = bench.measured_command("full-direct-tests", ["./Scripts/test.sh", "--direct-workers", "2"])
    content = log.read_text()
    inventory = [name for group in re.findall(r"(?m)^Selected group \d+: (\[.*\])$", content) for name in json.loads(group)]
    counters = {name: int(value) for name, value in re.findall(r"(?m)^- ([\w -]+): (\d+)$", content)}
    if not inventory or counters.get("Selected selections") != len(inventory) or counters.get("Discovered selections") != len(inventory):
        raise RuntimeError("The entire discovered inventory was not selected")
    if "- Execution mode: direct" not in content or counters.get("Workers") != 2:
        raise RuntimeError("The test runner did not use the requested direct workers")
    if any(counters.get(name, -1) != 0 for name in ("First-pass failed groups", "Timed out groups", "Full-group retries", "Isolated selection retries")):
        raise RuntimeError("A repeatability run required retries or reported a failed group")
    if not re.search(r"Test .*rebuilt source returns the current value.*passed", content):
        raise RuntimeError("The actual behavior probe did not pass")
    bench.update_result(inventory=inventory, inventory_sha256=hashlib.sha256(json.dumps(inventory).encode()).hexdigest(),
                        test_counters=counters, complete=True)
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        data = bench.read_result()
        with open(path, "a") as output:
            output.write(f"### Complete direct test run\n\n- Inventory: {len(inventory)} selections\n")
            output.write(f"- Build: {data['phases']['build']['seconds']:.1f}s\n")
            output.write(f"- Tests: {data['phases']['full-direct-tests']['seconds']:.1f}s\n")
            output.write("- Two workers; no failed groups, timeouts or retries\n")


def main():
    signal.signal(signal.SIGTERM, bench.interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "probe", "case"))
    parser.add_argument("--seed-context")
    args = parser.parse_args()
    if args.action == "prepare":
        bench.prepare("restored")
    elif args.action == "probe":
        frozen_timestamp_probe()
    else:
        if not args.seed_context:
            parser.error("the frozen seed context is required")
        case(args.seed_context)


if __name__ == "__main__":
    main()
