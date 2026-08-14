#!/usr/bin/env bash
# Materialise the shared SRQL fixture's TLS material for the dedicated Forgejo database job.
# This is a permitted credential-handling exception to the no-shell rule: fixture secrets must
# exist in the Bazel client's environment before the guarded local TestRunner actions start, and
# making them ordinary action inputs would upload them into REAPI metadata.
#
# Reads (environment):
#   SRQL_TEST_DATABASE_URL      required  DSN of the shared fixture database
#   SRQL_TEST_ADMIN_URL         required  DSN of an admin role on the same server
#   SRQL_TEST_DATABASE_CA_CERT  required  PEM used to verify the fixture's TLS
#   SRQL_TEST_DATABASE_CERT     optional  client certificate, with _KEY or neither
#   SRQL_TEST_DATABASE_KEY      optional  client key, with _CERT or neither
#   RUNNER_TEMP                 required  where the PEM files are written
#   GITHUB_ENV                  required  appended to, not overwritten
#
# Writes: normalized verify-full DSNs, TLS server-name bridges, and PEM file paths under
# $RUNNER_TEMP to $GITHUB_ENV. A caller that reaches this script has already decided the secrets
# are present; missing or malformed input fails loudly rather than silently weakening TLS.

set -euo pipefail

umask 077

if [ -z "${SRQL_TEST_DATABASE_URL:-}" ] || [ -z "${SRQL_TEST_ADMIN_URL:-}" ]; then
  echo "SRQL fixture DSNs must be configured via SRQL_TEST_DATABASE_URL and SRQL_TEST_ADMIN_URL secrets." >&2
  exit 1
fi

if [ -z "${SRQL_TEST_DATABASE_CA_CERT:-}" ]; then
  echo "SRQL_TEST_DATABASE_CA_CERT secret must be configured to verify SRQL fixture TLS." >&2
  exit 1
fi

if [ -z "${RUNNER_TEMP:-}" ] || [ -z "${GITHUB_ENV:-}" ]; then
  echo "RUNNER_TEMP and GITHUB_ENV must be set; this script is only meaningful inside CI." >&2
  exit 1
fi

ca_file="${RUNNER_TEMP}/srql-fixture-ca.crt"
printf "%s" "${SRQL_TEST_DATABASE_CA_CERT}" > "${ca_file}"
chmod 600 "${ca_file}"

# Client certificate and key are optional, but only as a pair -- half a pair means a renamed
# or half-rotated secret, which would otherwise surface much later as an opaque TLS handshake
# failure against the fixture.
if [ -n "${SRQL_TEST_DATABASE_CERT:-}" ] || [ -n "${SRQL_TEST_DATABASE_KEY:-}" ]; then
  if [ -z "${SRQL_TEST_DATABASE_CERT:-}" ] || [ -z "${SRQL_TEST_DATABASE_KEY:-}" ]; then
    echo "SRQL_TEST_DATABASE_CERT and SRQL_TEST_DATABASE_KEY must be provided together." >&2
    exit 1
  fi

  cert_file="${RUNNER_TEMP}/srql-fixture-client.crt"
  key_file="${RUNNER_TEMP}/srql-fixture-client.key"
  printf "%s" "${SRQL_TEST_DATABASE_CERT}" > "${cert_file}"
  printf "%s" "${SRQL_TEST_DATABASE_KEY}" > "${key_file}"
  chmod 600 "${key_file}"
  {
    echo "PGSSLCERT=${cert_file}"
    echo "PGSSLKEY=${key_file}"
    echo "SERVICERADAR_TEST_DATABASE_CERT=${cert_file}"
    echo "SERVICERADAR_TEST_DATABASE_KEY=${key_file}"
    echo "SRQL_TEST_DATABASE_CERT=${cert_file}"
    echo "SRQL_TEST_DATABASE_KEY=${key_file}"
  } >> "${GITHUB_ENV}"
fi

parser="$(command -v python3 || command -v python || true)"
if [ -z "${parser}" ]; then
  echo "python is required to parse SRQL fixture DSNs." >&2
  exit 1
fi

SRQL_FIXTURE_CA_FILE="${ca_file}" "${parser}" - <<'PY' >> "${GITHUB_ENV}"
import os
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def normalize(url):
    if "\n" in url or "\r" in url:
        raise SystemExit("SRQL fixture DSNs must not contain line breaks")

    parsed = urlsplit(url)
    query = [
        (key, value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
        if key != "sslmode"
    ]
    query.append(("sslmode", "verify-full"))
    normalized = urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, urlencode(query), parsed.fragment)
    )
    return {
        "url": normalized,
        "user": parsed.username or "",
        "password": parsed.password or "",
        "host": parsed.hostname or "",
        "port": str(parsed.port or 5432),
        "database": parsed.path.lstrip("/"),
    }


db = normalize(os.environ["SRQL_TEST_DATABASE_URL"])
admin = normalize(os.environ["SRQL_TEST_ADMIN_URL"])
host = admin["host"] or db["host"]
port = admin["port"] or db["port"]
user = admin["user"]
password = admin["password"]
server_name = (
    os.environ.get("SRQL_TEST_DATABASE_SERVER_NAME")
    or os.environ.get("PGSSLSERVERNAME")
    or "srql-fixture-rw.srql-fixtures.svc.cluster.local"
)

if not host or not user or not server_name:
    raise SystemExit("SRQL_TEST_ADMIN_URL must include host and username")
if any(char in server_name for char in "\r\n"):
    raise SystemExit("SRQL fixture TLS server name must not contain line breaks")

print(f"SRQL_TEST_DATABASE_URL={db['url']}")
print(f"SRQL_TEST_ADMIN_URL={admin['url']}")
print(f"SRQL_TEST_DATABASE_SERVER_NAME={server_name}")
print(f"SERVICERADAR_TEST_DATABASE_SERVER_NAME={server_name}")
print(f"PGSSLSERVERNAME={server_name}")
print(f"CNPG_TLS_SERVER_NAME={server_name}")
print("CNPG_SSL_MODE=verify-full")
print(f"PGSSLROOTCERT={os.environ['SRQL_FIXTURE_CA_FILE']}")
print(f"CNPG_CA_FILE={os.environ['SRQL_FIXTURE_CA_FILE']}")
print(f"SERVICERADAR_TEST_DATABASE_CA_CERT_FILE={os.environ['SRQL_FIXTURE_CA_FILE']}")
print(f"SRQL_TEST_DATABASE_CA_CERT_FILE={os.environ['SRQL_FIXTURE_CA_FILE']}")
print(f"TEST_CNPG_HOST={host}")
print(f"TEST_CNPG_PORT={port}")
print(f"TEST_CNPG_DATABASE={admin['database'] or 'postgres'}")
print(f"TEST_CNPG_USERNAME={user}")
print(f"TEST_CNPG_PASSWORD={password}")
print(f"CNPG_HOST={host}")
print(f"CNPG_PORT={port}")
PY
