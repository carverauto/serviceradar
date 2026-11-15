## Context
Issue `#6518` investigated transient `:connect_timeout` and `:nxdomain` connect failures against healthy in-cluster services (including StarRocks FE Stream Load HTTP endpoints and internal gRPC/NATS/CNPG peers). Client connect budgets are intentionally 5 seconds (`5_000 ms`); raising per-caller timeouts would mask stalls and hold worker pools longer rather than fixing name resolution.

Inspection of the resolver path established three compounding mechanisms:
1. **Unbounded `ndots:5` search-path amplification and 5-second glibc retry stall**: Every chart pod previously rendered with no `dnsConfig`, inheriting `options ndots:5` with glibc defaults (`timeout:5`, `attempts:2`, parallel `A`+`AAAA` over one ephemeral UDP port). Any `<5`-dot target (0-dot `<svc>` or 2-dot `<svc>.<ns>.svc`) walks search suffixes before trying the absolute name, and a single dropped UDP packet stalls resolution for 5,000 ms -- exhausting 5,000 ms caller connect budgets on the first attempt.
2. **Shared dual-stack UDP socket races under IPVS `:53/UDP` conntrack**: Sending parallel `A` and `AAAA` queries from the same ephemeral UDP source port can drop or race replies across `kube-proxy` IPVS conntrack; `single-request-reopen` uses distinct sockets on dual-stack lookups and retries.
3. **Pod-namespace CoreDNS UDP receive-buffer drops masked on host metrics**: Host-level `node_netstat_Udp_RcvbufErrors` reads the root network namespace (`0`), whereas CoreDNS pods run in isolated pod network namespaces where `/proc/<pid>/net/snmp` `Udp: RcvbufErrors` accounts for 100% of `Udp: InErrors` when concurrent lookup bursts overflow the default 208 KiB (`212992` byte) UDP socket receive buffer.

## Goals / Non-Goals
- **Goals**:
  - Bound single-packet DNS loss recovery inside existing 5-second client connect budgets (`timeout: "2"`, `attempts: "2"`, `single-request-reopen`) by default on every install without a Helm-only switch.
  - Eliminate search-domain `NXDOMAIN` amplification for intra-cluster traffic by pairing `ndots: "2"` with explicit 4-dot `<svc>.<ns>.svc.cluster.local` FQDNs and matching mTLS leaf certificate SANs.
  - Size host (`init_net`) `net.core.rmem_default` (`>= 8 MiB`) and `net.core.rmem_max` (`>= 16 MiB`) on cluster nodes so CoreDNS UDP `:53` sockets do not drop bursts in `RcvbufErrors`, with measurable pre/post verification gates.
- **Non-Goals**:
  - Deploying `NodeLocal DNSCache` (`169.254.20.10`), a `force_tcp` node-local DNS proxy DaemonSet, or modifying per-node K3s kubelet `clusterDNS` flags. Eliminating `ndots:5` search amplification with 4-dot FQDNs, bounding UDP retries to `2s` with `single-request-reopen`, and sizing host `rmem_default` to `8 MiB` resolves the UDP burst drops and retry stalls without introducing a privileged node-local DNS DaemonSet or host kubelet reconfiguration.
  - Raising HTTP, gRPC, database, or Stream Load connect timeouts in Elixir, Go, or Rust callers.
  - Adding optional Helm values gates that leave default installations unprotected.
  - Modifying deprecated cold-tier templates (being removed separately).

## Decisions

### Decision 1: Fixed Pod `dnsConfig` Helper Across All Non-ColdTier Workloads
Define `serviceradar.podDnsConfig` in `helm/serviceradar/templates/_helpers.tpl` (and `helm/serviceradar-k8s-edge/templates/_helpers.tpl`) emitting:
```yaml
dnsConfig:
  options:
    - name: ndots
      value: "2"
    - name: timeout
      value: "2"
    - name: attempts
      value: "2"
    - name: single-request-reopen
```
Apply unconditionally to all 36 pod-bearing manifests in `helm/serviceradar`:
- **Deployments (19)**: `agent.yaml`, `agent-gateway.yaml`, `archive-reader.yaml`, `bmp-collector.yaml`, `core.yaml`, `datasvc.yaml`, `dev/faker.yaml`, `flow-collector.yaml`, `gobgp.yaml`, `k8s-inventory.yaml`, `log-collector.yaml`, `log-collector-tcp.yaml`, `media-storage.yaml`, `rperf-checker.yaml`, `trapd.yaml`, `trivy-sidecar.yaml`, `web.yaml`, `webrtc-turn-server.yaml`, and `files/serviceradar-tools.yaml`.
- **StatefulSets (2)**: `nats.yaml`, `nvr.yaml`.
- **Jobs (15)**: `cert-generator-job.yaml`, `cert-regenerator-job.yaml`, `checker-templates-kv-bootstrap-job.yaml`, `cnpg-client-ca-job.yaml`, `cnpg-client-ca-secret-job.yaml`, `cnpg-extension-update-job.yaml`, `core-migrations-job.yaml`, `dgraph-acl-bootstrap-job.yaml`, `dgraph-schema-job.yaml`, `flow-collector-bootstrap-job.yaml`, `nats-creds-generator.yaml`, `secret-generator-job.yaml`, `starrocks-catalog-job.yaml`, `starrocks-catalog-reader-job.yaml`, and `starrocks-storage-volume-job.yaml`.
- **Edge chart Deployment (1)**: `helm/serviceradar-k8s-edge/templates/deployment.yaml`.
- **`dgraph` subchart workloads (5)**: with default values (`dgraph.enabled: true`) the chart renders `<release>-dgraph-alpha` and `<release>-dgraph-zero` from `charts/dgraph-24.1.4.tgz` (plus optional `ratel` Deployment and `cronjob-full` / `cronjob-inc` CronJobs). Upstream templates expose no `dnsConfig` value, so vendor the pinned `dgraph` 24.1.4 subchart unpacked under `helm/serviceradar/charts/dgraph` and emit the same fixed `dnsConfig` block unconditionally across all 5 workload pod templates.

