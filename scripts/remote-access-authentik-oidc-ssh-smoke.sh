#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTHENTIK_NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
AUTHENTIK_DEPLOYMENT="${AUTHENTIK_DEPLOYMENT:-deploy/authentik-server}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.carverauto.dev}"
SMOKE_SLUG="${SERVICERADAR_AUTHENTIK_SMOKE_SLUG:-serviceradar-remote-access-smoke}"
SMOKE_NAME="${SERVICERADAR_AUTHENTIK_SMOKE_NAME:-ServiceRadar Remote Access Smoke}"
SMOKE_GROUP="${SERVICERADAR_AUTHENTIK_SMOKE_GROUP:-serviceradar-remote-access-smoke}"
SSH_LOGIN_USER="${SERVICERADAR_REMOTE_ACCESS_SSH_USERNAME:-$(id -un)}"
SSH_PRINCIPAL="${SERVICERADAR_REMOTE_ACCESS_SSH_PRINCIPAL:-$SSH_LOGIN_USER}"
SSH_TARGET_HOST="${SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_HOST:-127.0.0.1}"
SSH_TARGET_PORT="${SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_PORT:-}"
KEEP_FIXTURE="${SERVICERADAR_AUTHENTIK_SMOKE_KEEP:-0}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

json_field() {
  jq -r --arg key "$1" '.[$key]'
}

