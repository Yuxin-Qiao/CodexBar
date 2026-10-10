"""Build and test a dependency-free miniature package at one stable absolute path."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

BASE = Path(os.environ['RUNNER_TEMP']) / 'addition-boundary-evidence'
BASE.mkdir(exist_ok=True)
label = sys.argv[1] if len(sys.argv) > 1 else ''
assert not label or label.isalpha(), 'Use a short alphabetic private experiment label.'
suffix = '-' + label if label else ''
ROOT = BASE / ('private-swift-probe' + suffix)
LOG_BASE = BASE / ('probe-' + label + '-logs') if label else BASE
if label:
    LOG_BASE.mkdir(exist_ok=False)
assert not ROOT.exists(), 'Preserve evidence: use a fresh probe directory.'
ROOT.mkdir()
ORIGINAL = BASE / 'strict-cache.py'
ORIGINAL.write_bytes(subprocess.check_output(['git', 'show', 'cd24c380e10075f6f1141cdc4fa139b16133621d:Scripts/ci_swiftpm_cache.py']))
PROTOTYPE = Path.cwd() / 'Scripts/ci_swiftpm_cache.py'
CONTEXT = 'private-current-schema3-addition-probe'

def run(args, log=None):
    started = time.monotonic()
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=150)
    if log:
        (LOG_BASE / log).write_text(p.stdout + p.stderr)
    if p.returncode:
        raise RuntimeError(str(args) + '\n' + (p.stdout + p.stderr)[-3000:])
    return p.stdout, {'seconds': round(time.monotonic() - started, 3), 'exit_code': p.returncode}

def write(name, content):
    p = ROOT / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return p

write('Package.swift', '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PrivateCIProbe", products: [.library(name: "PrivateCIProbe", targets: ["PrivateCIProbe"])], targets: [.target(name: "PrivateCIProbe", resources: [.process("Resources")]), .testTarget(name: "PrivateCIProbeTests", dependencies: ["PrivateCIProbe"], resources: [.copy("DataFiles")])])
''')
write('Sources/PrivateCIProbe/Value.swift', '''import Foundation
public func originalValue() -> Int { 41 }
public func resourceText() throws -> String { try String(contentsOf: Bundle.module.url(forResource: "kept", withExtension: "txt")!, encoding: .utf8) }
''')
write('Sources/PrivateCIProbe/Resources/kept.txt', 'kept resource\n')
(ROOT / 'Sources/PrivateCIProbe/Resources/alias.txt').symlink_to('kept.txt')
write('Tests/PrivateCIProbeTests/BaselineTests.swift', '''import XCTest
@testable import PrivateCIProbe
final class BaselineTests: XCTestCase { func testValue() { XCTAssertEqual(originalValue(), 41) } }
''')
write('Tests/PrivateCIProbeTests/DataFiles/kept.txt', 'fixture resource\n')
write('.gitignore', '.build/\n.seed-build/\n.external-input/\n')
run(['git', 'init', '-q'])
run(['git', 'add', '.'])
run(['git', '-c', 'user.name=CI Probe', '-c', 'user.email=ci-probe@example.invalid', 'commit', '-qm', 'Private baseline'])
_, cold = run(['swift', 'test', '--no-parallel'], 'probe-cold-seed.log')
run(['python3', str(ORIGINAL), 'snapshot', '--context', CONTEXT])
seed = ROOT / '.seed-build'
shutil.copytree(ROOT / '.build', seed, symlinks=True)
results = {'toolchain': run(['swift', '--version'])[0].strip(), 'cold_seed': cold,
           'original_sha256': hashlib.sha256(ORIGINAL.read_bytes()).hexdigest(),
           'prototype_sha256': hashlib.sha256(PROTOTYPE.read_bytes()).hexdigest(), 'cases': []}

def reset():
    run(['git', 'restore', '--staged', '--worktree', '.'])
    # Only this newly created disposable package; preserve logs/results outside it.
    run(['git', 'clean', '-fdq'])
    shutil.rmtree(ROOT / '.build')
    shutil.copytree(seed, ROOT / '.build', symlinks=True)

def add_source(resource_edit=False, backdated=False):
    p = write('Sources/PrivateCIProbe/Extra.swift', 'public func introducedValue() -> Int { 42 }\n')
    if backdated:
        os.utime(p, ns=(1_000_000_000, 1_000_000_000))
    extra = '; XCTAssertEqual(try resourceText(), "updated resource\\n")' if resource_edit else ''
    write('Tests/PrivateCIProbeTests/AddedTests.swift', 'import XCTest\n@testable import PrivateCIProbe\nfinal class AddedTests: XCTestCase { func testAdded() throws { XCTAssertEqual(introducedValue(), 42)' + extra + ' } }\n')
    if resource_edit:
        write('Sources/PrivateCIProbe/Resources/kept.txt', 'updated resource\n')

for name, helper, edit, backdated, tests_only in [
    ('production-source-addition', ORIGINAL, False, False, False),
    ('prototype-source-addition', PROTOTYPE, False, False, False),
    ('prototype-backdated-source-addition', PROTOTYPE, False, True, False),
    ('prototype-addition-and-resource-edit', PROTOTYPE, True, False, False),
    ('prototype-test-addition', PROTOTYPE, False, False, True),
]:
    reset()
    if tests_only:
        write('Tests/PrivateCIProbeTests/AddedTests.swift', 'import XCTest\n@testable import PrivateCIProbe\nfinal class AddedTests: XCTestCase { func testAdded() { XCTAssertEqual(originalValue(), 41) } }\n')
    else:
        add_source(edit, backdated)
    run(['git', 'add', '.'])
    stdout, restore_time = run(['python3', str(helper), 'restore', '--context', CONTEXT, '--clean-fallback'])
    restored = json.loads(stdout.splitlines()[-1])
    assert restored.get('cleaned', False) == (helper == ORIGINAL), restored
    if helper == PROTOTYPE:
        assert restored['verified_symlinks'] == 1
    if backdated:
        assert (ROOT / 'Sources/PrivateCIProbe/Extra.swift').stat().st_mtime_ns > 1_000_000_000
    _, tested = run(['swift', 'test', '--no-parallel'], name + '.log')
    log = (LOG_BASE / (name + '.log')).read_text()
    assert 'AddedTests.testAdded' in log or 'AddedTests testAdded' in log
    assert 'Executed 2 tests, with 0 failures' in log
    record = {'name': name, 'restore': restored, 'restore_process': restore_time,
              'build_and_complete_miniature_tests': tested, 'all_miniature_tests': 2,
              'new_code_value_verified': not tests_only, 'edited_resource_verified': edit,
              'backdated_new_source_invalidated': backdated}
    results['cases'].append(record)
    print(json.dumps(record), flush=True)

for name in ['source-removal', 'resource-addition', 'swift-extension-copy-resource-addition',
             'new-swift-symlink', 'regular-to-symlink-with-addition',
             'stable-link-to-untracked-target-with-addition', 'stable-link-to-external-target-with-addition',
             'added-source-with-symlink-ancestor']:
    reset()
    if name == 'source-removal':
        (ROOT / 'Sources/PrivateCIProbe/Value.swift').unlink()
    elif name == 'resource-addition':
        write('Sources/PrivateCIProbe/Resources/added.txt', 'resource\n')
    elif name == 'swift-extension-copy-resource-addition':
        write('Tests/PrivateCIProbeTests/DataFiles/not-a-source.swift', '// Copied fixture.\n')
    elif name == 'new-swift-symlink':
        (ROOT / 'Sources/PrivateCIProbe/NewLink.swift').symlink_to('Value.swift')
    elif name == 'regular-to-symlink-with-addition':
        add_source()
        (ROOT / 'Sources/PrivateCIProbe/Value.swift').unlink()
        (ROOT / 'Sources/PrivateCIProbe/Value.swift').symlink_to('Extra.swift')
    elif name in {'stable-link-to-untracked-target-with-addition', 'stable-link-to-external-target-with-addition'}:
        target = ROOT / 'Sources/PrivateCIProbe/Resources/kept.txt'
        # Snapshot a stable payload whose target cannot be verified in both snapshots.
        if 'untracked' in name:
            run(['git', 'rm', '--cached', str(target.relative_to(ROOT))])
        else:
            link = ROOT / 'Sources/PrivateCIProbe/Resources/alias.txt'
            link.unlink()
            link.symlink_to('/dev/null')
            run(['git', 'add', str(link.relative_to(ROOT))])
        run(['python3', str(ORIGINAL), 'snapshot', '--context', CONTEXT])
        add_source()
        run(['git', 'add', 'Sources/PrivateCIProbe/Extra.swift', 'Tests/PrivateCIProbeTests/AddedTests.swift'])
    else:
        directory = ROOT / '.external-input'
        directory.mkdir(exist_ok=True)
        write('.external-input/Extra.swift', 'public func introducedValue() -> Int { 42 }\n')
        (ROOT / 'Sources/PrivateCIProbe/Redirect').symlink_to('../../.external-input')
        # Stage as a regular file, then replace its parent with a link after staging.
        (ROOT / 'Sources/PrivateCIProbe/Redirect').unlink()
        write('Sources/PrivateCIProbe/Redirect/Extra.swift', 'public func introducedValue() -> Int { 42 }\n')
        run(['git', 'add', 'Sources/PrivateCIProbe/Redirect/Extra.swift'])
        shutil.rmtree(ROOT / 'Sources/PrivateCIProbe/Redirect')
        (ROOT / 'Sources/PrivateCIProbe/Redirect').symlink_to('../../.external-input')
    if name not in {'added-source-with-symlink-ancestor', 'stable-link-to-untracked-target-with-addition', 'stable-link-to-external-target-with-addition'}:
        run(['git', 'add', '-A'])
    fresh = write('Tests/PrivateCIProbeTests/BaselineTests.swift', (ROOT / 'Tests/PrivateCIProbeTests/BaselineTests.swift').read_text()).stat().st_mtime_ns
    stdout, elapsed = run(['python3', str(PROTOTYPE), 'restore', '--context', CONTEXT, '--clean-fallback'])
    restored = json.loads(stdout.splitlines()[-1])
    assert restored.get('cleaned') is True and restored['restored'] == 0, restored
    assert (ROOT / 'Tests/PrivateCIProbeTests/BaselineTests.swift').stat().st_mtime_ns == fresh
    record = {'name': name, 'restore': restored, 'restore_process': elapsed,
              'conservative_clean_before_any_old_mtime_write': True}
    results['cases'].append(record)
    print(json.dumps(record), flush=True)

results['limitations'] = 'Hosted miniature package boundary proof on the selected Xcode; project proof is recorded separately.'
(BASE / ('source-addition-probe-results' + suffix + '.json')).write_text(json.dumps(results, indent=2) + '\n')
reset()
print('Private schema-3 probe complete.', flush=True)
