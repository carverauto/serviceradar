#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Prepare and optionally execute a Helm rollback across the flows-stream migration.

Usage:
  prepare-flow-collector-rollback.sh \
    --release RELEASE --namespace NAMESPACE --revision REVISION [options]
  prepare-flow-collector-rollback.sh \
    --namespace NAMESPACE --prepare-only --target-config FLOW_COLLECTOR_JSON [options]

Required:
  --namespace NAMESPACE   Kubernetes namespace containing the flow collector.

Helm rollback mode:
  --release RELEASE       Helm release name.
  --revision REVISION     Legacy Helm revision whose flow collector targets events.

GitOps prepare-only mode:
  --target-config FILE    Standalone flow-collector.json rendered by the target
                          GitOps revision. It must set stream_name to events.

Options:
  --timeout DURATION      kubectl/Helm wait timeout (default: 5m).
  --prepare-only          Stop after the current image transfers subjects to events.
                          Use this only after pausing GitOps reconciliation, then
                          point GitOps at the legacy revision immediately.
  -h, --help              Show this help.

Why this helper exists:
  A plain `helm rollback` restores the old flow-collector image and old config at
  the same time. That image cannot detach flow subjects from the dedicated `flows`
  stream. This helper first restarts the CURRENT migration-capable image with
  stream_name=events, waits for its readiness gate and reverse-transfer log, and
  only then restores the requested old Helm revision.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

release=""
namespace=""
revision=""
target_config=""
timeout="5m"
prepare_only="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      [[ $# -ge 2 ]] || fail "--release requires a value"
      release="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || fail "--namespace requires a value"
      namespace="$2"
      shift 2
      ;;
    --revision)
      [[ $# -ge 2 ]] || fail "--revision requires a value"
      revision="$2"
      shift 2
      ;;
    --target-config)
      [[ $# -ge 2 ]] || fail "--target-config requires a value"
      target_config="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || fail "--timeout requires a value"
      timeout="$2"
      shift 2
      ;;
    --prepare-only)
      prepare_only="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$namespace" ]] || fail "--namespace is required"

if [[ -n "$target_config" ]]; then
  [[ "$prepare_only" == "true" ]] || fail "--target-config is valid only with --prepare-only"
  [[ -z "$release" && -z "$revision" ]] || fail "--target-config cannot be combined with --release/--revision"
  [[ -r "$target_config" ]] || fail "target flow-collector config is not readable: $target_config"
else
  [[ -n "$release" ]] || fail "--release is required unless --prepare-only uses --target-config"
  [[ "$revision" =~ ^[1-9][0-9]*$ ]] || fail "--revision must be a positive Helm revision"
fi

kubectl_bin="${KUBECTL_BIN:-kubectl}"
helm_bin="${HELM_BIN:-helm}"
jq_bin="${JQ_BIN:-jq}"

command -v "$kubectl_bin" >/dev/null 2>&1 || fail "kubectl executable not found: $kubectl_bin"
command -v "$jq_bin" >/dev/null 2>&1 || fail "jq executable not found: $jq_bin"
if [[ -z "$target_config" ]]; then
  command -v "$helm_bin" >/dev/null 2>&1 || fail "helm executable not found: $helm_bin"
fi

deployment="serviceradar-flow-collector"
configmap="serviceradar-flow-collector-config"
config_key="flow-collector.json"

if [[ -n "$target_config" ]]; then
  target_stream="$("$jq_bin" -r '.stream_name // empty' <"$target_config")"
  target_label="GitOps config $target_config"
else
  target_values="$($helm_bin get values "$release" --namespace "$namespace" --revision "$revision" --all -o json)"
  target_stream="$(printf '%s\n' "$target_values" | "$jq_bin" -r '.flowCollector.config.stream_name // empty')"
  target_label="Helm revision $revision"
fi
if [[ "$target_stream" != "events" ]]; then
  fail "$target_label targets stream '$target_stream', not legacy events; use an ordinary rollout for targets that already use flows"
fi

