## Context
Issue `#6518` investigated transient `:connect_timeout` and `:nxdomain` connect failures against healthy in-cluster services (including StarRocks FE Stream Load HTTP endpoints and internal gRPC/NATS/CNPG peers). Client connect budgets are intentionally 5 seconds (`5_000 ms`); raising per-caller timeouts would mask stalls and hold worker pools longer rather than fixing name resolution.

Inspection of the resolver path established three compounding mechanisms:
1. **Unbounded `ndots:5` search-path amplification and 5-second glibc retry stall**: Every chart pod currently renders with no `dnsConfig`, inheriting `options ndots:5` with glibc defaults (`timeout:5`, `attempts:2`, parallel `A`+`AAAA` over one ephemeral UDP port). Any `<5`-dot target (0-dot `<svc>` or 2-dot `<svc>.<ns>.svc`) walks search suffixes before trying the absolute name, and a single dropped UDP packet stalls resolution for 5,000 ms -- exhausting 5,000 ms caller connect budgets on the first attempt.
2. **Pod-namespace CoreDNS UDP receive-buffer drops masked on host metrics**: Host-level `node_netstat_Udp_RcvbufErrors` reads the root network namespace (`0`), whereas CoreDNS pods run in isolated pod network namespaces where `/proc/<pid>/net/snmp` `Udp: RcvbufErrors` accounts for 100% of `Udp: InErrors` during concurrent dual-stack lookup bursts.
3. **IPVS `:53/UDP` conntrack window (`nf_conntrack_udp_timeout = 30s`)**: When pods send all DNS over UDP to the `kube-dns` ClusterIP under `kube-proxy` IPVS round-robin masquerade without `NodeLocal DNSCache`, every UDP socket creates or reuses IPVS/conntrack state subject to the 30-second unassured UDP timeout (`nf_conntrack_udp_timeout = 30s` vs `120s` stream) and parallel `A`/`AAAA` reply races on the same 5-tuple.

## Goals / Non-Goals
- **Goals**:
  - Bound single-packet DNS loss recovery inside existing 5-second client connect budgets (`timeout: "2"`, `attempts: "2"`, `single-request-reopen`) by default on every install without a Helm-only switch.
  - Eliminate search-domain `NXDOMAIN` amplification for intra-cluster traffic by pairing `ndots: "2"` with explicit 4-dot `<svc>.<ns>.svc.cluster.local` FQDNs and matching mTLS leaf certificate SANs.
  - Specify the companion `gitops` cluster resolver architecture (`NodeLocal DNSCache` over TCP upstream + CoreDNS UDP buffer sizing) and measurable pre/post verification gates.
- **Non-Goals**:
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

### Decision 2: Explicit 4-Dot Cluster FQDNs and Leaf Certificate SAN Parity
- Render intra-cluster service endpoints in `helm/serviceradar` (NATS, core, web-ng, datasvc, agent-gateway, collectors, Dgraph, CNPG RW/pooler, and cross-namespace StarRocks FE endpoints such as `fe-service.<starrocks-ns>.svc.cluster.local`) as 4-dot `<service>.<namespace>.svc.cluster.local`. With `ndots: "2"`, any `>=2`-dot name is queried directly as an absolute FQDN first, producing zero search-suffix `NXDOMAIN` queries. Bare `<service>` (0 dots) still resolves via the first search suffix (`<namespace>.svc.cluster.local`) for manual/ad-hoc tools.
- Update `helm/serviceradar/files/generate-certs.sh` so every internal TLS server/component certificate (`web`, `rperf-client`, `flow-collector`, `bmp-collector`, `falcosidekick`, `trivy-sidecar`, `k8s-inventory`, and `tools`, in addition to `nats`, `core`, `kv`, `agent`, `gateway`, `log-collector`, and `trapd`) carries `DNS:<service>.{{ .Release.Namespace }}.svc.cluster.local`.

### Decision 3: Companion `gitops` Cluster Resolver Hardening (`NodeLocal DNSCache` + CoreDNS)
In the cluster `gitops` repository:
1. Deploy **`NodeLocal DNSCache`** as a node-local DaemonSet listening on a link-local IP (`169.254.20.10` /pillar local-dns pattern) with `force_tcp` on `cluster.local` and `.` upstream forwarders to `kube-dns`:
   - Pod UDP queries stay node-local over loopback/link-local with sub-millisecond cache hits and never traverse `kube-proxy` IPVS `:53/UDP` virtual services or 30-second UDP conntrack entries.
   - Cache misses use persistent TCP `:53` connections from `NodeLocal DNSCache` to CoreDNS, eliminating UDP receive-buffer drops and conntrack races.
2. Configure **CoreDNS** with `bufsize 1232`, `ready`/`health` probes, anti-affinity across worker nodes, and host sysctl / node kernel `net.core.rmem_max >= 8388608` so any direct UDP `:53` traffic cannot overflow a default 208 KiB socket buffer.
3. Add Prometheus alert coverage on CoreDNS pod-netns UDP drops / `SERVFAIL` rate and `NodeLocal DNSCache` upstream errors rather than relying on host-namespace `node_netstat_Udp_RcvbufErrors`.

### Decision 4: Baseline vs Expected Target Bounds

| Dimension | Pre-Change Baseline Mechanism | Expected Post-Change Bound |
| :--- | :--- | :--- |
| Pod `/etc/resolv.conf` | `options ndots:5` (default 5s timeout, 2 attempts, shared A/AAAA UDP socket) | `options ndots:2 timeout:2 attempts:2 single-request-reopen` on 100% of chart pods |
| First-loss recovery latency | `5,000 ms` before retry 1 (exceeds 5,000 ms client connect timeout) | `2,000 ms` before retry 1 (completes retry inside 5,000 ms client connect timeout) |
| Intra-cluster FQDN search queries | Up to 4 `NXDOMAIN` search walks per `A`+`AAAA` pair on `<5`-dot names (~25-30% of CoreDNS responses `NXDOMAIN`) | `0` search-suffix `NXDOMAIN` queries for 4-dot `<svc>.<ns>.svc.cluster.local` endpoints (<5% residual cluster `NXDOMAIN` share) |
| IPVS `:53/UDP` & CoreDNS `RcvbufErrors` | 100% of pod DNS over IPVS `:53/UDP` (`nf_conntrack_udp_timeout=30s`); non-zero CoreDNS pod-netns `Udp: RcvbufErrors` | Cache hits served locally on node; cache misses forwarded over TCP `:53`; `0` new CoreDNS pod-netns `Udp: RcvbufErrors` |
| Transient `:nxdomain` / `:connect_timeout` on healthy in-cluster services | Recurring first-attempt HTTP/TCP connect timeouts and occasional `:nxdomain` on 2-dot `<svc>.<ns>.svc` names | `0` `:nxdomain` errors and `0` DNS-induced first-attempt connect timeouts against healthy in-cluster services over a 24h soak |
