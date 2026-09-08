# Tasks: Verify Documentation Accuracy and Close Coverage Gaps

All paths under `docs/docs/` unless noted. Each accuracy fix cites the proving code.

## 1. Accuracy fixes — core, pipeline, data

- [x] 1.1 `cnpg-monitoring.md` — fix DB name `telemetry` → `serviceradar`
  (`helm/serviceradar/values.yaml:525`, `templates/cnpg-cluster.yaml:99`); schema-qualify
  table names (`logs` → `platform.logs`, etc., per `priv/repo/baseline/platform_schema.sql`).
- [x] 1.2 `architecture.md` — stop calling `core-elx` "the control plane"; the control-plane
  OTP app is `serviceradar_core` (`serviceradar_core_elx/lib/.../application.ex` is a thin
  media-ingress app). Use the service name `core` consistently.
- [x] 1.3 `architecture.md` / `data-pipeline.md` — `log-promotion` is an in-process
  `Jetstream.PullConsumer` in `serviceradar_core`
  (`lib/serviceradar/observability/log_promotion_consumer.ex`), not a separate deployment;
  fix the diagram's separate `Promote` box.
- [x] 1.4 `data-pipeline.md` — the diagram routes NetFlow through Zen; it does not. Zen
  subjects are `*.logs.{syslog,snmp,otel}` and `*.otel.metrics.raw`
  (`rust/consumers/zen/zen-consumer.json`); flows publish to `flows.raw.>`. Route NetFlow
  directly to the writer path.
- [x] 1.5 `rule-builder.md` — correct the Zen subject list (partition-prefixed wildcards;
  add the `*.otel.metrics.raw` group; `logs.internal.*` is not a Zen group).
- [x] 1.6 `edge-model.md` — add the 6th agent-gateway RPC `StreamConfig`
  (`proto/monitoring.proto:31-45`); verify or remove the "mDNS collection" bullet (no mDNS
  code found under `pkg/scan`/`pkg/sweeper`); de-duplicate the RPC list.

## 2. Accuracy fixes — ingestion collectors

- [x] 2.1 `otel.md` — remove the OTLP/HTTP `:4318` claims; the collector serves OTLP over
  gRPC only (`rust/otel/src/server.rs`). Note the otel collector is embedded in
  `log-collector` (`rust/log-collector/src/config.rs`), not standalone; document the
  Prometheus `/metrics` endpoint and reconcile its port (9464 vs 9090).
- [x] 2.2 `service-port-map.md` — remove/scope the `4318 OTLP/HTTP` row; clarify IPFIX is
  decoded on the NetFlow listener (2055), and `4739` is an optional alternate port, not a
  distinct collector (`rust/flow-collector/src/config.rs` `ListenerConfig`).
- [x] 2.3 `netflow.md` — remove the "NetFlow v7" claim (only v5/v9/IPFIX —
  `rust/flow-collector/src/netflow/converter.rs:529-533`); fix the config example —
  `max_templates`/`max_template_fields`/`buffer_size` are per-listener, not top-level; add
  the real top-level keys (`stream_subjects`, `stream_max_bytes`, `stream_replicas`,
  `pending_flows`).
- [x] 2.4 `syslog.md` — remove the RELP recommendation (flowgger inputs are udp/tcp/tls/
  file/redis/stdin only); document the TCP syslog collector (`log-collector-tcp`,
  `helm/.../templates/log-collector-tcp.yaml`).
- [x] 2.5 `snmp.md` — reframe SNMP polling as an embedded agent service, not a "gateway"
  function (`go/pkg/agent/snmp_service.go`); remove the `curl http://agent:8080/status`
  step (no such HTTP endpoint); verify local-override config keys against the agent struct;
  add a trapd security-mode note (`mtls`/`spiffe`/`none`, gRPC health port 50043 —
  `rust/trapd/src/config.rs`).
- [x] 2.6 `bgp-routing.md` — correct the BMP status: BMP ingest IS deployed (the
  `bmp-collector` template runs the upstream `arancini` image; stream `ARANCINI_CAUSAL`,
  subjects `arancini.updates.>`, port 11019). Replace "not yet available" with an accurate
  BMP-ingest section; resolve whether BMP data joins `bgp_routing_info` (design open Q).

## 3. Accuracy fixes — edge, deploy, UI, API

- [x] 3.1 `network-sweeps.md` — state that `tcp` mode performs SYN scanning (cross-link
  `syn-scanner-tuning.md`); modes are `tcp`/`tcp_connect`/`icmp` (`go/pkg/models/sweep.go:94-96`).
- [x] 3.2 `helm-configuration.md` — refresh the stale version pins (`1.2.20` → current
  `1.2.73`, `Chart.yaml`); point the HA example at `values-ha.yaml`; note `spire.enabled`
  defaults `false`.