fixture_json_from_output() {
  sed -n 's/^SR_AUTHENTIK_FIXTURE_JSON=//p' | tail -1
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local deadline=$((SECONDS + 10))

  while (( SECONDS < deadline )); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

require curl
require go
require jq
require kubectl
require ssh
require ssh-keygen

TMP_DIR="$(mktemp -d)"
SSHD_PID=""

cleanup() {
  unset CLIENT_SECRET OIDC_CLIENT_SECRET

  if [[ -n "$SSHD_PID" ]]; then
    kill "$SSHD_PID" >/dev/null 2>&1 || true
    wait "$SSHD_PID" >/dev/null 2>&1 || true
  fi

  if [[ "$KEEP_FIXTURE" != "1" ]]; then
    SR_AUTHENTIK_SMOKE_ACTION=cleanup \
    SR_AUTHENTIK_SMOKE_SLUG="$SMOKE_SLUG" \
    SR_AUTHENTIK_SMOKE_NAME="$SMOKE_NAME" \
    SR_AUTHENTIK_SMOKE_GROUP="$SMOKE_GROUP" \
    kubectl -n "$AUTHENTIK_NAMESPACE" exec -i "$AUTHENTIK_DEPLOYMENT" -- env \
      SR_AUTHENTIK_SMOKE_ACTION=cleanup \
      SR_AUTHENTIK_SMOKE_SLUG="$SMOKE_SLUG" \
      SR_AUTHENTIK_SMOKE_NAME="$SMOKE_NAME" \
      SR_AUTHENTIK_SMOKE_GROUP="$SMOKE_GROUP" \
      ak shell < "$ROOT_DIR/scripts/authentik-remote-access-oidc-fixture.py" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "==> Generating temporary ServiceRadar SSH CA and user key"
ssh-keygen -q -t ed25519 -N "" -f "$TMP_DIR/ca_ed25519"
ssh-keygen -q -t ed25519 -N "" -f "$TMP_DIR/user_ed25519"
ssh-keygen -y -f "$TMP_DIR/ca_ed25519" > "$TMP_DIR/ca_ed25519.pub"

echo "==> Building ServiceRadar SSH CA signer"
go build -o "$TMP_DIR/serviceradar-sshca-signer" ./go/cmd/tools/sshca-signer

echo "==> Provisioning disposable Authentik OIDC app and authorization code"
NONCE="$(openssl rand -hex 24 2>/dev/null || date +%s%N)"
CLIENT_SECRET="$(openssl rand -base64 72 2>/dev/null | tr -d '\n' || date +%s%N)"
FIXTURE_OUTPUT="$(
  kubectl -n "$AUTHENTIK_NAMESPACE" exec -i "$AUTHENTIK_DEPLOYMENT" -- env \
    SR_AUTHENTIK_SMOKE_ACTION=provision \
    SR_AUTHENTIK_SMOKE_SLUG="$SMOKE_SLUG" \
    SR_AUTHENTIK_SMOKE_NAME="$SMOKE_NAME" \
    SR_AUTHENTIK_SMOKE_GROUP="$SMOKE_GROUP" \
    SR_AUTHENTIK_SMOKE_USERNAME="${SERVICERADAR_AUTHENTIK_SMOKE_USERNAME:-serviceradar-remote-access-smoke}" \
    SR_AUTHENTIK_SMOKE_EMAIL="${SERVICERADAR_AUTHENTIK_SMOKE_EMAIL:-serviceradar-remote-access-smoke@example.test}" \
    SR_AUTHENTIK_SMOKE_CLIENT_SECRET="$CLIENT_SECRET" \
    SR_AUTHENTIK_SMOKE_NONCE="$NONCE" \
    SR_AUTHENTIK_SMOKE_DISCOVERY_BASE="$AUTHENTIK_BASE_URL" \
    ak shell < "$ROOT_DIR/scripts/authentik-remote-access-oidc-fixture.py"
)"
FIXTURE_JSON="$(printf '%s\n' "$FIXTURE_OUTPUT" | fixture_json_from_output)"
if [[ -z "$FIXTURE_JSON" ]]; then
  echo "$FIXTURE_OUTPUT" >&2
  echo "failed to parse Authentik fixture output" >&2
  exit 1
fi

CLIENT_ID="$(printf '%s' "$FIXTURE_JSON" | json_field client_id)"
DISCOVERY_URL="$(printf '%s' "$FIXTURE_JSON" | json_field discovery_url)"
REDIRECT_URI="$(printf '%s' "$FIXTURE_JSON" | json_field redirect_uri)"
AUTH_CODE="$(printf '%s' "$FIXTURE_JSON" | json_field code)"
OIDC_GROUP="$(printf '%s' "$FIXTURE_JSON" | json_field group)"

METADATA_JSON="$(curl -fsS "$DISCOVERY_URL/.well-known/openid-configuration")"
TOKEN_ENDPOINT="$(printf '%s' "$METADATA_JSON" | jq -r '.token_endpoint')"
if [[ -z "$TOKEN_ENDPOINT" || "$TOKEN_ENDPOINT" == "null" ]]; then
  echo "$METADATA_JSON" >&2
  echo "Authentik discovery response did not include token_endpoint" >&2
  exit 1
fi

echo "==> Exchanging Authentik authorization code for signed OIDC token"
TOKEN_JSON="$(
  curl -fsS -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=$AUTH_CODE" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "client_secret=$CLIENT_SECRET" \
    --data-urlencode "redirect_uri=$REDIRECT_URI"
)"
OIDC_CLIENT_SECRET="$CLIENT_SECRET"
unset CLIENT_SECRET
ID_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -r '.id_token')"
if [[ -z "$ID_TOKEN" || "$ID_TOKEN" == "null" ]]; then
  echo "$TOKEN_JSON" >&2
  echo "Authentik token response did not include id_token" >&2
  exit 1
fi

