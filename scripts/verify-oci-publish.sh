#!/usr/bin/env bash
set -euo pipefail

if ! command -v skopeo >/dev/null 2>&1; then
  echo "error: skopeo is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if [[ "$#" -eq 0 ]]; then
  TAGS=("latest")
else
  TAGS=("$@")
fi

REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
OCI_REPOSITORY_BASE="${REGISTRY_HOST}/${OCI_PROJECT}"

declare -a IMAGE_SPECS=(
  "${OCI_REPOSITORY_BASE}/serviceradar-web-ng|single"
  "${OCI_REPOSITORY_BASE}/serviceradar-core-elx|single"
  "${OCI_REPOSITORY_BASE}/serviceradar-agent-gateway|single"
  "${OCI_REPOSITORY_BASE}/serviceradar-agent|single"
  "${OCI_REPOSITORY_BASE}/serviceradar-log-collector|index"
  "${OCI_REPOSITORY_BASE}/serviceradar-trapd|index"
  "${OCI_REPOSITORY_BASE}/serviceradar-flow-collector|index"
  "${OCI_REPOSITORY_BASE}/arancini|index"
  "${OCI_REPOSITORY_BASE}/serviceradar-rperf-client|index"
  "${OCI_REPOSITORY_BASE}/serviceradar-faker|index"
  "${OCI_REPOSITORY_BASE}/serviceradar-zen|index"
  "${OCI_REPOSITORY_BASE}/serviceradar-tools|single"
)

fail() {
  echo "error: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "$context: expected '$expected', got '$actual'"
  fi
}

assert_contains_env() {
  local config_json="$1"
  local expected="$2"
  local context="$3"
  if ! jq -e --arg expected "$expected" '.config.Env // [] | index($expected)' <<<"$config_json" >/dev/null; then
    fail "$context: missing env '$expected'"
  fi
}

check_image_shape() {
  local tag="$1"
  local ref="$2"
  local kind="$2"
  kind="$3"
  local raw
  raw="$(skopeo inspect --raw "docker://${ref}:${tag}")"
  local media_type
  media_type="$(jq -r '.mediaType' <<<"$raw")"

  if [[ "$kind" == "index" ]]; then
    assert_eq "$media_type" "application/vnd.oci.image.index.v1+json" "${ref}:${tag} mediaType"
    jq -e '
      [.manifests[].platform | "\(.os)/\(.architecture)\(if .variant then "/" + .variant else "" end)"] as $platforms
      | ($platforms | index("linux/amd64")) != null
      and ($platforms | index("linux/arm64/v8")) != null
    ' <<<"$raw" >/dev/null || fail "${ref}:${tag} is missing amd64/arm64-v8 manifests"
  else
    assert_eq "$media_type" "application/vnd.oci.image.manifest.v1+json" "${ref}:${tag} mediaType"
  fi
}

check_config() {
  local tag="$1"
  local ref="$2"
  local config
  config="$(skopeo inspect --override-arch amd64 --config "docker://${ref}:${tag}")"

  case "${ref##*/}" in
    serviceradar-web-ng)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/app/bin/serviceradar_web_ng"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["start"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/app" "${ref}:${tag} workdir"
      assert_contains_env "$config" "PHX_SERVER=true" "${ref}:${tag}"
      assert_contains_env "$config" "MIX_ENV=prod" "${ref}:${tag}"
      ;;
    serviceradar-core-elx)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/app/bin/serviceradar_core_elx"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["start"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/app" "${ref}:${tag} workdir"
      assert_contains_env "$config" "MIX_ENV=prod" "${ref}:${tag}"
      ;;
    serviceradar-agent-gateway)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/app/bin/serviceradar_agent_gateway"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["start"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/app" "${ref}:${tag} workdir"
      assert_contains_env "$config" "MIX_ENV=prod" "${ref}:${tag}"
      ;;
    serviceradar-agent)
      assert_eq "$(jq -c '.config.Entrypoint // []' <<<"$config")" '[]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/usr/local/lib/serviceradar/agent/serviceradar-agent-seed","-config","/etc/serviceradar/agent.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-log-collector)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/entrypoint.sh"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["serviceradar-log-collector"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-flow-collector)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/serviceradar-flow-collector"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["--config","/etc/serviceradar/flow-collector.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    arancini)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/serviceradar-bmp-collector"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd // []' <<<"$config")" '[]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-rperf-client)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/entrypoint.sh"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/usr/local/bin/serviceradar-rperf-checker","--config","/etc/serviceradar/checkers/rperf.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-faker)
      assert_eq "$(jq -c '.config.Entrypoint // []' <<<"$config")" '[]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/usr/local/bin/serviceradar-faker","-config","/etc/serviceradar/faker.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-zen)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/entrypoint.sh"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["serviceradar-zen"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-tools)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/entrypoint.sh"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/bin/sh"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/" "${ref}:${tag} workdir"
      assert_contains_env "$config" "PATH=/usr/libexec/postgresql18:/usr/local/bin:/usr/bin:/bin" "${ref}:${tag}"
      ;;
  esac
}

for tag in "${TAGS[@]}"; do
  for spec in "${IMAGE_SPECS[@]}"; do
    IFS="|" read -r ref kind <<<"$spec"
    echo "checking ${ref}:${tag}"
    check_image_shape "$tag" "$ref" "$kind"
    check_config "$tag" "$ref"
  done
done

echo "verified OCI publish metadata for tags: ${TAGS[*]}"
