#!/usr/bin/env bash
set -euo pipefail

unit="$1"
agent_addon_root="/var/lib/serviceradar/agent/addons"
privileged_prefix="/usr/lib/serviceradar/addons/workload-identity/current/"

parsed="$(
  awk '
    /\\$/ {
      line = line substr($0, 1, length($0) - 1) " "
      next
    }
    {
      line = line $0
      print line
      line = ""
    }
  ' "$unit" | awk -F= '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ { next }
    /^[[:space:]]*[A-Za-z][A-Za-z0-9]*=/ {
      key = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print key "\t" value
    }
  '
)"

field() {
  local key="$1"
  printf '%s\n' "$parsed" | awk -F '\t' -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }'
}

command_path() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  while [[ "$value" == [-+@!]* ]]; do
    value="${value:1}"
  done
  if [[ "$value" == \"* ]]; then
    value="${value:1}"
    printf '%s\n' "${value%%\"*}"
    return
  fi
  printf '%s\n' "${value%% *}"
}

user="$(field User)"
group="$(field Group)"
bounding="$(field CapabilityBoundingSet)"
mode="$(field StateDirectoryMode)"
read_write="$(field ReadWritePaths)"
exec_start="$(command_path "$(field ExecStart)")"

if ! printf '%s\n' "$parsed" | awk -F '\t' '$1=="CapabilityBoundingSet" { found=1 } END { exit !found }'; then
  echo "workload identity must set an empty CapabilityBoundingSet" >&2
  exit 1
fi
if [[ "$user" != "root" || "$group" != "serviceradar" ]]; then
  echo "workload identity must run as root:serviceradar, got ${user}:${group}" >&2
  exit 1
fi
if [[ "$mode" != "2770" ]]; then
  echo "workload identity StateDirectoryMode = ${mode}, want 2770" >&2
  exit 1
fi
if [[ "$bounding" == *CAP_DAC_OVERRIDE* ]]; then
  echo "workload identity must use state-directory permissions, not CAP_DAC_OVERRIDE" >&2
  exit 1
fi
if [[ -z "$read_write" || "$read_write" == *"$agent_addon_root"* ]]; then
  echo "workload identity ReadWritePaths must not include the agent-writable tree: ${read_write}" >&2
  exit 1
fi
case "$exec_start" in
  "$privileged_prefix"*) ;;
  *)
    echo "workload identity ExecStart command = ${exec_start}, want ${privileged_prefix}*" >&2
    exit 1
    ;;
esac

while IFS= read -r line; do
  key="${line%%$'\t'*}"
  value="${line#*$'\t'}"
  case "$key" in
    ExecStart | ExecStartPre | ExecStartPost | ExecStop | ExecStopPost | ExecReload | ExecCondition)
      path="$(command_path "$value")"
      case "$path" in
        "$agent_addon_root" | "$agent_addon_root"/*)
          echo "workload identity ${key} executes from the agent-writable tree: ${path}" >&2
          exit 1
          ;;
      esac
      ;;
  esac
done <<< "$parsed"
