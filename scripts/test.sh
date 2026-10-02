#!/usr/bin/env bash
# Unit tests, then a smoke test of the CLI's argument handling. Nothing here
# touches the screen or posts input.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TEST_OUT=$(mktemp -d "${TMPDIR:-/tmp}/macctl-tests.XXXXXX")
trap 'rm -rf "$TEST_OUT"' EXIT
FLAGS=(-swift-version 6 -Onone)

swiftc "${FLAGS[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name MacControlKit -o "$TEST_OUT/libMacControlKit.a" \
    Sources/MacControlKit/*.swift
swiftc "${FLAGS[@]}" -I "$TEST_OUT" -L "$TEST_OUT" -lMacControlKit \
    -o "$TEST_OUT/macctl-tests" Tests/MacControlKitTests/*.swift
"$TEST_OUT/macctl-tests"

swiftc "${FLAGS[@]}" -I "$TEST_OUT" -L "$TEST_OUT" -lMacControlKit \
    -o "$TEST_OUT/macctl" Sources/macctl/main.swift
MACCTL="$TEST_OUT/macctl"
# State lives under the test dir: nothing here may read or clear the real
# machine's origin record or awake pid.
export MACCTL_CACHE_DIR="$TEST_OUT/cache"

status() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
check() { # expected-exit-code description command...
    local want=$1 what=$2; shift 2
    local got; got=$(status "$@")
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $what: exit $got, wanted $want" >&2
        exit 1
    fi
}
check 0 "help --json is valid JSON with a spec" \
    bash -c "'$MACCTL' help --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"ok\"] and d[\"spec\"] and d[\"exitCodes\"]'"
check 2 "unknown command is a usage error" "$MACCTL" no-such-command
check 2 "unknown flag is a usage error" "$MACCTL" click "Example App" 0.5 0.5 --cont 2
check 2 "bad choice is a usage error" "$MACCTL" click "Example App" 0.5 0.5 --button middle
check 2 "missing positionals are a usage error" "$MACCTL" click-text "Example App"
check 2 "bad region is a usage error" "$MACCTL" verify "Example App" Open --region 0.1,0.2
check 2 "unknown control scope is a usage error" "$MACCTL" controls "Example App" --scope all
check 2 "empty identifier is a usage error" "$MACCTL" controls "Example App" --identifier ''
check 2 "exact requires a label" "$MACCTL" controls "Example App" --exact
check 2 "set-value requires a selector" "$MACCTL" set-value "Example App" text
check 2 "activate rejects competing label arguments" "$MACCTL" activate "Example App" Save --match Cancel
check 4 "restore with nothing recorded is refused before doing anything" "$MACCTL" restore
check 0 "restore --forget with nothing recorded is fine" "$MACCTL" restore --forget
check 0 "front reports origin null when nothing is recorded" \
    bash -c "'$MACCTL' front | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"ok\"] and d[\"origin\"] is None'"
echo "ok: macctl cli smoke tests"
