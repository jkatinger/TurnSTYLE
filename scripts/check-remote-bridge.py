#!/usr/bin/env python3
"""Isolated bridge checks: real temporary files and SQLite, no SSH or live settings."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import uuid

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).with_name('remote-codex-bridge.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
with tempfile.TemporaryDirectory(prefix='turnstyle-remote-check-') as temp:
    home = Path(temp); root = home / '.codex'; root.mkdir()
    folder = home / 'Library/Application Support/TurnSTYLEBridge'
    original = b'{ "hooks": { "Stop": [{"hooks":[{"type":"command","command":"existing"}]}] }, "description":"Keep me" }'
    (root / 'hooks.json').write_bytes(original)
    config = b'notify = ["existing"]\n[hooks.state]\n'
    (root / 'config.toml').write_bytes(config)
    helper = b'#!/bin/sh\nexit 0\n'
    request = dict(helper=base64.b64encode(helper).decode(), script=base64.b64encode(b'# fixture').decode(), helperSHA256=hashlib.sha256(helper).hexdigest())
    installed = bridge.install(home, root, folder, request)
    assert Path(installed['backup']).read_bytes() == original
    assert (root / 'config.toml').read_bytes() == config
    settings = json.loads((root / 'hooks.json').read_bytes())
    assert settings['hooks']['Stop'][0]['hooks'][0]['command'] == 'existing'
    for event in bridge.EVENTS:
        assert settings['hooks'][event][-1]['hooks'][0]['command'].endswith(' ' + bridge.MARKER)
    assert bridge.install(home, root, folder, request)['hostID'] == installed['hostID']
    assert json.loads((root / 'hooks.json').read_bytes()) == settings
    print('PASS remote install preserves hooks, exact backup, trust/config, permissions and stable identity')
    db = sqlite3.connect(root / 'state_5.sqlite')
    db.execute('CREATE TABLE threads (id TEXT,title TEXT,cwd TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER,source TEXT)')
    db.execute("INSERT INTO threads VALUES ('chat','Old name','/project',1800000000,'/remote/rollout',0,'vscode')")
    db.execute("INSERT INTO threads VALUES ('child','Child','/project',1800000001,'/remote/child',0,'subAgent')")
    db.commit(); db.close()
    (root / 'session_index.jsonl').write_text('{"id":"chat","thread_name":"Renamed remote chat"}\n{incomplete')
    inbox = folder / 'data/events'; inbox.mkdir(parents=True)
    event_id = str(uuid.uuid4())
    event = dict(id=event_id,provider='codex',sessionID='chat',kind='responseFinished',occurredAt=1)
    file = inbox / (event_id + '.json'); file.write_text(json.dumps(event))
    (inbox / 'damaged.json').write_bytes(b'{broken')
    (inbox / 'oversized.json').write_bytes(b' ' * (64 * 1024 + 1))
    first = bridge.snapshot(root, folder, {})
    assert first['events'] == [event] and file.exists()
    assert len(list((folder / 'data/invalid-events').glob('*.json'))) == 2
    assert first['history'][0]['title'] == 'Renamed remote chat' and len(first['history']) == 1
    assert first['names']['chat'] == 'Renamed remote chat'
    assert bridge.snapshot(root, folder, {})['events'] == [event]
    final = bridge.snapshot(root, folder, dict(ack=[event_id, '../../../outside']))
    assert final['events'] == [] and not file.exists()
    print('PASS remote events replay until acknowledged; names/history are read-only; subagents excluded')
    broken_root = home / 'broken'; broken_root.mkdir(); (broken_root/'hooks.json').write_bytes(b'{broken')
    try:
        bridge.install(home, broken_root, home/'untouched', request)
        raise AssertionError('Malformed settings accepted')
    except ValueError:
        pass
    assert (broken_root/'hooks.json').read_bytes() == b'{broken' and not (home/'untouched').exists()
    print('PASS malformed remote settings are preserved before any installation writes')
