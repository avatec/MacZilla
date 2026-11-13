#!/bin/bash
# Test integracyjny FTP: stawia lokalny serwer (pyftpdlib w venv) i uruchamia testy.
set -euo pipefail
cd "$(dirname "$0")/.."
VENV=/tmp/ftpvenv
[ -x "$VENV/bin/python" ] || { python3 -m venv "$VENV"; "$VENV/bin/pip" install -q pyftpdlib; }
ROOT=$(mktemp -d)
PORT=2121
"$VENV/bin/python" -m pyftpdlib -p $PORT -w -u user -P pass -d "$ROOT" >/tmp/ftpd.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$ROOT"' EXIT
sleep 1.5
MZ_FTP_PORT=$PORT ./scripts/test.sh --filter FTP
