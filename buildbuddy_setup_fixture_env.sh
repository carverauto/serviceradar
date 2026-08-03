#!/usr/bin/env bash
# Assembles the srql-fixtures CNPG credentials for step 3 of the BuildBuddy workflow.
#
# WHY THIS IS A SCRIPT AND NOT A BAZEL TARGET
#
# Same carve-out as buildbuddy_setup_docker_auth.sh, for the same reason: this is credential
# handling that MUST NOT become an action input. A Bazel test action cannot obtain these
# values itself -- it runs on a remote executor with no kubeconfig, inside a sandbox, and a
# `kubectl get secret` from inside a test would be an undeclared network dependency. The
# values have to be in the BAZEL CLIENT's environment before `bazel test` starts, because
# .bazelrc carries them the rest of the way with `--test_env=NAME` pass-through:
#
#   K8s secret / BB secret -> env on the workflow runner -> --test_env -> test action
#
# WHY IT WRITES A FILE INSTEAD OF PRINTING exports
#
# A process cannot set its parent shell's environment, so `bazel run` alone cannot do this.
# Printing `export` lines for the caller to eval would put a live DSN on stdout, which
# `bazel run` streams into the build log. Writing 0600 to a path outside the workspace keeps
# the password out of both the log and the source tree.
#
# USAGE (BuildBuddy workflow, in ONE step so the env survives):
#
#   bazel run -c opt //:buildbuddy_setup_fixture_env
#   set -a; . "${SERVICERADAR_FIXTURE_ENV_FILE:-${TMPDIR:-/tmp}/serviceradar-fixture-env}"; set +a
#   bazel test -c opt //elixir/serviceradar_core:migrate_template --config=remote --test_tag_filters=
#   ...
set -o errexit
set -o nounset
set -o pipefail

env_file="${SERVICERADAR_FIXTURE_ENV_FILE:-${TMPDIR:-/tmp}/serviceradar-fixture-env}"

namespace="${SRQL_FIXTURE_NAMESPACE:-srql-fixtures}"
# Non-secret, so they are defaults here rather than secrets. The in-cluster service name is
# the one endpoint both the workflow runner and the executors can reach -- they are the same
# machines. A workstation is the odd one out: it reaches the LAN NodePort but not this, which
# is why a developer needs SRQL_TEST_DATABASE_URL set by hand. See openspec/notes/bazel-bb-ci.md.
host="${SRQL_FIXTURE_HOST:-srql-fixture-rw.srql-fixtures.svc.cluster.local}"
port="${SRQL_FIXTURE_PORT:-5432}"
database="${SRQL_FIXTURE_DATABASE:-srql_fixture}"
# verify-full is safe against this hostname: the server cert (secret srql-fixture-server)
# carries DNS SANs for srql-fixture-{r,ro,rw} at every suffix plus srql-fixture.serviceradar.cloud.
# It has NO IP SANs, so anything addressing the fixture by IP must drop to sslmode=require.
sslmode="${SRQL_FIXTURE_SSLMODE:-verify-full}"

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
    SRQL_TEST_DATABASE_CA_CERT must be PEM CONTENT, not a path -- a path names a file on
    the machine that launched the build and a remote executor has no such file.

Overrides: SRQL_FIXTURE_{NAMESPACE,HOST,PORT,DATABASE,SSLMODE}.
On a workstation the in-cluster hostname is unreachable; use the LAN NodePort with
SRQL_FIXTURE_SSLMODE=require (the server cert has no IP SANs).
EOF_ERR
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
} >"${env_file}"
chmod 600 "${env_file}"

# Source and shape only -- never a value. The DSN carries a password, and this runs where
# stdout becomes a build log.
#
# The endpoint is read back OUT of the assembled DSN rather than reprinted from the defaults
# above. On the fallback path those defaults are not what is in use -- the DSN came from the
# environment and can point anywhere -- and a summary that describes an endpoint the run is
# not using is worse than no summary at all.
endpoint_of() {
  local dsn="$1"
  dsn="${dsn#*://}"  # strip scheme
  dsn="${dsn#*@}"    # strip userinfo, password included
  printf '%s' "${dsn}"
}

printf 'Fixture credentials from %s -> %s\n' "${source_used}" "${env_file}" >&2
printf '  database : %s\n' "$(endpoint_of "${SRQL_TEST_DATABASE_URL}")" >&2
printf '  admin    : %s\n' "$(endpoint_of "${SRQL_TEST_ADMIN_URL}")" >&2
printf '  CA       : %s bytes of PEM\n' "${#SRQL_TEST_DATABASE_CA_CERT}" >&2
