#!/usr/bin/env python3
"""Exercise the Codex adapter through the packaged helper with isolated storage."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile

dist = Path(__file__).resolve().parents[1] / 'dist'
archive = max(dist.glob('TurnSTYLE-*-macos-*.zip'), key=lambda path: path.stat().st_mtime)
with tempfile.TemporaryDirectory(prefix='turnstyle-codex-check-') as folder:
    package = Path(folder) / 'package'
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(package)], check=True)
    helper = package / 'TurnSTYLE.app/Contents/Helpers/turnstyle-hook'
    env = dict(os.environ, TURNSTYLE_DATA_DIR=folder)
    def send(i):
        payload = {'hook_event_name': 'Stop', 'session_id': f'codex-fixture-{i}',
                   'cwd': '/fixture', 'transcript_path': '/fixture/rollout.jsonl', 'last_assistant_message': 'PRIVATE ASSISTANT TEXT',
                   'tool_input': {'secret': 'PRIVATE TOOL INPUT'}}
        result = subprocess.run([str(helper), '--turnstyle-codex-hook'], input=json.dumps(payload).encode(),
                                env=env, capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stdout == b'' and result.stderr == b''
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(send, range(40)))
    files = list((Path(folder) / 'events').glob('*.json'))
    assert len(files) == 40
    events = [json.loads(p.read_text()) for p in files]
    assert {e['provider'] for e in events} == {'codex'}
    assert {e['kind'] for e in events} == {'responseFinished'}
    assert len({e['sessionID'] for e in events}) == 40
    assert all('PRIVATE' not in p.read_text() for p in files)
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in files)
    print('PASS 40 concurrent Codex events, correct provider/status, no private payloads, owner-only files')
    for payload in [b'not-json', json.dumps({'hook_event_name': 'Stop', 'session_id': 'parent', 'agent_id': 'child', 'transcript_path': '/fixture/rollout.jsonl'}).encode()]:
        result = subprocess.run([str(helper), '--turnstyle-codex-hook'], input=payload,
                                env=env, capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stdout == b''
    assert len(list((Path(folder) / 'events').glob('*.json'))) == 40
    print('PASS malformed input and subagent events create no Codex queue rows')
