#!/usr/bin/env python3
"""TurnSTYLE's SSH-only Codex bridge. No listener, model calls or conversation replies."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import uuid

EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest',
          'PostToolUse', 'Stop', 'Interrupt', 'SessionEnd']
MARKER = '--turnstyle-remote-hook'


def atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.turnstyle-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def quoted(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def names(root):
    result = {}
    path = root / 'session_index.jsonl'
    if not path.exists():
        return result
    with path.open('rb') as stream:
        size = stream.seek(0, 2)
        stream.seek(max(0, size - 8 * 1024 * 1024))
        if size > 8 * 1024 * 1024:
            stream.readline()
        for line in stream:
            try:
                item = json.loads(line)
                if isinstance(item.get('id'), str) and isinstance(item.get('thread_name'), str) and item['thread_name'].strip():
                    result[item['id']] = item['thread_name']
            except (ValueError, TypeError):
                pass
    return result


def history(root, titles):
    # Internal local metadata, opened read-only. No transcript content is queried.
    path = root / 'state_5.sqlite'
    if not path.exists():
        return []
    conn = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2)
    try:
        rows = conn.execute("SELECT id, title, cwd, updated_at, rollout_path FROM threads WHERE archived = 0 AND source IN ('cli','vscode','appServer') ORDER BY updated_at DESC LIMIT 150")
        return [dict(id=row[0], title=titles.get(row[0]) or row[1] or 'Codex conversation',
                     workspace=row[2] or '', updatedAt=row[3], transcriptPath=row[4]) for row in rows]
    finally:
        conn.close()


def install(home, root, folder, request):
    # Validate all inputs/settings before changing anything. Never edit trust or config.toml.
    if not root.is_dir():
        raise ValueError('Codex home was not found; start a local Codex session on the Mini first')
    hook_file = root / 'hooks.json'
    original = hook_file.read_bytes() if hook_file.exists() else None
    settings = json.loads(original) if original is not None else {}
    if not isinstance(settings, dict) or not isinstance(settings.get('hooks', {}), dict):
        raise ValueError('Codex hooks.json is malformed; nothing changed')
    if settings.get('disableAllHooks') or settings.get('allowManagedHooksOnly'):
        raise ValueError('Personal hooks are disabled; nothing changed')
    hooks = settings.get('hooks', {})
    for event in EVENTS:
        groups = hooks.get(event, [])
        if not isinstance(groups, list) or any(not isinstance(g, dict) or not isinstance(g.get('hooks'), list) or any(not isinstance(h, dict) for h in g['hooks']) for g in groups):
            raise ValueError('Existing Codex hook groups are malformed; nothing changed')
    helper = base64.b64decode(request['helper'], validate=True)
    script = base64.b64decode(request['script'], validate=True)
    if hashlib.sha256(helper).hexdigest() != request['helperSHA256']:
        raise ValueError('Helper checksum mismatch')
    # Mac Mini and MacBook are both Apple Silicon; refuse an incompatible deployment.
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise ValueError('This bridge package requires Apple Silicon macOS')
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(folder, 0o700)
    helper_path = folder / 'turnstyle-hook'
    atomic(helper_path, helper, 0o700)
    atomic(folder / 'bridge.py', script)
    if not (folder / 'host-id').exists():
        atomic(folder / 'host-id', str(uuid.uuid4()).encode())
    command = '/usr/bin/env TURNSTYLE_DATA_DIR=' + quoted(folder / 'data') + ' ' + quoted(helper_path) + ' --turnstyle-codex-hook ' + MARKER
    for event in EVENTS:
        groups = []
        for old in hooks.get(event, []):
            group = dict(old)
            group['hooks'] = [h for h in old['hooks'] if not str(h.get('command', '')).endswith(' ' + MARKER)]
            if group['hooks']:
                groups.append(group)
        group = {'hooks': [dict(type='command', command=command, timeout=3)]}
        if event in ['PreToolUse', 'PermissionRequest', 'PostToolUse']:
            group['matcher'] = '*'
        hooks[event] = groups + [group]
    settings['hooks'] = hooks
    backup = None
    if original is not None:
        backup = root / 'turnstyle-backups' / ('hooks-' + str(uuid.uuid4()) + '.json')
        atomic(backup, original)
    atomic(hook_file, json.dumps(settings, indent=2, sort_keys=True).encode())
    return dict(installed=True, backup=str(backup) if backup else None,
                hostID=(folder / 'host-id').read_text().strip())


def snapshot(root, folder, request):
    host_id = (folder / 'host-id').read_text().strip()
    inbox = folder / 'data/events'
    for identifier in request.get('ack', [])[:200]:
        if isinstance(identifier, str) and re.fullmatch(r'[A-Fa-f0-9-]{36}', identifier):
            try:
                (inbox / (identifier + '.json')).unlink()
            except FileNotFoundError:
                pass
    events = []
    for file in sorted(inbox.glob('*.json'), key=lambda p: p.lstat().st_mtime):
        if file.is_symlink() or not file.is_file():
            continue
        try:
            with file.open('rb') as stream:
                data = stream.read(64 * 1024 + 1)
            if len(data) > 64 * 1024:
                raise ValueError('Oversized event')
            item = json.loads(data)
            if not isinstance(item, dict) or not isinstance(item.get('occurredAt'), (int, float)):
                raise ValueError('Invalid event')
        except (ValueError, TypeError):
            quarantine = folder / 'data/invalid-events'
            quarantine.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(quarantine, 0o700)
            destination = quarantine / (str(uuid.uuid4()) + '.json')
            file.replace(destination)
            os.chmod(destination, 0o600)
            continue
        if item.get('provider') == 'codex':
            events.append(item)
            if len(events) == 200:
                break
    events.sort(key=lambda item: item['occurredAt'])
    titles = names(root)
    try:
        chats = history(root, titles)
        history_error = None
        for chat in chats:
            titles.setdefault(chat['id'], chat['title'])
    except (sqlite3.Error, OSError):
        chats = []
        history_error = 'Remote history metadata could not be read; live hook events remain available.'
    try:
        name = subprocess.run(['/usr/sbin/scutil', '--get', 'ComputerName'], capture_output=True, text=True, timeout=2).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        name = ''
    return dict(hostID=host_id, hostName=name or 'Mac Mini', events=events, names=titles,
                history=chats, historyError=history_error)


def main():
    home = Path.home()
    root = Path(os.environ.get('CODEX_HOME', str(home / '.codex')))
    folder = home / 'Library/Application Support/TurnSTYLEBridge'
    request = json.load(sys.stdin)
    result = install(home, root, folder, request) if request.get('action') == 'install' else snapshot(root, folder, request)
    print(json.dumps(result, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)
