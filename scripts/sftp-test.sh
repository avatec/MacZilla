#!/bin/bash
# Test integracyjny SFTP: uruchamia tymczasowy sshd (port 2222, własny klucz) i testy.
set -euo pipefail
cd "$(dirname "$0")/.."
D=$(mktemp -d)
chmod 700 "$D"
ssh-keygen -q -t ed25519 -N "" -f "$D/host"
ssh-keygen -q -t ed25519 -N "" -f "$D/user"
cp "$D/user.pub" "$D/authorized_keys"
cat > "$D/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $D/host
PidFile $D/sshd.pid
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes no
PerSourcePenalties no
Subsystem sftp /usr/libexec/sftp-server
EOF
/usr/sbin/sshd -D -f "$D/sshd_config" -E "$D/sshd.log" &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$D"' EXIT
sleep 1.5
MZ_SFTP_PORT=2222 MZ_SFTP_KEY="$D/user" ./scripts/test.sh --filter "${MZ_FILTER:-SFTP|HostKey}"
