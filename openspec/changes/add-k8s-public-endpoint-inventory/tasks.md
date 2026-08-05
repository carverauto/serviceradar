## 1. Spec and contracts

- [ ] 1.1 Finalize event schema (protobuf or JSON) for public endpoint inventory snapshots/deltas (cluster_id, ip, hostname, port, protocol, exposure_class, service/gateway/route refs, backend targets, annotations subset, observed_at, deleted)
- [ ] 1.2 Document NATS subject family and SPIFFE publisher identity for `serviceradar-k8s-inventory`
- [ ] 1.3 Document support tiers (tested / supported-untested / experimental) in design-aligned docs draft

## 2. Go collector (`serviceradar-k8s-inventory`)

- [ ] 2.1 Scaffold `go/cmd/k8s-inventory` + `go/pkg/k8sinventory` with config (cluster_id, namespaces, feature flags, NATS/mTLS)
- [ ] 2.2 Implement Service informer: LoadBalancer ingress IP/hostname, ExternalIPs, ports, ETP, MetalLB/ExternalDNS annotations
- [ ] 2.3 Implement EndpointSlice informer join for backend targets (`targetRef`, ports)
- [ ] 2.4 Implement Gateway API informers (Gateway + HTTPRoute/TCPRoute/UDPRoute/GRPCRoute/TLSRoute as available)
- [ ] 2.5 Optional EnvoyProxy CR informer (flag); skip cleanly if CRD absent
- [ ] 2.6 Normalize to inventory events; full resync + watch; tombestones/soft-delete generations
- [ ] 2.7 Publish to NATS with existing collector security patterns; metrics (watch lag, object counts, publish errors, CRD missing)
- [ ] 2.8 Unit tests with fake clientsets for Service/EndpointSlice/Gateway fixtures (including hostname-only LB ingress)
- [ ] 2.9 Bazel/build packaging for container image `serviceradar-k8s-inventory`

## 3. Helm (optional component)

- [ ] 3.1 Add `k8sInventory` block to `helm/serviceradar/values.yaml` (`enabled: false` by default)
- [ ] 3.2 Templates: Deployment, ServiceAccount, ClusterRole/ClusterRoleBinding (or Role when namespaced), ConfigMap, optional NetworkPolicy
- [ ] 3.3 Wire image tag under `image.tags.k8sInventory` / chart appVersion pattern
- [ ] 3.4 SPIRE/mTLS service account hooks consistent with flow-collector / trapd
- [ ] 3.5 Graceful values when Gateway API or EnvoyProxy CRDs disabled
- [ ] 3.6 Enable in `helm/serviceradar/values-demo.yaml` with `clusterId: demo` and EnvoyProxy CRD on
- [ ] 3.7 Helm unit/template tests for enabled/disabled and RBAC resource list

## 4. Core ingest and storage

- [ ] 4.1 Platform migration: `platform.public_endpoints_current` (upsert key, indexes on ip/hostname/port/cluster_id)
- [ ] 4.2 EventWriter or dedicated processor: consume inventory subject → upsert/soft-delete
- [ ] 4.3 Fail-open if publisher absent; health/status for last successful resync per cluster_id
- [ ] 4.4 Tests for upsert, tombstone, dual IP+hostname rows

## 5. SRQL and IR UX

- [ ] 5.1 SRQL entity `in:public_endpoints` with filters: ip, hostname, port, protocol, namespace, cluster_id, exposure_class
- [ ] 5.2 Catalog entry for web-ng SRQL autocomplete
- [ ] 5.3 (P1) Optional join/enrichment documentation or read-path helper for flows → owner fields
- [ ] 5.4 Docs: IR runbook "investigate inbound to public VIP" using SRQL only

## 6. Security and validation

- [ ] 6.1 Review RBAC: confirm no secrets/pods/exec/nodes access in rendered manifests
- [ ] 6.2 Document and test: host agent paths unchanged (no new ClusterRole for node agents)
- [ ] 6.3 Demo validation checklist: resolve `23.138.124.7` → forgejo-gateway + ports 22/443; TCPRoute ssh backend
- [ ] 6.4 Document untested/experimental matrix (EKS/GKE/AKS/Tanzu hostname LBs; non-IPVS kube-proxy)

## 7. Explicitly deferred (track, do not block P0)

- [ ] 7.1 DNAT-aware process correlation using VIP→backend maps (experimental; separate issue if large)
- [ ] 7.2 Multi-replica leader election
- [ ] 7.3 Ingress resource informer
- [ ] 7.4 GitOps pin drift detection
- [ ] 7.5 Managed-cloud E2E test matrix
