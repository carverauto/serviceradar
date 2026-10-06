## Context

Edge host install is `serviceradar-cli edge install`. The leaf package is
`serviceradar-nats`. Collector types map to `serviceradar-log-collector`
(flowgger, otel), `serviceradar-flow-collector` (netflow, sflow), and
`serviceradar-trapd`. GitHub release assets embed that version
(`serviceradar-nats-1.4.83-1.x86_64.rpm`,
`serviceradar-nats_1.4.83_amd64.deb`). `GET /releases/latest/download/<file>`
cannot work until the filename is known, so the CLI reads the latest release
from the GitHub API and selects the asset.

The leaf listens on `local_listen` (default `0.0.0.0:4222`) with mTLS.
Collectors on that host must dial a loopback `tls://` URL, not the bind-all
address and not the platform NATS URL.

## Goals / Non-Goals

- Goals: latest published NATS and collector packages; collectors write to the
  local leaf only after that leaf service is active; keep an explicit
  `--version` pin.
- Non-Goals: floating the agent package; a new API for the host to report
  leaf connectivity (`NatsLeafServer` `:connect` stays unused); opening the
  hub leafnode port; deprovision.

## Decisions

- Decision: resolve latest with
  `GET https://api.github.com/repos/carverauto/serviceradar/releases/latest`,
  then download `{release-base}/<tag>/<asset>`. `--release-api-url` overrides
  the lookup the same way `--release-base-url` overrides the download prefix.
  The tag path is used rather than `browser_download_url`, which points at an
  untagged path for draft assets.
- Decision: confirmation is local. `setup.sh` already exits non-zero when
  `serviceradar-nats` does not become active. The CLI repeats
  `systemctl is-active --quiet serviceradar-nats` as its own step, and
  collector install runs that check before it fetches or applies a bundle
  when the collector has an `edge_site_id`.
- Decision: no new RBAC endpoint. Site and collector routes already require
  `settings.edge.manage`. The site payload gains `local_listen` and
  `client_url` so the operator can see the address the collectors will dial.
- Decision: `nats_leaf_url`, when set, still wins. It is the operator override
  for a collector that is not on the leaf host. A blank URL on an edge-site
  collector means the local client URL.

## Risks / Trade-offs

- Latest can be newer than the tenant chart. That is the requested behavior
  for the edge packages. Agent install stays pinned so it can match the tenant.
- GitHub's unauthenticated API rate limit can fail the lookup. The error tells
  the operator to pass `--version`.
- A wildcard `local_listen` becomes `127.0.0.1`, which is correct for a
  collector on the same host and wrong for a collector on another machine.
  Those collectors set `nats_leaf_url`.

## Migration Plan

No schema change. Existing sites keep their `nats_leaf_url`. Bundles generated
after this change pick up the local client URL only when that field is blank.

## Open Questions

- None. The hub leafnode listener and tenant chart upgrade stay outside this
  change.
