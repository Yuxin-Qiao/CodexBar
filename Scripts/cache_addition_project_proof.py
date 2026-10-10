"""Fork-only paired proof, same root and baseline for both cache policies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path.cwd()
evidence = Path(os.environ['RUNNER_TEMP']) / 'addition-evidence'
evidence.mkdir(exist_ok=True)
candidate = root / 'Scripts/ci_swiftpm_cache.py'
strict = Path(os.environ['RUNNER_TEMP']) / 'strict-cache.py'
strict.write_bytes(subprocess.check_output(['git', 'show', 'cd24c380e10075f6f1141cdc4fa139b16133621d:Scripts/ci_swiftpm_cache.py']))
metrics = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
           'toolchain': subprocess.check_output(['swift', '--version'], text=True).strip(),
           'cases': [], 'context_note': 'Both restore policies consume the same candidate-context baseline; only path-set policy differs.'}

def run(name, args):
    started = time.monotonic()
    with (evidence / (name + '.log')).open('w') as log:
        result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT)
    duration = round(time.monotonic() - started, 3)
    print(json.dumps({'stage': name, 'seconds': duration, 'exit_code': result.returncode}), flush=True)
    if result.returncode:
        print((evidence / (name + '.log')).read_text(errors='replace')[-6000:], flush=True)
        raise RuntimeError(name + ' failed')
    return duration

source = root / 'Sources/AdaptiveRefreshCore/CICacheAdditionProof.swift'
test = root / 'Tests/AdaptiveReplayKitTests/CICacheAdditionProofTests.swift'
assert not source.exists() and not test.exists()
try:
    lane = os.environ['CACHE_LANE']
    context = json.loads(subprocess.check_output(['python3', str(candidate), 'context', '--lane', lane], text=True))['context']
    metrics['context'] = context
    metrics['baseline_build_seconds'] = run('baseline-build', ['swift', 'build', '--build-tests'])
    run('baseline-snapshot', ['python3', str(candidate), 'snapshot', '--context', context])
    seed = Path(os.environ['RUNNER_TEMP']) / 'addition-build-seed'
    # This macOS clone stays on the same runner; products return to the same root.
    subprocess.run(['cp', '-cR', str(root / '.build'), str(seed)], check=True)
    source.write_text('public func ciCacheAdditionProofValue() -> Int { 42 }\n')
    test.write_text('import AdaptiveRefreshCore\nimport Testing\n@Suite struct CICacheAdditionProofTests {\n    @Test func `new source is compiled`() { #expect(ciCacheAdditionProofValue() == 42) }\n}\n')
    subprocess.run(['git', 'add', str(source), str(test)], check=True)
    for name, helper in [('candidate', candidate), ('strict-control', strict)]:
        if name != 'candidate':
            shutil.rmtree(root / '.build')
            subprocess.run(['cp', '-cR', str(seed), str(root / '.build')], check=True)
        restore_seconds = run(name + '-restore', ['python3', str(helper), 'restore', '--context', context, '--clean-fallback'])
        restored = json.loads((evidence / (name + '-restore.log')).read_text().splitlines()[-1])
        assert restored.get('cleaned', False) == (name == 'strict-control'), restored
        if name == 'candidate':
            assert restored['source_additions'] == 2 and restored['verified_symlinks'] >= 7
        build_seconds = run(name + '-build', ['swift', 'build', '--build-tests'])
        run(name + '-new-source-test', ['swift', 'test', '--skip-build', '--no-parallel', '--filter', 'CICacheAdditionProofTests'])
        log = (evidence / (name + '-new-source-test.log')).read_text()
        assert 'passed' in log and 'new source is compiled' in log
        metrics['cases'].append({'policy': name, 'restore': restored, 'restore_seconds': restore_seconds,
                                 'build_seconds': build_seconds, 'new_value_42_test_passed': True})
        if name == 'candidate' and lane == 'macos26-arm64':
            os.environ.update(CODEXBAR_TEST_GROUP_SIZE='8', CODEXBAR_TEST_SUITE_TIMEOUT='120',
                              CODEXBAR_TEST_RETRY_NON_TIMEOUT_FAILURES='0')
            metrics['complete_two_worker_test_seconds'] = run('complete-two-worker-tests', ['./Scripts/test.sh', '--direct-workers', '2'])
    if lane == 'macos26-arm64':
        metrics['complete_make_test_seconds'] = run('complete-make-test', ['make', 'test'])
finally:
    (evidence / 'metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    subprocess.run(['git', 'reset', '--', str(source), str(test)], check=True)
    source.unlink(missing_ok=True)
    test.unlink(missing_ok=True)
    subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--'], check=True)