### Decision 2: Explicit 4-Dot Cluster FQDNs and Leaf Certificate SAN Parity
- Render intra-cluster service endpoints in `helm/serviceradar` (NATS, core, web-ng, datasvc, agent-gateway, collectors, Dgraph, CNPG RW/pooler, hook Job `https://kubernetes.default.svc.cluster.local` API URLs, and cross-namespace StarRocks FE endpoints such as `lab-fe-service.starrocks.svc.cluster.local`) as 4-dot `<service-name>.<namespace>.svc.cluster.local`, where `<service-name>` is the Kubernetes Service `metadata.name` (`serviceradar-core`, `serviceradar-web-ng`, `serviceradar-datasvc`, `serviceradar-agent-gateway`, ...), not the `generate-certs.sh` component id or an `ExternalName` alias. With `ndots: "2"`, any `>=2`-dot name is queried directly as an absolute FQDN first, producing zero search-suffix `NXDOMAIN` queries. Bare `<service>` (0 dots) still resolves via the first search suffix (`<namespace>.svc.cluster.local`) for manual/ad-hoc tools.
- Update `helm/serviceradar/files/generate-certs.sh` so the leaf certificate of every TLS-serving chart Service carries `DNS:<service-name>.{{ .Release.Namespace }}.svc.cluster.local` using the same Service name clients dial: add it for `serviceradar-web-ng`, `serviceradar-rperf-client`, `serviceradar-flow-collector`, `serviceradar-bmp-collector`, `serviceradar-trivy-sidecar`, and `serviceradar-k8s-inventory` (alongside `serviceradar-log-collector-tcp` / `serviceradar-otlp` on `log-collector`); `serviceradar-nats`, `serviceradar-core`, `serviceradar-datasvc`, `serviceradar-agent`, `serviceradar-agent-gateway`, `serviceradar-log-collector`, and `serviceradar-trapd` already carry it. Bump `certs.runtimeLayoutVersion` from `"5"` to `"6"` so upgrades regenerate runtime certificates with the expanded SANs. Certificates with no backing Service (`falcosidekick`, `tools`) are client identities and need no cluster-local SAN.

### Decision 3: Cluster Host (`init_net`) UDP Receive-Buffer Sizing for CoreDNS
On Linux kernels `6.8` / `6.14`, `net.core.rmem_default` and `net.core.rmem_max` are global kernel variables initialized in `init_net` (`net/core/sysctl_net_core.c`), not per-network-namespace pod `securityContext.sysctls`. Every newly created AF_INET/AF_INET6 UDP socket in any pod network namespace inherits `sock_init_data` `sk_rcvbuf` from the host's `sysctl_rmem_default` at `socket()` creation time:
1. Persist `net.core.rmem_default = 8388608` (8 MiB) and `net.core.rmem_max = 16777216` (16 MiB) on every cluster node via host `/etc/sysctl.d/`.
2. Roll the `kube-system` CoreDNS Deployment so its pods open fresh `:53/UDP` sockets sized to the 8 MiB host default rather than the 208 KiB (`212992` byte) boot default.
3. Verify both `/proc/sys/net/core/rmem_default` (`>= 8388608`) on each node and `Udp: RcvbufErrors` inside each CoreDNS pod's `/proc/1/net/snmp` (since host `node_netstat_Udp_RcvbufErrors` does not observe pod network namespaces).

### Decision 4: Baseline vs Expected Target Bounds

| Dimension | Pre-Change Baseline Mechanism | Expected Post-Change Bound |
| :--- | :--- | :--- |
| Pod `/etc/resolv.conf` | `options ndots:5` (default 5s timeout, 2 attempts, shared A/AAAA UDP socket) | `options ndots:2 timeout:2 attempts:2 single-request-reopen` on 100% of chart pods |
| First-loss recovery latency | `5,000 ms` before retry 1 (exceeds 5,000 ms client connect timeout) | `2,000 ms` before retry 1 on a fresh socket (completes retry inside 5,000 ms client connect timeout) |
| Intra-cluster FQDN search queries | Up to 4 `NXDOMAIN` search walks per `A`+`AAAA` pair on `<5`-dot names (~25-30% of CoreDNS responses `NXDOMAIN`) | `0` search-suffix `NXDOMAIN` queries for 4-dot `<svc>.<ns>.svc.cluster.local` endpoints (<5% residual cluster `NXDOMAIN` share) |
| CoreDNS UDP socket buffer & `RcvbufErrors` | Host `rmem_default = 212992` (208 KiB); non-zero CoreDNS pod-netns `Udp: RcvbufErrors` under lookup bursts | Host `rmem_default >= 8388608` (8 MiB) + rolled CoreDNS pods; `0` new CoreDNS pod-netns `Udp: RcvbufErrors` |
| Transient `:nxdomain` / `:connect_timeout` on healthy in-cluster services | Recurring first-attempt HTTP/TCP connect timeouts and occasional `:nxdomain` on 2-dot `<svc>.<ns>.svc` names | `0` `:nxdomain` errors and `0` DNS-induced first-attempt connect timeouts against healthy in-cluster services over a 24h soak |
