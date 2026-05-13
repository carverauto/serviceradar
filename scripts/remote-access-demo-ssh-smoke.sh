#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_NAMESPACE="${SERVICERADAR_DEMO_NAMESPACE:-demo}"
TARGET_NAMESPACE="${SERVICERADAR_REMOTE_ACCESS_SMOKE_NAMESPACE:-serviceradar-remote-access-smoke}"
TARGET_SERVICE="${SERVICERADAR_REMOTE_ACCESS_SMOKE_SERVICE:-serviceradar-remote-access-ssh}"
TARGET_USER="${SERVICERADAR_REMOTE_ACCESS_SMOKE_USER:-srtest}"
TARGET_PRINCIPAL="${SERVICERADAR_REMOTE_ACCESS_SMOKE_PRINCIPAL:-sr-test-operator}"
TARGET_IMAGE="${SERVICERADAR_REMOTE_ACCESS_SMOKE_IMAGE:-ubuntu:22.04}"
AGENT_LABEL_SELECTOR="${SERVICERADAR_REMOTE_ACCESS_AGENT_SELECTOR:-app=serviceradar-agent}"
KEEP_TARGET="${SERVICERADAR_REMOTE_ACCESS_SMOKE_KEEP:-0}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

cleanup() {
  if [ -n "${AGENT_POD:-}" ]; then
    kubectl -n "${DEMO_NAMESPACE}" exec "${AGENT_POD}" -c agent -- \
      sh -c 'rm -f /tmp/remote-access-agent.test /tmp/serviceradar-remote-access-ca' >/dev/null 2>&1 || true
  fi

  if [ "${KEEP_TARGET}" != "1" ]; then
    kubectl delete namespace "${TARGET_NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  if [ -n "${TMP_DIR:-}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}

require_cmd kubectl
require_cmd go
require_cmd ssh-keygen

TMP_DIR="$(mktemp -d)"
trap cleanup EXIT

CA_KEY="${TMP_DIR}/serviceradar_remote_access_ca_ed25519"
PRINCIPALS_FILE="${TMP_DIR}/authorized_principals"
ssh-keygen -q -t ed25519 -N "" -f "${CA_KEY}" -C "serviceradar-remote-access-smoke" >/dev/null
printf '%s\n' "${TARGET_PRINCIPAL}" >"${PRINCIPALS_FILE}"

kubectl create namespace "${TARGET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${TARGET_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null
kubectl -n "${TARGET_NAMESPACE}" create configmap remote-access-ssh-trust \
  --from-file=trusted_user_ca.pub="${CA_KEY}.pub" \
  --from-file=authorized_principals="${PRINCIPALS_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TARGET_SERVICE}
  namespace: ${TARGET_NAMESPACE}
  labels:
    app: ${TARGET_SERVICE}
