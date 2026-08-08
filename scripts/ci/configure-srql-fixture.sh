#!/usr/bin/env bash
# Materialise the shared SRQL fixture's TLS material and export its connection settings.
#
# Shared by .forgejo/workflows/main.yml and .forgejo/workflows/integration-core.yml. Both
# need it, for different reasons, which is why it lives here rather than in either workflow:
#
#   * main.yml consumes SERVICERADAR_RUN_CORE_INTEGRATION to decide whether to drop
#     //rust/srql:srql_api_test and //rust/srql:srql_comprehensive_test from the Bazel sweep,
#     and passes the exported PGSSL*/SRQL_* variables through as --test_env.
#   * integration-core.yml consumes the same flag to decide whether to run the
#     serviceradar_core suite at all.
#
# Duplicating ~100 lines of secret plumbing across two workflows is how the two copies end up
# disagreeing about which secret is required, so there is exactly one copy.
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
# Writes: PEM files under $RUNNER_TEMP, and the variables above plus
# SERVICERADAR_RUN_CORE_INTEGRATION (1 when the server accepts a TCP connection, else 0) to
# $GITHUB_ENV. A caller that reaches this script has already decided the secrets are present;
# a missing one is a configuration error and fails loudly rather than silently skipping.

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

{
  echo "SRQL_TEST_DATABASE_URL=${SRQL_TEST_DATABASE_URL}"
  echo "SRQL_TEST_ADMIN_URL=${SRQL_TEST_ADMIN_URL}"
  echo "PGSSLROOTCERT=${ca_file}"
  echo "CNPG_CA_FILE=${ca_file}"
  echo "SERVICERADAR_TEST_DATABASE_CA_CERT_FILE=${ca_file}"
  echo "SRQL_TEST_DATABASE_CA_CERT_FILE=${ca_file}"
  echo "SERVICERADAR_SKIP_UNREACHABLE_INTEGRATION_DB=1"
} >> "${GITHUB_ENV}"

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

"${parser}" - <<'PY' >> "${GITHUB_ENV}"
import os
import socket
from urllib.parse import urlparse, parse_qs


def parse(url):
    u = urlparse(url)
    qs = parse_qs(u.query)
    return {
        "user": u.username or "",
        "password": u.password or "",
        "host": u.hostname or "",
        "port": str(u.port or 5432),
        "sslmode": (qs.get("sslmode") or [""])[0],
    }


db = parse(os.environ["SRQL_TEST_DATABASE_URL"])
admin = parse(os.environ["SRQL_TEST_ADMIN_URL"])
host = admin["host"] or db["host"]
port = admin["port"] or db["port"]
user = admin["user"]
password = admin["password"]

if not host or not user:
    raise SystemExit("SRQL_TEST_ADMIN_URL must include host and username")

print(f"TEST_CNPG_HOST={host}")
print(f"TEST_CNPG_PORT={port}")
print(f"TEST_CNPG_USERNAME={user}")
print(f"TEST_CNPG_PASSWORD={password}")
print(f"CNPG_HOST={host}")
print(f"CNPG_PORT={port}")

sslmode = db["sslmode"] or "require"
print(f"CNPG_SSL_MODE={sslmode}")
print(f"CNPG_TLS_SERVER_NAME={host}")

# The fixture lives in a cluster that is not always reachable from a runner. Probing here,
# once, is what lets both workflows degrade to "skip" rather than "fail" -- a fixture outage
# should not look identical to a broken migration.
reachable = False
try:
    with socket.create_connection((host, int(port)), timeout=5):
        reachable = True
except OSError:
    reachable = False

print(f"SERVICERADAR_RUN_CORE_INTEGRATION={'1' if reachable else '0'}")
PY
