#!/usr/bin/env python3
"""Fork-only compiled behavior checks for cache invalidation boundaries."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

import ci_swiftpm_cache as cache
import ci_swiftpm_cache_before_symlink_guard as before_cache


def verify_symlink_boundaries(output, record):
    for helper, label, clean_expected in ((before_cache, "before_symlink_guard", False),
                                         (cache, "with_symlink_guard", True)):
        with tempfile.TemporaryDirectory(prefix="cache-symlinks-") as temporary:
            root = Path(temporary)
            fixtures = root / "Fixtures"
            source = root / "Sources/Probe/Probe.swift"
            test = root / "TestsPlugin/ProbeTests.swift"
            for directory in (fixtures, source.parent, test.parent, root / "Sources/App"):
                directory.mkdir(parents=True, exist_ok=True)
            (root / ".gitignore").write_text("/.build/\n")
            (root / "Package.swift").write_text(
                '// swift-tools-version: 6.2\nimport PackageDescription\n'
                'let package = Package(name: "Probe", targets: [.target(name: "Probe"),'
                '.executableTarget(name: "App", dependencies: ["Probe"]),'
                '.testTarget(name: "ProbeTests", dependencies: ["Probe"], path: "TestsPlugin")])\n'
            )
            (root / "Sources/App/main.swift").write_text('import Probe\nprint("CI_LINK_VALUE=\\(Probe.value())")\n')
            for suffix, value in (("old", 41), ("new", 42)):
                (fixtures / f"source-{suffix}.swift").write_text(f"public func value() -> Int {{ {value} }}\n")
                (fixtures / f"test-{suffix}.swift").write_text(
                    'import XCTest\nimport Probe\nfinal class ProbeTests: XCTestCase { '
                    f'func testValue() {{ XCTAssertEqual(Probe.value(), {value}); '
                    f'print("CI_LINK_TEST={value}") }} }}\n'
                )
            source.symlink_to("../../Fixtures/source-old.swift")
            test.symlink_to("../Fixtures/test-old.swift")
            frozen_ns = 1_700_000_000_000_000_000
            for path in root.rglob("*"):
                if path.is_file():
                    os.utime(path, ns=(frozen_ns, frozen_ns), follow_symlinks=False)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)

            def run(phase, arguments):
                path = output / f"{label}-{phase}.log"
                with path.open("w") as log:
                    subprocess.run(arguments, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
                return path.read_text()

            def build_and_value(phase):
                run(phase + "-build", ["swift", "build", "--build-tests", "--build-system", "native"])
                content = run(phase + "-value", ["swift", "run", "--skip-build", "--build-system", "native", "App"])
                markers = [line for line in content.splitlines() if line.startswith("CI_LINK_VALUE=")]
                if len(markers) != 1:
                    raise RuntimeError("Missing actual compiled symlink value")
                return int(markers[0].split("=", 1)[1])

            def test_value(phase, expected):
                content = run(phase + "-test", ["swift", "test", "--skip-build", "--build-system", "native", "--filter", "ProbeTests"])
                if content.count(f"CI_LINK_TEST={expected}") != 1:
                    raise RuntimeError("The linked compiled test did not execute")

            def restore(phase):
                return json.loads(run(phase + "-restore", ["python3", str(Path(helper.__file__).resolve()),
                                                          "restore", "--context", "compiled-symlinks", "--clean-fallback"]))

            def objects():
                return {str(path.relative_to(root)): path.stat().st_mtime_ns for path in (root / ".build").rglob("*.o")}

            if build_and_value("cold") != 41:
                raise RuntimeError("Cold linked source must produce 41")
            test_value("cold", 41)
            helper.snapshot(root, helper.DEFAULT_METADATA, "compiled-symlinks")
            cold_objects = objects()
            for name, mode in helper.tracked_files(root).items():
                if mode in {"100644", "100755"}:
                    path = root / name
                    path.write_bytes(path.read_bytes())
            warm = restore("unchanged")
            if warm.get("fallback") or build_and_value("unchanged") != 41:
                raise RuntimeError("Unchanged symlinks must allow valid warm reuse")
            test_value("unchanged", 41)
            rewritten_objects = [name for name, timestamp in cold_objects.items() if objects().get(name) != timestamp]
            if clean_expected and (warm.get("verified_symlinks") != 2 or rewritten_objects):
                raise RuntimeError("Unchanged verified symlinks must not recompile objects")
            helper.snapshot(root, helper.DEFAULT_METADATA, "compiled-symlinks")
            for link, target in ((source, "../../Fixtures/source-new.swift"), (test, "../Fixtures/test-new.swift")):
                previous = link.lstat().st_mtime_ns
                link.unlink()
                link.symlink_to(target)
                os.utime(link, ns=(previous, previous), follow_symlinks=False)
            subprocess.run(["git", "add", "Sources", "TestsPlugin"], cwd=root, check=True)
            changed = restore("retargeted")
            if bool(changed.get("cleaned")) != clean_expected:
                raise RuntimeError("Symlink retargeting must request clean products only with the guard")
            actual = build_and_value("retargeted")
            if clean_expected and actual != 42:
                raise RuntimeError("Retargeted linked source must produce 42")
            test_value("retargeted", actual)
            record(label=label, unchanged_restore=warm, unchanged_rewritten_objects=len(rewritten_objects),
                   retargeted_restore=changed, retargeted_actual=actual, compiled_test_passed=True)


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
        verify_symlink_boundaries(output, record)
        proof["complete"] = True
        (output / "result.json").write_text(json.dumps(proof, indent=2) + "\n")
        print(json.dumps(proof))


if __name__ == "__main__":
    main()
