#!/usr/bin/env python3
"""Fork-only hosted experiment; not part of the proposed production pipeline."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import time

import ci_swiftpm_cache as cache

ROOT = Path(__file__).resolve().parent.parent
CORE_INPUT = "Sources/CodexBarCore/PathEnvironment.swift"
TEST_INPUT = "Tests/CodexBarTests/CICacheBehaviorProbeTests.swift"
PROBE_MARKER = "// CI cache experiment probe; not included in the performance PR."


def output_root():
    path = Path(os.environ["CI_CACHE_BENCH_DIR"])
    path.mkdir(parents=True, exist_ok=True)
    return path


def read_result():
    path = output_root() / "result.json"
    return json.loads(path.read_text()) if path.exists() else {"phases": {}}


def update_result(**values):
    result = read_result()
    result.update(values)
    (output_root() / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def command_output(*arguments):
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def toolchain_context():
    description = {
        "xcode": command_output("xcodebuild", "-version"),
        "swift": command_output("swift", "--version"),
        "sdk": command_output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": command_output("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "sdk_path": command_output("xcrun", "--sdk", "macosx", "--show-sdk-path"),
        "architecture": platform.machine(),
        "build_system": "native",
        "configuration": "debug",
        "test_group_size": 8,
        "test_timeout_seconds": 120,
    }
    if "default: native" not in command_output("swift", "build", "--help"):
        raise RuntimeError("This experiment requires the hosted native SwiftPM default")
    for name in ("Package.swift", "Package.resolved", "Scripts/ci_swiftpm_cache.py"):
        description[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    fingerprint = hashlib.sha256(json.dumps(description, sort_keys=True).encode()).hexdigest()
    return fingerprint, description


def prepare(mode):
    value = 42 if mode == "changed" else 41
    source = ROOT / CORE_INPUT
    original = source.read_text()
    if PROBE_MARKER in original:
        raise RuntimeError("Experiment inputs must start from a fresh checkout")
    source.write_text(original + f"\n{PROBE_MARKER}\npublic enum CICacheBehaviorProbe {{\n    public static func value() -> Int {{ {value} }}\n}}\n")
    (ROOT / TEST_INPUT).write_text(
        "import CodexBarCore\nimport Testing\n\n@Suite struct CICacheBehaviorProbeTests {\n"
        f"    @Test func `rebuilt source returns the current value`() {{\n        #expect(CICacheBehaviorProbe.value() == {value})\n    }}\n}}\n"
    )
    subprocess.run(["git", "add", "--", CORE_INPUT, TEST_INPUT], cwd=ROOT, check=True)
    context, description = toolchain_context()
    update_result(
        mode=mode,
        git_head=command_output("git", "rev-parse", "HEAD"),
        product_base=os.environ["CI_CACHE_PRODUCT_BASE"],
        context=context,
        toolchain=description,
        behavior_probe={"source": CORE_INPUT, "test": TEST_INPUT, "expected_value": value},
    )
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"context={context}\n")
    print(json.dumps({"mode": mode, "context": context, "expected_value": value}))


def objects():
    return {
        str(path.relative_to(ROOT / ".build")): [path.stat().st_mtime_ns, path.stat().st_size]
        for path in (ROOT / ".build").rglob("*.o") if path.is_file()
    }


def measured_command(name, arguments):
    started = time.monotonic()
    environment = os.environ.copy()
    environment.update(TERM="dumb", CODEXBAR_TEST_GROUP_SIZE="8", CODEXBAR_TEST_SUITE_TIMEOUT="120", CODEXBAR_TEST_RETRY_NON_TIMEOUT_FAILURES="0")
    log = output_root() / f"{name}.log"
    child = subprocess.Popen(arguments, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", start_new_session=True)
    try:
        with log.open("w") as output:
            for line in child.stdout:
                output.write(line)
                print(line, end="", flush=True)
        result = child.wait()
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
    elapsed = time.monotonic() - started
    data = read_result()
    data["phases"][name] = {"seconds": elapsed, "exit_code": result}
    update_result(phases=data["phases"])
    if result:
        raise RuntimeError(f"{name} exited with {result}; result and log retained")
    return log


def seed():
    measured_command("cold-build", ["swift", "build", "--build-tests"])
    data = read_result()
    started = time.monotonic()
    inputs = cache.snapshot(ROOT, cache.DEFAULT_METADATA, data["context"])
    update_result(snapshot=inputs, snapshot_seconds=time.monotonic() - started, seeded_objects=len(objects()))


def case(mode):
    data = read_result()
    root_fd = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY)
    try:
        metadata = cache.read_metadata(root_fd, cache.DEFAULT_METADATA, data["context"])
    finally:
        os.close(root_fd)
    if not metadata:
        raise RuntimeError("A nonempty, matching baseline cache is required")
    started = time.monotonic()
    restored = cache.restore(ROOT, cache.DEFAULT_METADATA, data["context"]) if mode != "control" else {"restored": 0, "control": True}
    update_result(input_restore=restored, input_restore_seconds=time.monotonic() - started)
    if mode != "control" and (restored.get("fallback") or not restored["restored"]):
        raise RuntimeError("Optimized case did not restore verified input timestamps")
    if mode == "changed" and restored["changed"] != 2:
        raise RuntimeError("Changed core and test files must both retain fresh timestamps")
    before = objects()
    build_log = measured_command("build", ["swift", "build", "--build-tests"])
    after = objects()
    common = before.keys() & after.keys()
    update_result(
        objects_before=len(before),
        objects_after=len(after),
        object_mtimes_changed=sum(before[key][0] != after[key][0] for key in common),
        new_objects=len(after.keys() - before.keys()),
        compiling_lines=len(re.findall(r"(?m)^.*\bCompiling\b.*$", build_log.read_text())),
    )
    if mode == "changed" and not any(before[key][0] != after[key][0] for key in common):
        raise RuntimeError("Changed source did not rebuild any original object")
    test_log = measured_command("full-tests", ["make", "test"])
    content = test_log.read_text()
    inventory = [selection for group in re.findall(r"(?m)^Selected group \d+: (\[.*\])$", content) for selection in json.loads(group)]
    counters = {name: int(value) for name, value in re.findall(r"(?m)^- ([\w -]+): (\d+)$", content)}
    if not inventory or counters.get("Selected selections") != len(inventory):
        raise RuntimeError("Full test selection manifest was not verified")
    if counters.get("Discovered selections") != len(inventory):
        raise RuntimeError("Experiment must execute the entire discovered inventory")
    if not any("CICacheBehaviorProbeTests" in name for name in inventory):
        raise RuntimeError("Actual compiled behavior probe was not selected")
    update_result(
        inventory=inventory,
        inventory_sha256=hashlib.sha256(json.dumps(inventory).encode()).hexdigest(),
        test_counters=counters,
        complete=True,
    )
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        data = read_result()
        with open(summary, "a") as output:
            output.write(f"\n### SwiftPM cache experiment: {mode}\n\n")
            output.write(f"- Build: {data['phases']['build']['seconds']:.1f}s\n")
            output.write(f"- Tests: {data['phases']['full-tests']['seconds']:.1f}s\n")
            output.write(f"- Object mtimes changed: {data['object_mtimes_changed']}\n")
            output.write(f"- Full inventory: {len(inventory)} selections\n")
            output.write(f"- Behavior probe expected value: {data['behavior_probe']['expected_value']}\n")


def marker(name, finish):
    path = output_root() / f"{name}.started"
    if not finish:
        path.write_text(str(time.monotonic()))
    else:
        elapsed = time.monotonic() - float(path.read_text())
        data = read_result()
        data["phases"][name] = {"seconds": elapsed}
        update_result(phases=data["phases"])


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


def main():
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "seed", "case", "marker"))
    parser.add_argument("--mode", choices=("seed", "control", "restored", "changed"), default="seed")
    parser.add_argument("--name")
    parser.add_argument("--finish", action="store_true")
    args = parser.parse_args()
    if args.action == "prepare":
        prepare(args.mode)
    elif args.action == "seed":
        seed()
    elif args.action == "case":
        case(args.mode)
    else:
        marker(args.name, args.finish)


if __name__ == "__main__":
    main()
