## 1. Spec and contracts

- [ ] 1.1 Finalize event schema (protobuf or JSON) for public endpoint inventory snapshots/deltas (cluster_id, ip, hostname, port, protocol, exposure_class, service/gateway/route refs, backend targets, annotations subset, observed_at, deleted)
- [ ] 1.2 Document NATS subject family and SPIFFE publisher identity for `serviceradar-k8s-inventory`
- [ ] 1.3 Document support tiers (tested / supported-untested / experimental) in design-aligned docs draft

## 2. Go collector (`serviceradar-k8s-inventory`)

### Phase A — library + provable local validation (no SR integration)

- [x] 2.1a Scaffold `go/pkg/k8sinventory` pure `BuildSnapshot` + correlation hints (no NATS/core)
- [x] 2.1b Scaffold `go/cmd/k8s-inventory snapshot` JSON dump (kubeconfig / in-cluster)
- [x] 2.2 Service ownership: LoadBalancer ingress IP/hostname, ExternalIPs, ports, ETP, MetalLB annotations
- [x] 2.3 EndpointSlice join for backend targets (`targetRef`, ports) → DNAT hints (`VIP:port → podIP:targetPort`)
- [x] 2.4 Gateway API list path (Gateway + HTTPRoute/TCPRoute/UDPRoute/GRPCRoute/TLSRoute via dynamic client)
- [x] 2.8 Unit tests (pure fixtures + fake clientset + unstructured Gateway/TCPRoute) proving Forgejo VIP associations
- [x] 2.8b Live smoke: `k8s-inventory snapshot --cluster-id demo --ip 23.138.124.7 --port 22` returns LB + Gateway ownership and envoy DNAT hint
- [x] 2.9a Bazel BUILD for package + binary (image packaging later)

### Phase B — continuous collector + publish path (no core ingest yet)

- [x] 2.1 Scaffold long-running config (cluster_id, namespaces, feature flags, NATS/mTLS, PUBLISH_MODE)
- [x] 2.6 Debounced rebuild controller + Service/EndpointSlice informers + resync ticker
- [x] 2.7 Publish modes: `nats` (JetStream), `stdout`, `none`; metrics/health HTTP; stable content hash skip
- [x] 2.7b Unit tests for controller publish/skip/debounce without apiserver NATS
- [ ] 2.5 Optional EnvoyProxy CR informer (RBAC/Helm flag ready; informer not implemented — Service status covers MetalLB pins)
- [ ] 2.9b Container image `serviceradar-k8s-inventory` for Helm (Bazel/OCI pipeline)

## 3. Helm (optional component)

- [x] 3.1 Add `k8sInventory` block to `helm/serviceradar/values.yaml` (`enabled: false` by default)
- [x] 3.2 Templates: Deployment, ServiceAccount, ClusterRole/ClusterRoleBinding, metrics Service
- [x] 3.3 Wire image tag under `image.tags.k8sInventory`
- [x] 3.4 mTLS cert generation + NATS ACL for `serviceradar-k8s-inventory` / `inventory.k8s.>`
- [x] 3.5 Gateway API RBAC gated; EnvoyProxy CRD optional
- [x] 3.6 Enable in `helm/serviceradar/values-demo.yaml` with `clusterId: demo`
- [ ] 3.7 Helm unit/template tests for enabled/disabled and RBAC resource list

## 4. Core ingest and storage

- [x] 4.1 Platform migration: `platform.public_endpoints_current` (upsert key, indexes on ip/hostname/port/cluster_id)
- [x] 4.2 EventWriter processor `K8sPublicEndpoints`: consume `inventory.k8s.>` → upsert/soft-delete
- [x] 4.2b Config stream `K8S_INVENTORY` + pipeline batcher routing
- [ ] 4.3 Fail-open if publisher absent; health/status for last successful resync per cluster_id (metrics only for now)
- [x] 4.4 Processor unit test (payload shape); soft-delete exercised on apply

## 5. SRQL and IR UX

- [x] 5.1 SRQL entity `in:public_endpoints` with filters: ip, hostname, port, protocol, namespace, cluster_id, exposure_class
- [ ] 5.2 Catalog entry for web-ng SRQL autocomplete
- [x] 5.3 (P1) Optional join/enrichment documentation or read-path helper for flows → owner fields
- [x] 5.4 Docs: IR runbook includes SRQL examples

## 6. Security and validation

- [ ] 6.1 Review RBAC: confirm no secrets/pods/exec/nodes access in rendered manifests
- [ ] 6.2 Document and test: host agent paths unchanged (no new ClusterRole for node agents)
- [ ] 6.3 Demo validation checklist: resolve `23.138.124.7` → forgejo-gateway + ports 22/443; TCPRoute ssh backend
- [ ] 6.4 Document untested/experimental matrix (EKS/GKE/AKS/Tanzu hostname LBs; non-IPVS kube-proxy)

## 7. Explicitly deferred (track, do not block P0)

- [x] 7.1 DNAT-aware process correlation using VIP→backend maps (core FlowAttribution.Correlation + SRQL owner filters + attributed-flows UI)
- [ ] 7.2 Multi-replica leader election
- [ ] 7.3 Ingress resource informer
- [ ] 7.4 GitOps pin drift detection
- [ ] 7.5 Managed-cloud E2E test matrix
