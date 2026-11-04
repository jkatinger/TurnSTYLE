#!/usr/bin/env python3
"""Exercise the packaged helper with real stdin, fragmented input and concurrency."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

dist = Path(__file__).resolve().parents[1] / 'dist'
archive = max(dist.glob('TurnSTYLE-*-macos-*.zip'), key=lambda path: path.stat().st_mtime)
with tempfile.TemporaryDirectory(prefix='turnstyle-helper-check-') as folder:
    package = Path(folder) / 'package'
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(package)], check=True)
    helper = package / 'TurnSTYLE.app/Contents/Helpers/turnstyle-hook'
    env = dict(os.environ, TURNSTYLE_DATA_DIR=folder)
    def send(i):
        payload = json.dumps({'hook_event_name': 'UserPromptSubmit', 'session_id': f'fixture-{i}',
                              'prompt': f'Fixture task {i}', 'cwd': '/fixture'}).encode()
        result = subprocess.run([str(helper), '--turnstyle-hook'], input=payload,
                                env=env, capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stdout == b''
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(send, range(40)))
    events = list((Path(folder) / 'events').glob('*.json'))
    assert len(events) == 40
    assert len({json.loads(p.read_text())['sessionID'] for p in events}) == 40
    print('PASS 40 concurrent hook deliveries, no event loss')
    p = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    p.stdin.write(b'{"session_id":"fragmented",'); p.stdin.flush()
    time.sleep(0.05)
    p.stdin.write(b'"hook_event_name":"Stop"}'); p.stdin.close()
    assert p.wait(timeout=5) == 0
    assert p.stdout.read() == b''
    assert len(list((Path(folder) / 'events').glob('*.json'))) == 41
    print('PASS fragmented stdin is read completely')
    invalid = subprocess.run([str(helper)], input=b'not-json', env=env, capture_output=True, timeout=5)
    assert invalid.returncode == 0 and invalid.stdout == b''
    assert len(list((Path(folder) / 'events').glob('*.json'))) == 41
    print('PASS malformed input fails open without creating a session')
    modes = [p.stat().st_mode & 0o777 for p in (Path(folder) / 'events').glob('*.json')]
    assert set(modes) == {0o600}
    print('PASS event files are readable only by their owner')

    oversized = json.dumps({'hook_event_name': 'Stop', 'session_id': 'oversized',
                            'unused': 'x' * (8 * 1024 * 1024)}).encode()
    result = subprocess.run([str(helper)], input=oversized, env=env, capture_output=True, timeout=5)
    assert result.returncode == 0 and result.stdout == b''
    assert len(list((Path(folder) / 'events').glob('*.json'))) == 41
    assert Path(folder).stat().st_mode & 0o777 == 0o700
    print('PASS oversized stdin fails open without storing an event; data root is owner-only')
