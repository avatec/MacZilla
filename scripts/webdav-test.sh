#!/bin/bash
# Test integracyjny WebDAV: lokalny WsgiDAV (venv w /tmp/ftpvenv) na porcie 8099.
set -euo pipefail
cd "$(dirname "$0")/.."
VENV=/tmp/ftpvenv
[ -x "$VENV/bin/wsgidav" ] || { python3 -m venv "$VENV"; "$VENV/bin/pip" install -q wsgidav cheroot; }
ROOT=$(mktemp -d)
"$VENV/bin/wsgidav" --host 127.0.0.1 --port 8099 --root "$ROOT" --auth anonymous >/tmp/wsgidav.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$ROOT"' EXIT
sleep 2
MZ_DAV_PORT=8099 ./scripts/test.sh --filter WebDAV
