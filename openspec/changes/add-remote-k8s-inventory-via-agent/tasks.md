## 1. Spec and contracts

- [x] 1.1 Define status envelope for k8s public endpoint snapshots (service_type/source, schema version, content_hash, cluster_id, chunking rules)
- [x] 1.2 Document exclusive publish modes: `nats` | `agent_spool` | `stdout` | `none`
- [x] 1.3 Document cluster-agent topology (Deployment replicas=1, shared spool volume, no DaemonSet for inventory)

## 2. Collector (k8s-inventory)

- [x] 2.1 Implement `PUBLISH_MODE=agent_spool` (atomic write of latest snapshot under configurable spool dir)
- [x] 2.2 Content-hash skip: do not rewrite spool when snapshot unchanged (controller stableSnapshotHash already skips publish)
- [x] 2.3 Metrics: spool write success/fail, last snapshot bytes, last generated_at (reuses existing publish metrics)
- [x] 2.4 Unit tests for spool writer (atomic replace, size budget, config)

## 3. Agent

- [x] 3.1 Config section for k8s public endpoint spool path (`k8s_public_endpoints` in agent.json)
- [x] 3.2 Spool reader → GetStatus / push_loop with service_type `k8s_public_endpoints`
- [x] 3.3 Size budget 4MiB (StreamStatus; full-snapshot v1, no multi-chunk yet)
- [x] 3.4 Host-plane defaults unchanged; edge chart uses inventory SA only for kube API
- [x] 3.5 Unit tests for spool → status payload assembly

## 4. Agent-gateway

- [x] 4.1 Admit k8s public endpoint status sources (size limits, identity required)
- [x] 4.2 Publish admitted payloads to JetStream `inventory.k8s.public_endpoints`
- [x] 4.3 Attach gateway-attested agent/partition/tenant headers without dropping collector cluster_id
- [x] 4.4 Tests for routing and reject paths (oversized, NATS failure)

## 5. Core

- [x] 5.1 Confirm EventWriter `K8sPublicEndpoints` consumes agent-path payloads unchanged (same JSON subject)
- [ ] 5.2 Optional: persist agent provenance alongside cluster_id for audit (headers available; follow-up)
- [x] 5.3 Regression: co-located NATS path still works (unchanged publisher mode)

## 6. Packaging and install

- [x] 6.1 Helm values: `k8sInventory.publishMode`, spool volume wiring when `agent_spool` (`helm/serviceradar-k8s-edge`)
- [x] 6.2 Example values / thin chart for remote “cluster sensors only” (inventory + single agent)
- [ ] 6.3 NetworkPolicy notes: inventory → apiserver; agent → agent-gateway only (optional NetworkPolicy template)
- [x] 6.4 Image/certs: remote install uses **agent** enrollment certs (`agent.existingTlsSecret`), not platform NATS inventory certs

## 7. Docs and product narrative

- [x] 7.1 Update `docs/docs/k8s-public-endpoint-inventory.md` remote section: agent path is the supported SaaS/multi-cluster design
- [x] 7.2 SaaS note: customers install sensors only; connectivity is outbound to agent-gateway
- [x] 7.3 Clarify cluster agent vs host agent DaemonSet roles
- [ ] 7.4 Runbook: enroll cluster agent package → deploy inventory+agent → verify `in:public_endpoints cluster_id:…` (expand after image roll)

## 8. Validation

- [ ] 8.1 Lab: remote namespace with inventory+agent only, gateway on demo/SaaS, VIP row appears with correct cluster_id
- [ ] 8.2 Lab: attributed flow join still works when NetFlow+netprobe hit the same VIP from another path
- [ ] 8.3 Negative: agent without inventory spool stays healthy; inventory without agent leaves spool lag metric
