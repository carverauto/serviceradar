#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: import-dashboard-package.sh MANIFEST_JSON RENDERER_JS

Import and enable a dashboard package into the Docker-backed web-ng database by
using the running Docker web-ng release RPC.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 2 ]]; then
  usage
  [[ $# -eq 2 ]] || exit 2
fi

manifest="$(realpath "$1")"
renderer="$(realpath "$2")"
web_container="${WEB_NG_CONTAINER:-serviceradar-web-ng-mtls}"

if [[ ! -s "$manifest" ]]; then
  echo "manifest not found or empty: $manifest" >&2
  exit 1
fi

if [[ ! -s "$renderer" ]]; then
  echo "renderer not found or empty: $renderer" >&2
  exit 1
fi

if ! docker inspect "$web_container" >/dev/null 2>&1; then
  echo "container not found: $web_container" >&2
  exit 1
fi

docker cp "$manifest" "$web_container:/tmp/dashboard-manifest.json"
docker cp "$renderer" "$web_container:/tmp/dashboard-renderer.js"

docker exec "$web_container" /app/bin/serviceradar_web_ng rpc '
manifest = File.read!("/tmp/dashboard-manifest.json")
renderer = File.read!("/tmp/dashboard-renderer.js")
{:ok, package} =
  ServiceRadarWebNG.Dashboards.Packages.import_json(
    manifest,
    renderer,
    scope: nil,
    signature: %{"kind" => "local_docker_loop_import"}
  )
{:ok, package} = ServiceRadarWebNG.Dashboards.Packages.enable(package.id, scope: nil)
IO.inspect(%{
  status: package.status,
  hash: package.content_hash,
  renderer_sha: package.renderer["sha256"]
}, limit: :infinity)
'
