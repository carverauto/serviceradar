#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/serviceradar"

if [[ -n "${HELM_BIN:-}" ]]; then
  HELM_CMD=("${HELM_BIN}")
elif command -v helm >/dev/null 2>&1; then
  HELM_CMD=(helm)
else
  HELM_CMD=("${ROOT_DIR}/scripts/run-helm.sh")
fi

tmp_root="${ROOT_DIR}/.helm-defaults-check"
mkdir -p "${tmp_root}"
tmpdir="$(mktemp -d "${tmp_root}/run.XXXXXXXX")"
trap 'rm -rf "${tmpdir}"; rmdir "${tmp_root}" 2>/dev/null || true' EXIT

legacy_values="${tmpdir}/legacy-values.yaml"
cat >"${legacy_values}" <<'YAML'
core:
  eventWriter: {}
  anomalyDetectionConfig: {}
  capacityForecasting: {}
  capacityForecastConfig: {}
YAML

render_env() {
  local output_file="$1"
  shift

  "${HELM_CMD[@]}" template serviceradar "${CHART_DIR}" \
    --show-only templates/core.yaml \
    --set global.imageTag="v1.0.0" \
    "$@" >"${output_file}"
}

assert_env() {
  local rendered="$1"
  local name="$2"
  local expected="$3"

  python3 - "$rendered" "$name" "$expected" <<'PY'
import re
import sys

path, wanted_name, wanted_value = sys.argv[1:4]
text = open(path, "r", encoding="utf-8").read()

pattern = re.compile(
    r"^\s*-\s+name:\s+" + re.escape(wanted_name) +
    r"\s*\n\s+value:\s+(?P<value>.+?)\s*$",
    re.MULTILINE,
)
match = pattern.search(text)

if match is None:
    print(f"missing env {wanted_name}", file=sys.stderr)
    sys.exit(1)

actual = match.group("value").strip().strip('"')

if actual != wanted_value:
    print(
        f"{wanted_name}: expected {wanted_value!r}, got {actual!r}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

assert_env_absent() {
  local rendered="$1"
  local name="$2"

  if grep -qE "^[[:space:]]*-[[:space:]]+name:[[:space:]]+${name}$" "${rendered}"; then
    echo "unexpected env ${name}" >&2
    exit 1
  fi
}

check_default_render() {
  local rendered="${tmpdir}/default.yaml"

  render_env "${rendered}"

  assert_env "${rendered}" "EVENT_WRITER_ENABLED" "true"
  assert_env_absent "${rendered}" "ANOMALY_ANALYSIS_CONSUMER_ENABLED"
  assert_env "${rendered}" "SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON" '{\"cpu\":{\"drift_mode\":\"deseasonalized_only\"},\"disk\":{\"drift_mode\":\"off\"},\"icmp\":{\"drift_mode\":\"off\"},\"interface\":{\"drift_mode\":\"deseasonalized_only\"},\"memory\":{\"drift_mode\":\"deseasonalized_only\"},\"other\":{\"drift_mode\":\"off\"},\"red\":{}}'
  assert_env "${rendered}" "SERVICERADAR_CAPACITY_FORECASTING_ENABLED" "true"
  assert_env "${rendered}" "SERVICERADAR_CAPACITY_FORECASTING_MIN_POINTS" "72"
  assert_env "${rendered}" "SERVICERADAR_CAPACITY_FORECAST_CONFIG_METRIC_CLASS_OVERRIDES_JSON" '{\"cpu\":{},\"disk\":{},\"flow\":{},\"interface\":{},\"memory\":{}}'
}

check_legacy_missing_values_render() {
  local rendered="${tmpdir}/legacy.yaml"

  render_env "${rendered}" -f "${legacy_values}"

  assert_env "${rendered}" "EVENT_WRITER_ENABLED" "true"
  assert_env "${rendered}" "SERVICERADAR_CAPACITY_FORECASTING_ENABLED" "true"
  assert_env "${rendered}" "SERVICERADAR_CAPACITY_FORECASTING_MIN_POINTS" "72"
}

check_demo_render() {
  local rendered="${tmpdir}/demo.yaml"

  render_env "${rendered}" -f "${CHART_DIR}/values-demo.yaml"

  assert_env "${rendered}" "EVENT_WRITER_ENABLED" "true"
  assert_env "${rendered}" "SERVICERADAR_CAPACITY_FORECASTING_ENABLED" "true"
  assert_env "${rendered}" "SERVICERADAR_CAPACITY_FORECASTING_MIN_POINTS" "72"
}

check_default_render
check_legacy_missing_values_render
check_demo_render

echo "core analytics Helm defaults are safe"
