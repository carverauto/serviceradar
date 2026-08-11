#!/usr/bin/env bash
# Assembles the srql-fixtures CNPG credentials for step 3 of the BuildBuddy workflow.
#
# WHY THIS IS A SCRIPT AND NOT A BAZEL TARGET
#
# Same carve-out as buildbuddy_setup_docker_auth.sh, for the same reason: this is credential
# handling that MUST NOT become an action input. A Bazel test action cannot obtain these
# values itself -- it is sandboxed and has no kubeconfig, and a `kubectl get secret` from inside
# a test would be an undeclared network dependency. The
# values have to be in the BAZEL CLIENT's environment before `bazel test` starts, because the
# explicit `.bazelrc` `database_env` profile carries them the rest of the way:
#
#   K8s secret / BB secret -> env on runner -> --config=database_env -> local test action
#
# WHY IT WRITES A FILE INSTEAD OF PRINTING exports
#
# A process cannot set its parent shell's environment, so `bazel run` alone cannot do this.
# Printing `export` lines for the caller to eval would put a live DSN on stdout, which
# `bazel run` streams into the build log. Writing 0600 to a path outside the workspace keeps
# the password out of both the log and the source tree.
#
# RELATION TO scripts/ci/configure-srql-fixture.sh
#
# That script is the Forgejo-era equivalent and is NOT superseded by accident. It CONSUMES
# the same three secrets rather than sourcing them, and writes to $GITHUB_ENV / $RUNNER_TEMP,
# neither of which exists in a BuildBuddy workflow. It also materialises the CA to a file and
# exports four *_CA_CERT_FILE paths. The database TestRunner now executes locally by caller
# strategy, while eligible compilation remains remote. It dies with the .forgejo tier.
#
# This target differs in two ways: it can SOURCE the credentials from the srql-fixtures K8s
# secrets rather than requiring them pre-set, and it emits PEM content rather than a path, so
# the credential contract is independent of a runner-local filesystem path.
#
# USAGE
#
# This helper only materializes credentials. Run it from the canonical, single-shell Bazel
# lifecycle documented in .agents/skills/srql-fixtures-db-tests/SKILL.md. That recipe owns
# the per-run file path, local TestRunner strategy, fixture guard, cache policy, and cleanup.
set -o errexit
set -o nounset
set -o pipefail

: "${SERVICERADAR_FIXTURE_ENV_FILE:?SERVICERADAR_FIXTURE_ENV_FILE must name a caller-owned temporary file}"
env_file="${SERVICERADAR_FIXTURE_ENV_FILE}"

namespace="${SRQL_FIXTURE_NAMESPACE:-srql-fixtures}"
# Non-secret, so they are defaults here rather than secrets. The in-cluster service name is
# the one endpoint the in-cluster workflow runner can reach. A workstation is the odd one out:
# it reaches the LAN NodePort but not this, which is why a developer needs
# SRQL_TEST_DATABASE_URL set by hand. See openspec/notes/bazel-bb-ci.md.
host="${SRQL_FIXTURE_HOST:-srql-fixture-rw.srql-fixtures.svc.cluster.local}"
port="${SRQL_FIXTURE_PORT:-5432}"
database="${SRQL_FIXTURE_DATABASE:-srql_fixture}"
# verify-full is safe against this hostname: the server cert (secret srql-fixture-server)
# carries DNS SANs for srql-fixture-{r,ro,rw} at every suffix plus srql-fixture.serviceradar.cloud.
# It has no IP SANs, so a NodePort caller must also set PGSSLSERVERNAME and
# SRQL_TEST_DATABASE_SERVER_NAME to the certificate's DNS name.
sslmode="${SRQL_FIXTURE_SSLMODE:-verify-full}"
if [[ "${sslmode}" != "verify-full" ]]; then
  echo "SRQL_FIXTURE_SSLMODE must be verify-full; refusing to weaken fixture TLS verification" >&2
  exit 1
fi

