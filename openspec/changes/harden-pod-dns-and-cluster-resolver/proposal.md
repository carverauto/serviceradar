# Change: Harden Pod DNS Configuration and Cluster Resolver Path (#6518 Follow-Up)

## Why
Every ServiceRadar pod currently inherits Kubernetes's default `ClusterFirst` `/etc/resolv.conf` (`options ndots:5` with glibc's 5-second initial UDP retry timer and dual-stack `A`/`AAAA` lookups over one socket). Under that posture:
1. Any intra-cluster hostname with fewer than 5 dots (such as bare `<service>` or 2-dot `<service>.<namespace>.svc`) triggers search-domain walks that amplify DNS traffic with avoidable `NXDOMAIN` lookups before reaching the authoritative name, or transiently return `:nxdomain` / `SERVFAIL` when one UDP search-path exchange drops.
2. A single lost UDP DNS packet stalls glibc's stub resolver for 5,000 ms before its first retry, consuming the entire 5-second TCP/HTTP connect budget of Elixir (`Mint`/`Req`), Go (`net.Dialer`), and Rust (`reqwest`/`tonic`) clients without raising per-caller timeouts.
3. On clusters running `kube-proxy` IPVS round-robin over `:53/UDP` (`nf_conntrack_udp_timeout = 30s`, `nf_conntrack_udp_timeout_stream = 120s`) without `NodeLocal DNSCache`, UDP bursts overflow CoreDNS pod socket receive buffers (`Udp: RcvbufErrors` inside the CoreDNS pod network namespace, invisible to host-namespace `node_netstat_Udp_RcvbufErrors`) and race conntrack expiry.

## What Changes
- **Fixed chart pod `dnsConfig` defaults (no Helm-only toggle)**: Emit a shared `serviceradar.podDnsConfig` helper (`ndots: "2"`, `timeout: "2"`, `attempts: "2"`, `single-request-reopen`) unconditionally across all 36 pod-bearing manifests in `helm/serviceradar` (19 Deployments including `dev/faker` and `files/serviceradar-tools.yaml`, 2 StatefulSets, and 15 Jobs) and `helm/serviceradar-k8s-edge` (`deployment.yaml`), plus the default-enabled `dgraph` subchart StatefulSets (`<release>-dgraph-alpha`, `<release>-dgraph-zero`), whose upstream `dgraph-24.1.4` templates expose no `dnsConfig` value, by vendoring that pinned subchart unpacked under `helm/serviceradar/charts/dgraph` and emitting the same fixed block in its pod templates. Per-caller client connect timeouts remain unchanged.
- **Explicit intra-cluster FQDNs and TLS SAN parity**: Default intra-cluster Service addresses rendered by `helm/serviceradar` (and cross-namespace service references such as StarRocks FE HTTP/MySQL endpoints) to explicit 4-dot FQDNs built from the Kubernetes Service name (`<service-name>.<namespace>.svc.cluster.local`, e.g. `serviceradar-core.<namespace>.svc.cluster.local`), and extend `helm/serviceradar/files/generate-certs.sh` so the leaf certificate of every TLS-serving chart Service carries that exact name as `DNS:<service-name>.<namespace>.svc.cluster.local` (`serviceradar-web-ng`, `serviceradar-rperf-client`, `serviceradar-flow-collector`, `serviceradar-bmp-collector`, `serviceradar-trivy-sidecar`, and `serviceradar-k8s-inventory`, matching the existing `serviceradar-nats`, `serviceradar-core`, `serviceradar-datasvc`, `serviceradar-agent`, `serviceradar-agent-gateway`, `serviceradar-log-collector`, and `serviceradar-trapd` SANs).
- **Cluster-side resolver contract (`gitops` companion)**: Document and pair the chart change with cluster-level `NodeLocal DNSCache` (node-local link-local listener upgrading cache misses to TCP `:53` against CoreDNS, bypassing IPVS `:53/UDP` conntrack state) and kubelet `clusterDNS` pointed at the node-local listener so pod `resolv.conf` reaches the cache, plus CoreDNS UDP socket receive-buffer sizing (`net.core.rmem_default` / `rmem_max` applied inside the CoreDNS pod network namespace).

## Impact
- Affected specs: `cluster-dns-resilience` (added)
- Affected code (upon implementation approval):
  - `helm/serviceradar/templates/_helpers.tpl` and all 36 pod-bearing templates/files in `helm/serviceradar`
  - Vendored `dgraph` subchart (replacing `helm/serviceradar/charts/dgraph-24.1.4.tgz` with unpacked `charts/dgraph`) alpha/zero StatefulSet templates
  - `helm/serviceradar/files/generate-certs.sh`
  - `helm/serviceradar-k8s-edge/templates/_helpers.tpl` and `deployment.yaml`
  - Companion `gitops` repository manifests (`NodeLocal DNSCache` DaemonSet, kubelet `clusterDNS`, CoreDNS pod sysctls)