echo "==> Verifying Authentik token and issuing ServiceRadar SSH certificate"
(
  cd "$ROOT_DIR/elixir/web-ng"
  MIX_ENV=test \
  SERVICERADAR_AUTHENTIK_OIDC_CLIENT_ID="$CLIENT_ID" \
  SERVICERADAR_AUTHENTIK_OIDC_CLIENT_SECRET="$OIDC_CLIENT_SECRET" \
  SERVICERADAR_AUTHENTIK_OIDC_DISCOVERY_URL="$DISCOVERY_URL" \
  SERVICERADAR_AUTHENTIK_OIDC_ID_TOKEN="$ID_TOKEN" \
  SERVICERADAR_AUTHENTIK_OIDC_NONCE="$NONCE" \
  SERVICERADAR_AUTHENTIK_OIDC_GROUP="$OIDC_GROUP" \
  SERVICERADAR_REMOTE_ACCESS_SSH_PRINCIPAL="$SSH_PRINCIPAL" \
  SERVICERADAR_REMOTE_ACCESS_PUBLIC_KEY_FILE="$TMP_DIR/user_ed25519.pub" \
  SERVICERADAR_REMOTE_ACCESS_CERT_FILE="$TMP_DIR/user_ed25519-cert.pub" \
  SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_FILE="$TMP_DIR/ca_ed25519" \
  SERVICERADAR_REMOTE_ACCESS_SSHCA_SIGNER="$TMP_DIR/serviceradar-sshca-signer" \
  SERVICERADAR_REMOTE_ACCESS_TARGET_HOST="$SSH_TARGET_HOST" \
  mix run ../../scripts/remote_access_authentik_oidc_ssh_smoke.exs
)
unset OIDC_CLIENT_SECRET

if [[ -z "$SSH_TARGET_PORT" ]]; then
  require sshd

  echo "==> Starting temporary OpenSSH target with TrustedUserCAKeys"
  SSHD_BIN="$(command -v sshd)"
  SSH_TARGET_PORT="$((20000 + RANDOM % 20000))"
  HOST_KEY="$TMP_DIR/host_ed25519"
  PRINCIPALS_FILE="$TMP_DIR/authorized_principals"
  KNOWN_HOSTS="$TMP_DIR/known_hosts"
  SSHD_CONFIG="$TMP_DIR/sshd_config"
  SSHD_LOG="$TMP_DIR/sshd.log"

  ssh-keygen -q -t ed25519 -N "" -f "$HOST_KEY"
  printf '%s\n' "$SSH_PRINCIPAL" > "$PRINCIPALS_FILE"
  : > "$KNOWN_HOSTS"

  cat > "$SSHD_CONFIG" <<EOF
Port $SSH_TARGET_PORT
ListenAddress 127.0.0.1
HostKey $HOST_KEY
PidFile $TMP_DIR/sshd.pid
AuthorizedKeysFile none
AuthorizedPrincipalsFile $PRINCIPALS_FILE
TrustedUserCAKeys $TMP_DIR/ca_ed25519.pub
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
UsePAM no
PermitTTY no
StrictModes no
AllowUsers $SSH_LOGIN_USER
LogLevel VERBOSE
EOF

  "$SSHD_BIN" -t -f "$SSHD_CONFIG"
  "$SSHD_BIN" -D -e -f "$SSHD_CONFIG" > "$SSHD_LOG" 2>&1 &
  SSHD_PID="$!"

  if ! wait_for_tcp 127.0.0.1 "$SSH_TARGET_PORT"; then
    cat "$SSHD_LOG" >&2
    echo "temporary sshd did not become ready" >&2
    exit 1
  fi
else
  KNOWN_HOSTS="$TMP_DIR/known_hosts"
  : > "$KNOWN_HOSTS"
fi

echo "==> Authenticating to OpenSSH target with ServiceRadar short-lived cert"
SSH_OUTPUT="$(
  ssh \
    -F /dev/null \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" \
    -o "CertificateFile=$TMP_DIR/user_ed25519-cert.pub" \
    -i "$TMP_DIR/user_ed25519" \
    -p "$SSH_TARGET_PORT" \
    "$SSH_LOGIN_USER@$SSH_TARGET_HOST" \
    printf serviceradar-authentik-sshca
)"

if [[ "$SSH_OUTPUT" != "serviceradar-authentik-sshca" ]]; then
  echo "unexpected SSH output: $SSH_OUTPUT" >&2
  exit 1
fi

echo "OK: Authentik OIDC claims issued a ServiceRadar SSH cert accepted by OpenSSH TrustedUserCAKeys"
