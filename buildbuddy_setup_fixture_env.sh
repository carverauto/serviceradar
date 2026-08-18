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
#   live CA (kubectl or HTTPS) + K8s/BB DSNs -> env on runner -> --config=database_env
#   -> local test action
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
# This target sources DSNs from the srql-fixtures K8s secrets when RBAC exists, otherwise from
# pre-set workflow DSN secrets. The CA is never taken from a stored CI secret: it comes from
# the live cert-manager Secret or from SRQL_FIXTURE_CA_URL. It emits PEM content rather than a
# path, so the credential contract is independent of a runner-local filesystem path.
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
# verify-full is safe against this hostname: the cert-manager server cert
# (secret srql-fixture-server-tls) carries DNS SANs for srql-fixture-{r,ro,rw} at every
# suffix plus srql-fixture.serviceradar.cloud. It has no IP SANs, so a NodePort caller
# must also set PGSSLSERVERNAME and SRQL_TEST_DATABASE_SERVER_NAME to the certificate's
# DNS name.
ca_secret="${SRQL_FIXTURE_CA_SECRET:-srql-fixture-server-ca}"
ca_url="${SRQL_FIXTURE_CA_URL:-https://srql-fixture-ca.serviceradar.cloud/ca.crt}"
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

pem_looks_like_cert() {
  [[ "$1" == *"BEGIN CERTIFICATE"* && "$1" == *"END CERTIFICATE"* ]]
}

# A stored SRQL_TEST_DATABASE_CA_CERT is not a source. Fail if openssl can see the
# PEM and it is already expired; skip the check when openssl is missing.
ca_is_current() {
  local pem="$1"
  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi
  printf '%s' "${pem}" | openssl x509 -noout -checkend 0 >/dev/null 2>&1
}

