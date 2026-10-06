# Change: Install the latest edge NATS and collector packages

## Why

`edge install leaf` and `edge install collector` require the operator to type
the tenant chart version, then look for a GitHub release asset with that
version in the filename. The packages the edge host should run are the ones
published on the latest ServiceRadar GitHub release. Collectors assigned to an
edge site also fall back to the in-cluster NATS URL when `nats_leaf_url` is
blank, and the CLI applies that config without checking that the local leaf
is up.

## What Changes

- `edge install leaf` and `edge install collector` download the matching
  package from the latest `carverauto/serviceradar` GitHub release when
  `--version` is omitted. `--version` still pins a release. `edge install
  agent` still requires `--version`.
- After the leaf bundle's `setup.sh`, the CLI confirms `serviceradar-nats` is
  active. A collector bound to an edge site is not configured until that
  local service is active.
- An edge-site collector bundle with no `nats_leaf_url` uses a `tls://` client
  URL derived from the leaf's `local_listen` (a wildcard bind becomes
  `127.0.0.1`). An explicit `nats_leaf_url` remains the override.
- `GET /api/admin/edge-sites` includes `local_listen` and `client_url` on the
  leaf server. These routes already require `settings.edge.manage`. No new
  endpoint is added.

## Impact

- Affected specs: `edge-host-install` (new)
- Affected code: `js/cli` edge install, collector bundle NATS URL, edge-site
  JSON