strategy="$($kubectl_bin --namespace "$namespace" get deployment "$deployment" -o jsonpath='{.spec.strategy.type}')"
[[ "$strategy" == "Recreate" ]] || fail "current $deployment strategy is $strategy, not migration-safe Recreate"
replicas="$($kubectl_bin --namespace "$namespace" get deployment "$deployment" -o jsonpath='{.spec.replicas}')"
[[ "$replicas" == "1" ]] || fail "current $deployment has $replicas replicas; reverse transfer requires exactly one publisher"

current_config="$($kubectl_bin --namespace "$namespace" get configmap "$configmap" -o "jsonpath={.data.${config_key//./\\.}}")"
current_stream="$(printf '%s\n' "$current_config" | "$jq_bin" -r '.stream_name // empty')"
ready_path="$(printf '%s\n' "$current_config" | "$jq_bin" -r '.ready_state_path // "/var/lib/serviceradar/flow-collector.ready"')"
readiness_command="$($kubectl_bin --namespace "$namespace" get deployment "$deployment" -o 'jsonpath={.spec.template.spec.containers[?(@.name=="flow-collector")].readinessProbe.exec.command[*]}')"
[[ "$readiness_command" == *"$ready_path"* ]] || fail "current readiness probe does not gate on $ready_path; refusing to trust old-image pgrep readiness"

current_image="$($kubectl_bin --namespace "$namespace" get deployment "$deployment" -o 'jsonpath={.spec.template.spec.containers[?(@.name=="flow-collector")].image}')"
printf 'Preparing flow ownership with current image %s in namespace %s.\n' "$current_image" "$namespace"

case "$current_stream" in
  flows)
    current_cm="$($kubectl_bin --namespace "$namespace" get configmap "$configmap" -o json)"
    legacy_cm="$(
      printf '%s\n' "$current_cm" |
        "$jq_bin" '.data["flow-collector.json"] |= (fromjson | .stream_name = "events" | tojson)'
    )"
    printf '%s\n' "$legacy_cm" | "$kubectl_bin" --namespace "$namespace" replace -f - >/dev/null

    # Recreate plus the RWO marker PVC ensures only this migration-capable
    # publisher owns the transfer while it moves subjects back to events.
    "$kubectl_bin" --namespace "$namespace" rollout restart "deployment/$deployment" >/dev/null
    ;;
  events)
    printf 'ConfigMap already targets events; verifying the prepared current-image pod.\n'
    ;;
  *)
    fail "current flow collector targets unexpected stream '$current_stream'"
    ;;
esac

"$kubectl_bin" --namespace "$namespace" rollout status "deployment/$deployment" --timeout "$timeout"
"$kubectl_bin" --namespace "$namespace" wait --for=condition=Available "deployment/$deployment" --timeout "$timeout" >/dev/null

prepared_config="$($kubectl_bin --namespace "$namespace" get configmap "$configmap" -o "jsonpath={.data.${config_key//./\\.}}")"
prepared_stream="$(printf '%s\n' "$prepared_config" | "$jq_bin" -r '.stream_name // empty')"
[[ "$prepared_stream" == "events" ]] || fail "prepared ConfigMap reverted to $prepared_stream before rollback; pause GitOps reconciliation and retry"

prepared_logs="$($kubectl_bin --namespace "$namespace" logs "deployment/$deployment" --tail=200)"
if ! grep -Fq 'legacy events stream' <<<"$prepared_logs"; then
  fail "current collector became available but did not confirm the legacy events stream path; leaving the old image untouched"
fi

printf 'Current image is ready after transferring flow subjects back to events.\n'
if [[ "$prepare_only" == "true" ]]; then
  printf 'Preparation complete. Keep reconciliation paused and apply %s now.\n' "$target_label"
  exit 0
fi

printf 'Rolling Helm release %s back to revision %s.\n' "$release" "$revision"
"$helm_bin" rollback "$release" "$revision" --namespace "$namespace" --wait --timeout "$timeout"
printf 'Rollback complete. The old image started only after events regained flow-subject ownership.\n'
