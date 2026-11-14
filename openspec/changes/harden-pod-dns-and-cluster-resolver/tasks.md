## 1. Helm Chart Pod `dnsConfig` & FQDN Defaults (`serviceradar` Repo)
- [ ] 1.1 Add `serviceradar.podDnsConfig` (`ndots: "2"`, `timeout: "2"`, `attempts: "2"`, `single-request-reopen`) to `helm/serviceradar/templates/_helpers.tpl` and `helm/serviceradar-k8s-edge/templates/_helpers.tpl` with no Helm-only feature gate.
- [ ] 1.2 Include `serviceradar.podDnsConfig` in all 36 pod-bearing manifests in `helm/serviceradar` (19 Deployments including `dev/faker.yaml` and `files/serviceradar-tools.yaml`, 2 StatefulSets, and 15 Jobs) and in `helm/serviceradar-k8s-edge/templates/deployment.yaml`.
- [ ] 1.3 Expand intra-cluster service endpoint defaults in `helm/serviceradar` templates/values (including cross-namespace StarRocks FE endpoints) from bare `<svc>` / 2-dot `<svc>.<ns>.svc` to 4-dot `<svc>.<ns>.svc.cluster.local`.
- [ ] 1.4 Update `helm/serviceradar/files/generate-certs.sh` so `web`, `rperf-client`, `flow-collector`, `bmp-collector`, `falcosidekick`, `trivy-sidecar`, `k8s-inventory`, and `tools` leaf certificates include `DNS:<service>.{{ .Release.Namespace }}.svc.cluster.local` (and trigger cert regeneration when SANs change).
- [ ] 1.5 Add Bazel Helm template assertions proving every rendered Deployment, StatefulSet, and Job carries the fixed `dnsConfig`, 4-dot intra-cluster FQDNs, and matching `generate-certs.sh` SANs.

## 2. Cluster Resolver Hardening (`gitops` Repo Companion)
- [ ] 2.1 Deploy `NodeLocal DNSCache` DaemonSet with `force_tcp` upstream forwarding to CoreDNS so pod lookups stay node-local and bypass `kube-proxy` IPVS `:53/UDP` conntrack entries.
- [ ] 2.2 Configure CoreDNS `bufsize 1232`, replica anti-affinity, and node `net.core.rmem_max` sizing, plus Prometheus alert rules for CoreDNS `SERVFAIL` / pod-netns UDP drops and `NodeLocal DNSCache` upstream errors.
- [ ] 2.3 Verify post-rollout 24-hour soak metrics: `/etc/resolv.conf` carries `ndots:2 timeout:2 attempts:2 single-request-reopen`, CoreDNS `NXDOMAIN` share drops below 5%, CoreDNS pod-netns `Udp: RcvbufErrors` increments equal 0, and healthy in-cluster endpoints log 0 `:nxdomain` / DNS-stalled connect timeouts.