- [x] 3.3 `tls-security.md` — expand the thin page: SPIRE/SPIFFE setup and key values
  (`spire.enabled` default `false`, trust domain), and the in-chart `cert-generator-job` /
  `cert-regenerator-job` alternative.
- [x] 3.4 `sysmon-profiles.md` — verify the macOS local-config path
  (`/usr/local/etc/serviceradar/sysmon.json`) against `go/pkg/agent/sysmon_service.go`;
  fix if stale.
- [x] 3.5 Replace the stale `docs/openapi/index.yaml` (legacy `/api/pollers/*`) with the
  current `web-ng` API spec (export from `/api/docs/v1/admin/openapi.json` if a running
  instance is available; otherwise a minimal accurate spec).

## 4. New documentation — close coverage gaps

- [x] 4.1 Create `rperf.md` — Network Performance Testing: what rperf measures
  (TCP/UDP throughput, jitter, loss); the checker (`rust/rperf-client`, port 50081, mTLS)
  and the `serviceradar-rperf` server (`rust/rperf-server`, port 5199 + UDP 5200-5210);
  Helm `rperf-checker` deployment; querying results via the SRQL `rperf` alias.
- [x] 4.2 Create `cli-reference.md` — the `serviceradar` CLI (`go/cmd/cli`,
  `go/pkg/cli/help.go`): `update-config`, `update-gateway`, `generate-tls`,
  `generate-jwt-keys`, `spire-join-token`, `enroll`, `edge package …`, `nats-bootstrap`,
  `admin nats`, bcrypt hashing.
- [x] 4.3 Create `configuration-system.md` — the NATS-KV configuration model via `datasvc`
  (`rust/config-bootstrap/`, `rust/kvutil/`; `kv.address`, `kv.bucket`), file vs. KV
  precedence. Written fresh — not seeded from the stale unpublished docs.
- [x] 4.4 Create `rbac-and-roles.md` — the four roles (`viewer`/`helpdesk`/`operator`/
  `admin`, `serviceradar/identity/constants.ex`), the permission catalog
  (`identity/rbac/catalog.ex`), and custom role profiles (`/api/admin/role-profiles`).
- [x] 4.5 Create `agent-configuration.md` — the agent config-file reference
  (`go/pkg/agent/types.go` `ServerConfig`: `gateway_addr` required, `sync_runtime_enabled`,
  `remote_access_rdp_enabled`, `checkers_dir`, `kv_address`, etc.) and the agent check
  types (`icmp`/`tcp`/`http`/`grpc`/`process`/`sweep`/`mtr`, `proto/monitoring.proto:491-508`),
  including MTR checks.
- [x] 4.6 Create `web-ui-overview.md` — a map of the web UI (Dashboard, Devices,
  Interfaces, Agents, Gateways, Events, Alerts, Observability, Topology, NetFlow Map,
  Diagnostics, Settings) for new users.
- [x] 4.7 Create `api-reference.md` — API authentication (session vs. API credentials at
  `/settings/api-credentials`) and the `/api/query` SRQL endpoint; link the `/api/` spec.
- [x] 4.8 Document `datasvc` as a section in `data-pipeline.md` (KV + object-store gRPC
  role) and add a `platform`-schema / data-model overview to `database-bootstrap.md`.

## 5. Concision trims

- [x] 5.1 `netflow.md` — remove the BGP section duplicated with `bgp-routing.md` (replace
  with a pointer); move the per-vendor flow-export configs and developer type-conversion
  notes out of the user guide; soften the unsourced throughput numbers.
- [x] 5.2 `remote-access.md` — collapse the rotation procedure and custody guidance stated
  multiple times into one of each; move the signer env-var list into a reference table.
- [x] 5.3 `remote-access-rdp.md` — remove the duplicated checklists; keep one canonical
  JSON policy example.
- [x] 5.4 `helm-configuration.md` — trim the sweep-tuning bulk (it duplicates
  `network-sweeps.md` / `syn-scanner-tuning.md`); lead with install, HA, and networking.
- [x] 5.5 `cnpg-monitoring.md`, `database-bootstrap.md`, `observability-rollup-recovery.md`
  — remove changelog-style narration and trim deep internal-runbook detail; keep the
  operator-facing guidance.
- [x] 5.6 `srql-language-reference.md` — remove the internal source-path "Reference notes";
  optionally mention the `rperf` entity alias.

## 6. Navigation and validation

- [x] 6.1 Add the new pages to `sidebars.ts` (rperf under "Edge & Agents" or a new
  "Reference" group; `cli-reference`, `configuration-system`, `rbac-and-roles`,
  `agent-configuration`, `web-ui-overview`, `api-reference` placed sensibly).
- [x] 6.2 `npm run build` passes with zero broken links (`onBrokenLinks: throw`).
- [x] 6.3 Spot-check each accuracy fix against its cited code reference.
- [x] 6.4 `openspec validate update-documentation-accuracy-and-coverage --strict`.
