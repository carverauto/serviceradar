#!/usr/bin/env bash
set -euo pipefail

script_under_test="${1:-scripts/prepare-flow-collector-rollback.sh}"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

calls_file="$fixture_dir/calls"
state_file="$fixture_dir/state"
printf 'flows\n' >"$state_file"
: >"$calls_file"

cat >"$fixture_dir/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >>"$CALLS_FILE"
if [[ "$1 $2" == "get values" ]]; then
  # Keep an unrelated events stream in every fixture. The helper must inspect
  # flowCollector.config.stream_name, not grep the whole release for "events".
  printf '{"flowCollector":{"config":{"stream_name":"%s"}},"logCollector":{"stream_name":"events"}}\n' "${TARGET_STREAM:-events}"
fi
EOF

cat >"$fixture_dir/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
filter="$*"
input="$(cat)"
if [[ "$filter" == *'.flowCollector.config.stream_name // empty'* ]]; then
  if [[ "$input" == *'"flowCollector":{"config":{"stream_name":"flows"}}'* ]]; then
    printf 'flows\n'
  else
    printf 'events\n'
  fi
elif [[ "$filter" == *'.stream_name // empty'* ]]; then
  if [[ "$input" == *'"stream_name":"events"'* ]]; then
    printf 'events\n'
  else
    printf 'flows\n'
  fi
elif [[ "$filter" == *'.ready_state_path'* ]]; then
  printf '/var/lib/serviceradar/flow-collector.ready\n'
else
  printf '%s' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"serviceradar-flow-collector-config"},"data":{"flow-collector.json":"{\"stream_name\":\"events\",\"ready_state_path\":\"/var/lib/serviceradar/flow-collector.ready\"}"}}'
fi
EOF

cat >"$fixture_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$CALLS_FILE"
args="$*"
case "$args" in
  *'get deployment serviceradar-flow-collector -o jsonpath={.spec.strategy.type}'*)
    printf 'Recreate'
    ;;
  *'get deployment serviceradar-flow-collector -o jsonpath={.spec.replicas}'*)
    printf '1'
    ;;
  *'readinessProbe.exec.command'*)
    printf '/bin/sh -c test -f /var/lib/serviceradar/flow-collector.ready'
    ;;
  *'containers[?(@.name=="flow-collector")].image'*)
    printf 'registry.example/flow:new'
    ;;
  *'get configmap serviceradar-flow-collector-config -o jsonpath='*)
    stream="$(cat "$STATE_FILE")"
    printf '{"stream_name":"%s","ready_state_path":"/var/lib/serviceradar/flow-collector.ready"}' "$stream"
    ;;
  *'get configmap serviceradar-flow-collector-config -o json'*)
    printf '%s' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"serviceradar-flow-collector-config"},"data":{"flow-collector.json":"{\"stream_name\":\"flows\",\"ready_state_path\":\"/var/lib/serviceradar/flow-collector.ready\"}"}}'
    ;;
  *'replace -f -'*)
    cat >/dev/null
    printf 'events\n' >"$STATE_FILE"
    ;;
  *'logs deployment/serviceradar-flow-collector'*)
    printf 'Connected to NATS (legacy events stream, dup_window=120s)\n'
    ;;
  *)
    ;;
esac
EOF

chmod +x "$fixture_dir/helm" "$fixture_dir/jq" "$fixture_dir/kubectl"

CALLS_FILE="$calls_file" STATE_FILE="$state_file" \
KUBECTL_BIN="$fixture_dir/kubectl" HELM_BIN="$fixture_dir/helm" JQ_BIN="$fixture_dir/jq" \
  bash "$script_under_test" --release serviceradar --namespace demo --revision 7 --timeout 1m

replace_line="$(grep -n 'kubectl .*replace -f -' "$calls_file" | cut -d: -f1)"
rollback_line="$(grep -n 'helm rollback serviceradar 7' "$calls_file" | cut -d: -f1)"
[[ -n "$replace_line" && -n "$rollback_line" && "$replace_line" -lt "$rollback_line" ]]

: >"$calls_file"
printf 'flows\n' >"$state_file"
if CALLS_FILE="$calls_file" STATE_FILE="$state_file" TARGET_STREAM=flows \
  KUBECTL_BIN="$fixture_dir/kubectl" HELM_BIN="$fixture_dir/helm" JQ_BIN="$fixture_dir/jq" \
    bash "$script_under_test" --release serviceradar --namespace demo --revision 8 >/dev/null 2>&1; then
  echo "expected target stream validation to fail" >&2
  exit 1
fi
if grep -q 'kubectl .*replace -f -' "$calls_file"; then
  echo "target validation failed after mutating the ConfigMap" >&2
  exit 1
fi

# GitOps prepare-only mode must not depend on Helm release history. Validate
# the rendered target flow config directly and leave Helm entirely unavailable.
: >"$calls_file"
printf 'flows\n' >"$state_file"
printf '%s\n' '{"stream_name":"events"}' >"$fixture_dir/legacy-flow-collector.json"
CALLS_FILE="$calls_file" STATE_FILE="$state_file" \
KUBECTL_BIN="$fixture_dir/kubectl" HELM_BIN="$fixture_dir/no-helm-history" JQ_BIN="$fixture_dir/jq" \
  bash "$script_under_test" --namespace demo --prepare-only \
    --target-config "$fixture_dir/legacy-flow-collector.json" --timeout 1m
if grep -q '^helm ' "$calls_file"; then
  echo "GitOps prepare-only mode unexpectedly used Helm release history" >&2
  exit 1
fi
if ! grep -q 'kubectl .*replace -f -' "$calls_file"; then
  echo "GitOps prepare-only mode did not perform the reverse-transfer mutation" >&2
  exit 1
fi

: >"$calls_file"
printf 'flows\n' >"$state_file"
printf '%s\n' '{"stream_name":"flows"}' >"$fixture_dir/nonlegacy-flow-collector.json"
if CALLS_FILE="$calls_file" STATE_FILE="$state_file" \
  KUBECTL_BIN="$fixture_dir/kubectl" HELM_BIN="$fixture_dir/no-helm-history" JQ_BIN="$fixture_dir/jq" \
    bash "$script_under_test" --namespace demo --prepare-only \
      --target-config "$fixture_dir/nonlegacy-flow-collector.json" >/dev/null 2>&1; then
  echo "expected non-legacy GitOps target validation to fail" >&2
  exit 1
fi
if grep -q 'kubectl .*replace -f -' "$calls_file"; then
  echo "GitOps target validation failed after mutating the ConfigMap" >&2
  exit 1
fi

printf 'prepare-flow-collector-rollback contract tests passed\n'
