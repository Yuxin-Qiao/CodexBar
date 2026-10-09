#!/usr/bin/env python3
"""Fork-only compiled behavior checks for cache invalidation boundaries."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

import ci_swiftpm_cache as cache


def main():
    output = Path(os.environ["CI_CACHE_BENCH_DIR"])
    output.mkdir(parents=True, exist_ok=True)
    proof = {"phases": []}

    def record(**values):
        proof["phases"].append(values)
        (output / "result.json").write_text(json.dumps(proof, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="cache-edges-") as temporary:
        root = Path(temporary)
        source = root / "Sources/Probe/Probe.swift"
        test = root / "Tests/ProbeTests/ProbeTests.swift"
        resources = root / "Sources/Probe/Resources"
        resources.mkdir(parents=True)
        test.parent.mkdir(parents=True)
        (root / ".gitignore").write_text("/.build/\n")
        (root / "Package.swift").write_text(
            '// swift-tools-version: 6.2\nimport PackageDescription\n'
            'let package = Package(name: "Probe", targets: [.target(name: "Probe", resources: [.process("Resources")]),'
            '.testTarget(name: "ProbeTests", dependencies: ["Probe"])])\n'
        )
        source.write_text('import Foundation\npublic func value() -> Int { 41 }\n'
                          'public func resource(_ name: String) -> String? { '
                          'guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else { return nil }; '
                          'return try? String(contentsOf: url, encoding: .utf8) }\n')
        (resources / "kept.txt").write_text("old")
        (resources / "deleted.txt").write_text("delete")

        def write_test(value, kept, deleted, added):
            test.write_text('import XCTest\nimport Probe\nfinal class ProbeTests: XCTestCase { '
                            'func testInputs() { '
                            f'XCTAssertEqual(Probe.value(), {value}); '
                            f'XCTAssertEqual(Probe.resource("kept"), "{kept}"); '
                            f'XCTAssertEqual(Probe.resource("deleted"), {deleted}); '
                            f'XCTAssertEqual(Probe.resource("added"), {added}); '
                            f'print("CI_INPUTS_PASS={value},{kept}") }} }}\n')

        def git(*arguments):
            subprocess.run(["git", *arguments], cwd=root, check=True)

        def run(label, arguments):
            with (output / f"{label}.log").open("w") as log:
                subprocess.run(arguments, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
            return (output / f"{label}.log").read_text()

        def build_and_test(label):
            run(f"{label}-build", ["swift", "build", "--build-tests", "--build-system", "native"])
            content = run(f"{label}-behavior", ["swift", "test", "--skip-build", "--filter", "ProbeTests", "--build-system", "native"])
            markers = [line for line in content.splitlines() if line.startswith("CI_INPUTS_PASS=")]
            if len(markers) != 1:
                raise RuntimeError("The compiled resource/source assertions did not run")
            return markers[0]

        def restore(label, clean):
            helper = Path(cache.__file__).resolve()
            arguments = ["python3", str(helper), "restore", "--context", "compiled-edges"]
            if clean:
                arguments.append("--clean-fallback")
            return json.loads(run(f"{label}-restore", arguments))

        write_test(41, "old", '"delete"', "nil")
        git("init", "--quiet", str(root))
        git("add", ".")
        record(label="cold", actual=build_and_test("cold"))
        cache.snapshot(root, cache.DEFAULT_METADATA, "compiled-edges")
        timestamps = {path: path.stat().st_mtime_ns for path in (source, test, resources / "kept.txt")}
        source.write_text(source.read_text().replace("41", "42"))
        (resources / "kept.txt").write_text("new")
        write_test(42, "new", '"delete"', "nil")
        for path, previous in timestamps.items():
            os.utime(path, ns=(previous, previous))
        restored = restore("backdated", False)
        if restored.get("changed") != 3 or restored.get("fallback"):
            raise RuntimeError("Changed source, test and resource must all invalidate their prior timestamps")
        record(label="same_size_backdated", restore=restored, actual=build_and_test("backdated"))
        cache.snapshot(root, cache.DEFAULT_METADATA, "compiled-edges")
        (resources / "deleted.txt").unlink()
        write_test(42, "new", "nil", "nil")
        git("add", "-A", "--", "Sources", "Tests")
        restored = restore("removed", True)
        if not restored.get("cleaned") or restored.get("removed") != 1:
            raise RuntimeError("Removed resources require clean cached products")
        record(label="removed_resource", restore=restored, actual=build_and_test("removed"))
        cache.snapshot(root, cache.DEFAULT_METADATA, "compiled-edges")
        (resources / "added.txt").write_text("added")
        write_test(42, "new", "nil", '"added"')
        git("add", "--", "Sources", "Tests")
        restored = restore("added", True)
        if not restored.get("cleaned") or restored.get("missing") != 1:
            raise RuntimeError("New resource paths require normal cold products")
        record(label="added_resource", restore=restored, actual=build_and_test("added"))
        proof["complete"] = True
        (output / "result.json").write_text(json.dumps(proof, indent=2) + "\n")
        print(json.dumps(proof))


if __name__ == "__main__":
    main()
