#!/bin/bash
# Test integracyjny FTPS: pyftpdlib z TLS (self-signed) – explicit na 2123, implicit na 2124.
set -euo pipefail
cd "$(dirname "$0")/.."
VENV=/tmp/ftpvenv
[ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import OpenSSL, pyftpdlib" 2>/dev/null || {
  python3 -m venv "$VENV"; "$VENV/bin/pip" install -q pyftpdlib pyopenssl; }
D=$(mktemp -d)
ROOT="$D/root"; mkdir "$ROOT"
"$VENV/bin/python" - "$D" <<'PY'
import sys, datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
d = sys.argv[1]
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=2)).sign(key, hashes.SHA256()))
pem = cert.public_bytes(serialization.Encoding.PEM) + key.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())
open(d + "/cert.pem", "wb").write(pem)
PY
cat > "$D/server.py" <<EOF
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.servers import FTPServer
from pyftpdlib.handlers import TLS_FTPHandler
from pyftpdlib.ioloop import IOLoop
import threading

def make(port, implicit):
    a = DummyAuthorizer(); a.add_user("user", "pass", "$ROOT", perm="elradfmwMT")
    if implicit:
        from pyftpdlib.handlers import TLS_FTPHandler as Base
        class H(Base):
            def handle(self):
                super().handle()
                self.secure_connection(self.ssl_context)
    else:
        H = type("H", (TLS_FTPHandler,), {})
    H.certfile = "$D/cert.pem"; H.authorizer = a
    H.tls_control_required = True; H.tls_data_required = True
    return FTPServer(("127.0.0.1", port), H)

s1 = make(2123, False)
for s in (s1,):
    pass
s1.serve_forever()
EOF
"$VENV/bin/python" "$D/server.py" >/tmp/ftpsd.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$D"' EXIT
sleep 2
MZ_FTPS_PORT=2123 ./scripts/test.sh --filter FTPS
