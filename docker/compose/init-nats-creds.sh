#!/usr/bin/env bash
set -euo pipefail

creds_dir="/etc/serviceradar/creds"
seed_dir="/seed/creds"

bootstrap_complete() {
  [ -f "${creds_dir}/operator.jwt" ] &&
  [ -f "${creds_dir}/system.jwt" ] &&
  [ -f "${creds_dir}/system_account.pub" ] &&
  [ -f "${creds_dir}/system.creds" ] &&
  [ -f "${creds_dir}/platform.creds" ] &&
  [ -f "${creds_dir}/nats.conf" ]
}

fix_runtime_perms() {
  mkdir -p "${creds_dir}"
  find "${creds_dir}" -type d -exec chmod 0755 {} \;

  for path in "${creds_dir}"/*.creds "${creds_dir}"/*.jwt "${creds_dir}"/*.pub "${creds_dir}"/*.conf; do
    if [[ -f "${path}" ]]; then
      chmod 0644 "${path}"
    fi
  done

  if [[ -f "${creds_dir}/operator.seed" ]]; then
    chmod 0600 "${creds_dir}/operator.seed"
  fi
}

if bootstrap_complete; then
  if [[ ! -f "${creds_dir}/operator.seed" ]]; then
    if [[ -n "${NATS_OPERATOR_SEED:-}" ]]; then
      echo "Persisting operator seed to creds volume."
      echo "${NATS_OPERATOR_SEED}" > "${creds_dir}/operator.seed"
    else
      echo "Warning: operator.seed missing and NATS_OPERATOR_SEED not set; NATS account provisioning will fail."
    fi
  fi
  if [[ ! -f "${creds_dir}/system_account.pub" ]] && [[ -n "${NATS_SYSTEM_ACCOUNT_PUBLIC_KEY:-}" ]]; then
    echo "${NATS_SYSTEM_ACCOUNT_PUBLIC_KEY}" > "${creds_dir}/system_account.pub"
  fi
  fix_runtime_perms
  echo "NATS creds already present; skipping bootstrap."
  exit 0
fi

if [[ -f "${creds_dir}/operator.jwt" ]] || [[ -f "${creds_dir}/system.creds" ]] || [[ -f "${creds_dir}/platform.creds" ]]; then
  echo "Detected partial NATS creds bootstrap state; regenerating missing artifacts."
fi

mkdir -p "${creds_dir}"
if [[ -f "${seed_dir}/operator.jwt" ]]; then
  echo "Copying seed NATS creds into volume."
  cp -a "${seed_dir}/." "${creds_dir}/"
  if [[ ! -f "${creds_dir}/operator.seed" ]] && [[ -n "${NATS_OPERATOR_SEED:-}" ]]; then
    echo "Persisting operator seed to creds volume."
    echo "${NATS_OPERATOR_SEED}" > "${creds_dir}/operator.seed"
  fi
  if [[ ! -f "${creds_dir}/system_account.pub" ]] && [[ -n "${NATS_SYSTEM_ACCOUNT_PUBLIC_KEY:-}" ]]; then
    echo "${NATS_SYSTEM_ACCOUNT_PUBLIC_KEY}" > "${creds_dir}/system_account.pub"
  fi
  fix_runtime_perms
  exit 0
fi

args=(nats-bootstrap --local --output-dir "${creds_dir}" --operator-name "${NATS_OPERATOR_NAME}" --output json)
if [[ -n "${NATS_OPERATOR_SEED:-}" ]]; then
  args+=(--import-operator-seed "${NATS_OPERATOR_SEED}")
fi
serviceradar-cli "${args[@]}"
if [[ ! -f "${creds_dir}/operator.seed" ]] && [[ -n "${NATS_OPERATOR_SEED:-}" ]]; then
  echo "Persisting operator seed to creds volume."
  echo "${NATS_OPERATOR_SEED}" > "${creds_dir}/operator.seed"
fi
if [[ ! -f "${creds_dir}/system_account.pub" ]] && [[ -n "${NATS_SYSTEM_ACCOUNT_PUBLIC_KEY:-}" ]]; then
  echo "${NATS_SYSTEM_ACCOUNT_PUBLIC_KEY}" > "${creds_dir}/system_account.pub"
fi
fix_runtime_perms