fetch_ca_url() {
  local url="$1"
  if [[ "${url}" == file://* ]]; then
    cat "${url#file://}"
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to fetch SRQL_FIXTURE_CA_URL=${url}" >&2
    return 1
  fi
  curl -fsS --max-time 20 "${url}"
}

resolve_live_ca() {
  local pem=""
  if command -v kubectl >/dev/null 2>&1 &&
    kubectl auth can-i get secrets -n "${namespace}" >/dev/null 2>&1; then
    pem="$(secret_value "${ca_secret}" 'ca\.crt')"
    if pem_looks_like_cert "${pem}" && ca_is_current "${pem}"; then
      SRQL_TEST_DATABASE_CA_CERT="${pem}"
      ca_source="kubernetes (${namespace}/${ca_secret})"
      return 0
    fi
  fi

  pem="$(fetch_ca_url "${ca_url}" 2>/dev/null || true)"
  if pem_looks_like_cert "${pem}" && ca_is_current "${pem}"; then
    SRQL_TEST_DATABASE_CA_CERT="${pem}"
    ca_source="https (${ca_url})"
    return 0
  fi

  return 1
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
ca_source=""

# CA first, from a live source only. A pre-set SRQL_TEST_DATABASE_CA_CERT is the snapshot
# this helper exists to retire; it is never a source.
if ! resolve_live_ca; then
  cat >&2 <<EOF_ERR
No live SRQL fixture CA available.

The CA must come from the current cert-manager Secret or the published bundle, not from a
stored CI secret. Provide ONE of:

  * Cluster access -- kubectl on PATH with \`get secrets\` in ${namespace}.
    Reads ${ca_secret} key ca.crt.

  * ${ca_url} reachable (override with SRQL_FIXTURE_CA_URL).
    In-cluster runners use the ClusterIP HTTP bundle; workstations can
    use kubectl or the public HTTPS URL.

A pre-set SRQL_TEST_DATABASE_CA_CERT is ignored on purpose.
EOF_ERR
  exit 1
fi

# DSNs: kubectl when RBAC exists, otherwise pre-set workflow/developer URLs.
if command -v kubectl >/dev/null 2>&1 &&
  kubectl auth can-i get secrets -n "${namespace}" >/dev/null 2>&1; then
  db_user="$(secret_value srql-test-db-credentials username)"
  db_pass="$(secret_value srql-test-db-credentials password)"
  admin_user="$(secret_value srql-test-admin-credentials username)"
  admin_pass="$(secret_value srql-test-admin-credentials password)"

  if [[ -n "${db_user}" && -n "${db_pass}" && -n "${admin_user}" && -n "${admin_pass}" ]]; then
    base="${host}:${port}"
    SRQL_TEST_DATABASE_URL="postgres://$(urlencode "${db_user}"):$(urlencode "${db_pass}")@${base}/${database}?sslmode=${sslmode}"
    SRQL_TEST_ADMIN_URL="postgres://$(urlencode "${admin_user}"):$(urlencode "${admin_pass}")@${base}/postgres?sslmode=${sslmode}"
    source_used="kubernetes (${namespace})"
  fi
fi

if [[ -z "${source_used}" ]]; then
  if [[ -n "${SRQL_TEST_DATABASE_URL:-}" && -n "${SRQL_TEST_ADMIN_URL:-}" ]]; then
    source_used="pre-set DSNs"
  fi
fi

if [[ -z "${source_used}" ]]; then
  cat >&2 <<'EOF_ERR'
No srql-fixtures DSNs available.

Provide ONE of:

  * Cluster access -- kubectl on PATH with `get secrets` in the srql-fixtures namespace.
    Reads srql-test-db-credentials and srql-test-admin-credentials and assembles the DSNs.

  * These two already exported (BuildBuddy/Forgejo DSN secrets):
        SRQL_TEST_DATABASE_URL
        SRQL_TEST_ADMIN_URL

The CA is obtained separately from the live cert-manager Secret or SRQL_FIXTURE_CA_URL.

Overrides: SRQL_FIXTURE_{NAMESPACE,HOST,PORT,DATABASE,SSLMODE,CA_SECRET,CA_URL}.
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

  # BRIDGE -- DELETE WITH THE LAST UNCONVERTED READER.
  #
  # `--test_env=NAME` only FORWARDS a variable from the caller's environment; nothing sets one.
  # These five are the only names this script sets, so they are the only ones worth forwarding,
  # and they live here rather than in //.bazelrc because that is where the values come from:
  # a forwarding list kept somewhere else drifts from the thing that produces it. The profile
  # this replaced forwarded 43 names, 38 of which nothing ever set.
  #
  # Every remaining reader is listed in openspec/changes/add-unified-config-and-secret-managers
  # phase 7. When the Elixir test config and integration_tests/srql/tests/support/harness.rs
  # resolve through ConfigManager/SecretManager, delete this block: SERVICERADAR_ENV is then the
  # only variable a component needs, and it is stated at the invocation.
  emit SERVICERADAR_TEST_ENV_FLAGS "$(printf -- '--test_env=%s ' \
    SRQL_TEST_DATABASE_URL \
    SRQL_TEST_ADMIN_URL \
    SRQL_TEST_DATABASE_CA_CERT \
    SRQL_TEST_DATABASE_SERVER_NAME \
    PGSSLSERVERNAME)"
} >"${env_file}"
chmod 600 "${env_file}"

# Source and shape only -- never parse or print any portion of a credential-bearing DSN.
# Malformed userinfo and query delimiters can make otherwise reasonable endpoint redaction
# leak a password into build logs, so the private env file is the only DSN output.
printf 'Fixture credentials from %s -> %s\n' "${source_used}" "${env_file}" >&2
printf '  CA       : %s bytes of PEM from %s\n' "${#SRQL_TEST_DATABASE_CA_CERT}" "${ca_source}" >&2

if command -v openssl >/dev/null 2>&1; then
  not_after="$(printf '%s' "${SRQL_TEST_DATABASE_CA_CERT}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [[ -n "${not_after}" ]]; then
    printf '  expires  : %s\n' "${not_after}" >&2
  fi
fi
