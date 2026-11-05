#!/usr/bin/env python3
"""Cast's opt-in Agent Desktop adapter. Local user boundary, not a shell sandbox.
Only accepts JSON on stdin; never forwards arbitrary CLI flags. Revocation prevents
new commands; already delivered AX actions cannot be rolled back.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path.home() / 'Library/Application Support/Cast/DesktopSessions'
CLI = next((p for p in ['/opt/homebrew/bin/agent-desktop', '/usr/local/bin/agent-desktop'] if Path(p).is_file()), None)


def fail(message):
    raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text())


def check_lease(directory):
    if (directory / 'revoked').exists():
        fail('Desktop access was stopped in Cast. Ask the user to select a window again.')
    grant = read_json(directory / 'grant.json')
    now = time.time()
    if now > grant['expires'] or now - (directory / 'heartbeat').stat().st_mtime > 20:
        fail('Desktop access expired or Cast is no longer active.')
    return grant


def run(args, directory=None):
    if not CLI:
        fail('Agent Desktop is not installed on this Mac.')
    child = subprocess.Popen([CLI] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 20
    try:
        while True:
            if directory:
                check_lease(directory)
            if time.monotonic() > deadline:
                fail('Desktop command timed out; observe before retrying an action.')
            try:
                out, err = child.communicate(timeout=0.2)
                break
            except subprocess.TimeoutExpired:
                pass
        if len(out) > 2 * 1024 * 1024:
            fail('Desktop response exceeded the bounded snapshot size.')
        result = json.loads(out)
        if not result.get('ok'):
            # Preserve disposition: caller must observe, not blindly retry.
            return result
        return result
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate()


def references(value):
    result = set()
    if isinstance(value, dict):
        ref = value.get('ref_id')
        if isinstance(ref, str) and re.fullmatch(r'@[a-zA-Z0-9]+:e[0-9]+', ref):
            result.add(ref)
        for item in value.values():
            result.update(references(item))
    elif isinstance(value, list):
        for item in value:
            result.update(references(item))
    return result


def command(request):
    if not isinstance(request, dict):
        fail('Expected a JSON object.')
    session = request.get('session', '')
    if not isinstance(session, str) or not re.fullmatch(r'[A-Fa-f0-9-]{36}', session):
        fail('A Cast desktop session ID is required.')
    directory = ROOT / session
    grant = check_lease(directory)
    # Serialize across sessions targeting the same process. Parallel cursors do not
    # isolate app state. flock is released even on client failure.
    with open(ROOT / ('app-' + str(int(grant['pid'])) + '.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        grant = check_lease(directory)
        # A failed re-observation must not leave refs from an older view usable.
        # Clear before inventory as well: window enumeration can itself time out.
        if request.get('action') == 'snapshot':
            (directory / 'refs.json').write_text(json.dumps({'created': 0, 'refs': []}))
        inventory = run(['list-windows'], directory)
        if not inventory.get('ok'):
            return inventory
        window = next((w for w in inventory['data'] if w['id'] == grant['window']), None)
        if not window or window.get('pid') != grant['pid'] or window.get('process_instance') != grant['processInstance']:
            fail('The selected window closed or its process changed. Select it again in Cast.')
        action = request.get('action')
        if action == 'snapshot':
            result = run(['snapshot', '--app', grant['app'], '--window-id', grant['window'],
                          '--max-depth', '20', '--compact', '--timeout-ms', '15000'], directory)
            if result.get('ok'):
                (directory / 'refs.json').write_text(json.dumps({'created': time.time(), 'refs': sorted(references(result))}))
            return result
        if grant['mode'] != 'interact':
            fail('This Cast desktop session is inspect-only.')
        arity = {'click': 0, 'toggle': 0, 'check': 0, 'uncheck': 0, 'expand': 0, 'collapse': 0, 'set-value': 1, 'select': 1, 'scroll': 0}
        if action not in arity:
            fail('Unsupported action. Allowed: snapshot, click, toggle, check, uncheck, expand, collapse, set-value, select, scroll. No physical input or shell commands.')
        state = read_json(directory / 'refs.json')
        ref = request.get('ref')
        if ref not in state['refs'] or time.time() - state['created'] > 60:
            fail('Take a fresh snapshot of the selected window before acting.')
        args = [action, ref]
        if action == 'scroll':
            direction, amount = request.get('direction', 'down'), request.get('amount', 3)
            if direction not in ['up','down','left','right'] or type(amount) is not int or not 1 <= amount <= 20:
                fail('Scroll needs a supported direction and 1–20 units.')
            args += ['--direction', direction, '--amount', str(amount)]
        if arity[action]:
            value = request.get('value')
            if not isinstance(value, str) or len(value) > 16000 or value.startswith('-'):
                fail('A bounded non-option value is required.')
            args.append(value)
        # Invalidate all refs before action, including ambiguous delivery/failure.
        (directory / 'refs.json').write_text(json.dumps({'created': 0, 'refs': []}))
        check_lease(directory)
        return run(args, directory)


def main():
    try:
        raw = sys.stdin.buffer.read(32769)
        if len(raw) > 32768:
            fail('Request too large.')
        result = command(json.loads(raw))
    except Exception as error:
        result = {'ok': False, 'error': {'code': 'CAST_DESKTOP_REFUSED', 'message': str(error)}}
    print(json.dumps(result))
    return 0 if result.get('ok') else 1


if __name__ == '__main__':
    sys.exit(main())