spec:
  restartPolicy: Always
  containers:
    - name: sshd
      image: ${TARGET_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -euo pipefail
          export DEBIAN_FRONTEND=noninteractive
          if [ ! -x /usr/sbin/sshd ]; then
            apt-get update
            apt-get install -y openssh-server
          fi
          useradd -m -s /bin/bash "${TARGET_USER}" 2>/dev/null || true
          passwd -d "${TARGET_USER}" >/dev/null
          mkdir -p "/home/${TARGET_USER}/.ssh" /run/sshd
          cp /trust/trusted_user_ca.pub /etc/ssh/trusted_user_ca.pub
          cp /trust/authorized_principals "/home/${TARGET_USER}/.ssh/authorized_principals"
          chown -R "${TARGET_USER}:${TARGET_USER}" "/home/${TARGET_USER}/.ssh"
          chmod 700 "/home/${TARGET_USER}/.ssh"
          chmod 644 "/home/${TARGET_USER}/.ssh/authorized_principals" /etc/ssh/trusted_user_ca.pub
          ssh-keygen -A
          {
            printf '%s\n' 'Port 22'
            printf '%s\n' 'ListenAddress 0.0.0.0'
            printf '%s\n' 'HostKey /etc/ssh/ssh_host_ed25519_key'
            printf '%s\n' 'HostKey /etc/ssh/ssh_host_rsa_key'
            printf '%s\n' 'AuthorizedKeysFile none'
            printf '%s\n' 'AuthorizedPrincipalsFile .ssh/authorized_principals'
            printf '%s\n' 'TrustedUserCAKeys /etc/ssh/trusted_user_ca.pub'
            printf '%s\n' 'PasswordAuthentication no'
            printf '%s\n' 'KbdInteractiveAuthentication no'
            printf '%s\n' 'ChallengeResponseAuthentication no'
            printf '%s\n' 'PubkeyAuthentication yes'
            printf '%s\n' 'AuthenticationMethods publickey'
            printf '%s\n' 'UsePAM no'
            printf '%s\n' 'PermitTTY yes'
            printf '%s\n' 'StrictModes no'
            printf '%s\n' 'AllowUsers ${TARGET_USER}'
            printf '%s\n' 'LogLevel VERBOSE'
          } >/tmp/sshd_config
          exec /usr/sbin/sshd -D -e -f /tmp/sshd_config
      ports:
        - name: ssh
          containerPort: 22
      readinessProbe:
        tcpSocket:
          port: 22
        periodSeconds: 2
        failureThreshold: 30
      volumeMounts:
        - name: trust
          mountPath: /trust
          readOnly: true
  volumes:
    - name: trust
      configMap:
        name: remote-access-ssh-trust
---
apiVersion: v1
kind: Service
metadata:
  name: ${TARGET_SERVICE}
  namespace: ${TARGET_NAMESPACE}
spec:
  selector:
    app: ${TARGET_SERVICE}
  ports:
    - name: ssh
      port: 22
      targetPort: 22
YAML

kubectl -n "${TARGET_NAMESPACE}" wait --for=condition=Ready "pod/${TARGET_SERVICE}" --timeout=180s

AGENT_POD="$(
  kubectl -n "${DEMO_NAMESPACE}" get pod -l "${AGENT_LABEL_SELECTOR}" \
    -o jsonpath='{.items[0].metadata.name}'
)"
if [ -z "${AGENT_POD}" ]; then
  echo "could not find demo agent pod with selector ${AGENT_LABEL_SELECTOR}" >&2
  exit 1
fi

AGENT_NODE="$(
  kubectl -n "${DEMO_NAMESPACE}" get pod "${AGENT_POD}" \
    -o jsonpath='{.spec.nodeName}'
)"
GOARCH="$(
  kubectl get node "${AGENT_NODE}" -o jsonpath='{.status.nodeInfo.architecture}'
)"
if [ -z "${GOARCH}" ]; then
  GOARCH="amd64"
fi

TEST_BIN="${TMP_DIR}/remote-access-agent.test"
(
  cd "${REPO_ROOT}"
  CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH}" \
    go test -c -tags integration -o "${TEST_BIN}" ./go/pkg/agent
)

kubectl -n "${DEMO_NAMESPACE}" cp -c agent "${TEST_BIN}" "${AGENT_POD}:/tmp/remote-access-agent.test"
kubectl -n "${DEMO_NAMESPACE}" cp -c agent "${CA_KEY}" "${AGENT_POD}:/tmp/serviceradar-remote-access-ca"
kubectl -n "${DEMO_NAMESPACE}" exec "${AGENT_POD}" -c agent -- \
  chmod 700 /tmp/remote-access-agent.test
kubectl -n "${DEMO_NAMESPACE}" exec "${AGENT_POD}" -c agent -- \
  chmod 600 /tmp/serviceradar-remote-access-ca

TARGET_HOST="${TARGET_SERVICE}.${TARGET_NAMESPACE}.svc.cluster.local"

kubectl -n "${DEMO_NAMESPACE}" exec "${AGENT_POD}" -c agent -- env \
  SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_HOST="${TARGET_HOST}" \
  SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_PORT="22" \
  SERVICERADAR_REMOTE_ACCESS_SSH_USERNAME="${TARGET_USER}" \
  SERVICERADAR_REMOTE_ACCESS_SSH_PRINCIPAL="${TARGET_PRINCIPAL}" \
  SERVICERADAR_REMOTE_ACCESS_AGENT_ID="demo-agent-smoke" \
  SERVICERADAR_REMOTE_ACCESS_SESSION_ID="demo-agent-sshca-smoke" \
  SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_FILE="/tmp/serviceradar-remote-access-ca" \
  /tmp/remote-access-agent.test \
  -test.run '^TestProxmoxConsoleManagerAuthenticatesToTrustedUserCATarget$' \
  -test.v

echo "remote-access SSH smoke succeeded through ${DEMO_NAMESPACE}/${AGENT_POD} to ${TARGET_HOST}:22"
