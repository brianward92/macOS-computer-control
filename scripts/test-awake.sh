#!/usr/bin/env bash
# Opt-in live power test. Temporarily wakes/holds the display; sends no input.
# Tests the installed helper beyond caffeinate -u's default five-second timeout.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export MACCTL=${MACCTL:-"$PWD/bin/macctl"}
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --sleep-first ) ]]; then
    echo "usage: bash scripts/test-awake.sh [--sleep-first]" >&2
    exit 2
fi
export MACCTL_TEST_SLEEP_FIRST=${1:-}
python3 - <<'PY'
import json
import os
import re
import subprocess
import tempfile
import time

macctl = os.environ['MACCTL']
with tempfile.TemporaryDirectory(prefix='macctl-awake-test-') as scratch:
    env = dict(os.environ, MACCTL_CACHE_DIR=scratch)
    def cli(*args, expected=0):
        result = subprocess.run([macctl, *args], env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return json.loads(result.stdout)

    def has_activity(pid):
        text = subprocess.check_output(['pmset', '-g', 'assertions'], text=True)
        return any(re.search(r'pid\s+' + str(pid) + r'\(caffeinate\):', line)
                   and 'UserIsActive' in line for line in text.splitlines())

    def wait_for(predicate, timeout=3):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.1)
        assert predicate(), 'condition did not settle'

    def assert_ready_without_recovery():
        status = cli('doctor')
        assert status['ok'] and not status['screenLocked'], status
        assert not status.get('wokeScreen'), ('display/session needed recovery during hold', status)

    driver = subprocess.Popen(['/bin/sleep', '60'])
    try:
        if os.environ.get('MACCTL_TEST_SLEEP_FIRST'):
            subprocess.run(['pmset', 'displaysleepnow'], check=True)
            time.sleep(1)
        holder = cli('awake', '--while-pid', str(driver.pid))['holding']
        wait_for(lambda: has_activity(holder))
        time.sleep(6)
        assert has_activity(holder), 'process-bound user activity expired after five seconds'
        assert_ready_without_recovery()
        time.sleep(7)
        assert has_activity(holder), 'process-bound activity did not survive the observed display relapse interval'
        assert_ready_without_recovery()
        cli('awake', '--seconds', '0', expected=2)
        assert cli('awake', '--status')['holding'] == holder, 'invalid request released existing hold'
        replacement = cli('awake', '--while-pid', str(driver.pid))['holding']
        assert replacement != holder
        wait_for(lambda: has_activity(replacement) and not has_activity(holder))
        holder = replacement
        assert_ready_without_recovery()
        driver.terminate()
        driver.wait(timeout=3)
        wait_for(lambda: not has_activity(holder))
        wait_for(lambda: cli('awake', '--status')['holding'] is None)
        print('ok: process hold stays active beyond 12s and ends with its driver', flush=True)

        holder = cli('awake', '--seconds', '8')['holding']
        wait_for(lambda: has_activity(holder))
        time.sleep(6)
        assert has_activity(holder), 'timed activity expired after five seconds'
        assert_ready_without_recovery()
        wait_for(lambda: not has_activity(holder), timeout=4)
        print('ok: timed hold retains activity and expires', flush=True)

        holder = cli('awake', '--seconds', '30')['holding']
        wait_for(lambda: has_activity(holder))
        assert cli('awake', '--off')['released']
        wait_for(lambda: not has_activity(holder))
        print('ok: --off releases user activity', flush=True)
    finally:
        try:
            cli('awake', '--off')
        finally:
            if driver.poll() is None:
                driver.terminate()
                driver.wait(timeout=3)
PY