# RFC 3986 userinfo encoding. CNPG generates passwords that can contain characters which
# silently truncate or corrupt a DSN if interpolated raw (`@` splits userinfo from host,
# `/` ends the authority, `?` starts the query).
urlencode() {
  local raw="$1" out='' i char
  for ((i = 0; i < ${#raw}; i++)); do
    char="${raw:i:1}"
    case "$char" in
      [A-Za-z0-9.~_-]) out+="$char" ;;
      *) out+="$(printf '%%%02X' "'$char")" ;;
    esac
  done
  printf '%s' "$out"
}

secret_value() {
  kubectl get secret "$1" -n "${namespace}" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d
}

with_sslmode() {
  local url="$1" mode="$2" base query parameter out="" found=0

  # PostgreSQL connection URLs have no useful fragment semantics. Keeping one
  # would also make an appended sslmode part of the fragment rather than the
  # query, silently defeating the verified-TLS contract.
  if [[ "${url}" == *#* ]]; then
    printf 'PostgreSQL fixture URLs must not contain fragments.\n' >&2
    return 1
  fi

  if [[ "${url}" == *\?* ]]; then
    base="${url%%\?*}"
    query="${url#*\?}"
  else
    base="${url}"
    query=""
  fi

  local old_ifs="${IFS}"
  IFS='&'
  for parameter in ${query}; do
    if [[ "${parameter}" == sslmode=* ]]; then
      parameter="sslmode=${mode}"
      found=1
    fi
    if [[ -n "${out}" ]]; then
      out+="&"
    fi
    out+="${parameter}"
  done
  IFS="${old_ifs}"

  if [[ "${found}" -eq 0 ]]; then
    if [[ -n "${out}" ]]; then
      out+="&"
    fi
    out+="sslmode=${mode}"
  fi

  printf '%s?%s' "${base}" "${out}"
}

database_host() {
  local url="$1" rest authority
  rest="${url#*://}"
  authority="${rest%%/*}"
  authority="${authority##*@}"

  if [[ "${authority}" == \[*\]* ]]; then
    authority="${authority#\[}"
    printf '%s' "${authority%%\]*}"
  else
    printf '%s' "${authority%%:*}"
  fi
}

source_used=""

# Path 1: read the K8s secrets directly. srql-fixtures stays the single source of truth, and
# a CNPG CA rotation (90 days) is picked up automatically rather than needing a re-copy.
if command -v kubectl >/dev/null 2>&1 &&
  kubectl auth can-i get secrets -n "${namespace}" >/dev/null 2>&1; then
  db_user="$(secret_value srql-test-db-credentials username)"
  db_pass="$(secret_value srql-test-db-credentials password)"
  admin_user="$(secret_value srql-test-admin-credentials username)"
  admin_pass="$(secret_value srql-test-admin-credentials password)"
  ca_cert="$(secret_value srql-fixture-ca 'ca\.crt')"

  if [[ -n "${db_user}" && -n "${db_pass}" && -n "${admin_user}" && -n "${admin_pass}" && -n "${ca_cert}" ]]; then
    base="${host}:${port}"
    SRQL_TEST_DATABASE_URL="postgres://$(urlencode "${db_user}"):$(urlencode "${db_pass}")@${base}/${database}?sslmode=${sslmode}"
    SRQL_TEST_ADMIN_URL="postgres://$(urlencode "${admin_user}"):$(urlencode "${admin_pass}")@${base}/postgres?sslmode=${sslmode}"
    SRQL_TEST_DATABASE_CA_CERT="${ca_cert}"
    source_used="kubernetes (${namespace})"
  fi
fi

# Path 2: fall back to whatever is already exported -- BuildBuddy workflow secrets, or a
# developer's own shell. Deliberately NOT an error: a runner without cluster RBAC, or a
# workstation pointed at a NodePort, is a legitimate caller.
if [[ -z "${source_used}" ]]; then
  if [[ -n "${SRQL_TEST_DATABASE_URL:-}" && -n "${SRQL_TEST_ADMIN_URL:-}" && -n "${SRQL_TEST_DATABASE_CA_CERT:-}" ]]; then
    source_used="pre-set environment (BuildBuddy secrets)"
  fi
fi

if [[ -z "${source_used}" ]]; then
  cat >&2 <<'EOF_ERR'
No srql-fixtures credentials available.

Provide ONE of:

  * Cluster access -- kubectl on PATH with `get secrets` in the srql-fixtures namespace.
    Reads srql-test-db-credentials, srql-test-admin-credentials and srql-fixture-ca and
    assembles the DSNs itself. Preferred: rotation is picked up automatically.

  * These three already exported (BuildBuddy workflow secrets, same names the outgoing
    Forgejo workflows use):
        SRQL_TEST_DATABASE_URL
        SRQL_TEST_ADMIN_URL
        SRQL_TEST_DATABASE_CA_CERT
    SRQL_TEST_DATABASE_CA_CERT must be PEM CONTENT, not a path. Bazel TestRunner sandboxes
    must not depend on a caller-owned host path, and the fixture CA rotates independently.

Overrides: SRQL_FIXTURE_{NAMESPACE,HOST,PORT,DATABASE,SSLMODE}.
On a workstation the in-cluster hostname is unreachable; use the LAN NodePort with
SRQL_FIXTURE_SSLMODE=verify-full plus PGSSLSERVERNAME and SRQL_TEST_DATABASE_SERVER_NAME set
to srql-fixture-rw.srql-fixtures.svc.cluster.local (the server cert has no IP SANs).
EOF_ERR
  exit 1
fi

# One shared TLS contract for both credential paths. Pre-set workflow secrets used to carry no
# sslmode: tokio-postgres then defaulted to Prefer (permitting plaintext fallback) while Ecto used
# verify_none even though a CA was present. Keep verify-full in the shared DSNs. The Rust lifecycle
# maps that value to Require only at its tokio-postgres parser boundary and still verifies through
# rustls; Ecto consumes verify-full directly.
SRQL_TEST_DATABASE_URL="$(with_sslmode "${SRQL_TEST_DATABASE_URL}" "${sslmode}")"
SRQL_TEST_ADMIN_URL="$(with_sslmode "${SRQL_TEST_ADMIN_URL}" "${sslmode}")"

tls_server_name="${SRQL_TEST_DATABASE_SERVER_NAME:-${PGSSLSERVERNAME:-}}"
if [[ -z "${tls_server_name}" ]]; then
  tls_server_name="$(database_host "${SRQL_TEST_DATABASE_URL}")"
fi
if [[ -z "${tls_server_name}" ]]; then
  echo "could not derive the SRQL fixture TLS server name" >&2
  exit 1
fi

# Single-quote every value, escaping any embedded single quote as '\''. NOT ${var@Q}: that
# needs bash 4.4 and macOS ships bash 3.2, so a developer running this locally got a "bad
# substitution" that wrote a truncated file. The CA is multi-line PEM, which single quotes
# carry through `.` unharmed.
emit() {
  local name="$1" value="$2"
  printf "%s='%s'\n" "${name}" "${value//\'/\'\\\'\'}"
}

umask 077
{
  emit SRQL_TEST_DATABASE_URL "${SRQL_TEST_DATABASE_URL}"
  emit SRQL_TEST_ADMIN_URL "${SRQL_TEST_ADMIN_URL}"
  emit SRQL_TEST_DATABASE_CA_CERT "${SRQL_TEST_DATABASE_CA_CERT}"
  emit SRQL_TEST_DATABASE_SERVER_NAME "${tls_server_name}"
  emit PGSSLSERVERNAME "${tls_server_name}"
} >"${env_file}"
chmod 600 "${env_file}"

# Source and shape only -- never parse or print any portion of a credential-bearing DSN.
# Malformed userinfo and query delimiters can make otherwise reasonable endpoint redaction
# leak a password into build logs, so the private env file is the only DSN output.
printf 'Fixture credentials from %s -> %s\n' "${source_used}" "${env_file}" >&2
printf '  CA       : %s bytes of PEM\n' "${#SRQL_TEST_DATABASE_CA_CERT}" >&2

# The fixture CA is on a 90-day rotation. Where it arrives as a stored BuildBuddy secret
# rather than straight from srql-fixture-ca, nothing refreshes it -- so the day it lapses,
# eight shards start failing TLS verification and it reads as a database outage rather than
# a stale copy. Say the date out loud while there is still time to act on it.
#
# WARNS ONLY, never fails: an expired CA is a real failure the tests themselves will report,
# and turning credential setup into a second place that can hard-fail on a clock is worse
# than the confusion it prevents.
if command -v openssl >/dev/null 2>&1; then
  not_after="$(printf '%s' "${SRQL_TEST_DATABASE_CA_CERT}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [[ -n "${not_after}" ]]; then
    if printf '%s' "${SRQL_TEST_DATABASE_CA_CERT}" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
      # 21 days: longer than a sprint, short enough to still be urgent.
      if ! printf '%s' "${SRQL_TEST_DATABASE_CA_CERT}" | openssl x509 -noout -checkend 1814400 >/dev/null 2>&1; then
        printf '  EXPIRES  : %s -- under 21 days. Refresh the SRQL_TEST_DATABASE_CA_CERT secret from\n' "${not_after}" >&2
        printf '             kubectl get secret srql-fixture-ca -n %s -o jsonpath=%s | base64 -d\n' \
          "${namespace}" "'{.data.ca\.crt}'" >&2
      else
        printf '  expires  : %s\n' "${not_after}" >&2
      fi
    else
      printf '  EXPIRED  : %s -- TLS verification WILL fail. Refresh the secret before running step 3.\n' "${not_after}" >&2
    fi
  fi
fi
