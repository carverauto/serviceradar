## 1. Spec and contracts

- [ ] 1.1 Define status envelope for k8s public endpoint snapshots (service_type/source, schema version, content_hash, cluster_id, chunking rules)
- [ ] 1.2 Document exclusive publish modes: `nats` | `agent_spool` | `stdout` | `none`
- [ ] 1.3 Document cluster-agent topology (Deployment replicas=1, shared spool volume, no DaemonSet for inventory)

## 2. Collector (k8s-inventory)

- [ ] 2.1 Implement `PUBLISH_MODE=agent_spool` (atomic write of latest snapshot under configurable spool dir)
- [ ] 2.2 Content-hash skip: do not rewrite spool when snapshot unchanged
- [ ] 2.3 Metrics: spool write success/fail, last snapshot bytes, last generated_at
- [ ] 2.4 Unit tests for spool writer (atomic replace, hash skip, size budget)

## 3. Agent

- [ ] 3.1 Config section for k8s public endpoint spool path (defaults under `/var/lib/serviceradar/k8s-inventory/spool`)
- [ ] 3.2 Spool poller/watcher → StreamStatus (or PushStatus when under budget) with reserved service_type
- [ ] 3.3 Chunk large snapshots using existing StreamStatus framing
- [ ] 3.4 Ensure host-plane agent defaults do not mount inventory SA or require ClusterRole
- [ ] 3.5 Unit tests for spool → status payload assembly

## 4. Agent-gateway

- [ ] 4.1 Admit k8s public endpoint status sources (size limits, identity required)
- [ ] 4.2 Publish admitted payloads to JetStream `inventory.k8s.public_endpoints` (stream `k8s_inventory`)
- [ ] 4.3 Attach gateway-attested agent/partition/tenant metadata without dropping collector `cluster_id`
- [ ] 4.4 Tests for routing and reject paths (oversized, unauthenticated)

## 5. Core

- [ ] 5.1 Confirm EventWriter `K8sPublicEndpoints` consumes agent-path payloads unchanged
- [ ] 5.2 Optional: persist agent provenance alongside cluster_id for audit (if not already in envelope)
- [ ] 5.3 Regression: co-located NATS path still works

## 6. Packaging and install

- [x] 6.1 Helm values: `k8sInventory.publishMode`, spool volume wiring when `agent_spool` (`helm/serviceradar-k8s-edge`)
- [x] 6.2 Example values / thin chart for remote “cluster sensors only” (inventory + single agent)
- [ ] 6.3 NetworkPolicy notes: inventory → apiserver; agent → agent-gateway only (optional NetworkPolicy template)
- [x] 6.4 Image/certs: remote install uses **agent** enrollment certs (`agent.existingTlsSecret`), not platform NATS inventory certs

## 7. Docs and product narrative

- [ ] 7.1 Update `docs/docs/k8s-public-endpoint-inventory.md` remote section: agent path is the supported SaaS/multi-cluster design (not experimental NATS)
- [ ] 7.2 SaaS note: customers install sensors only; connectivity is outbound to agent-gateway
- [ ] 7.3 Clarify cluster agent vs host agent DaemonSet roles
- [ ] 7.4 Runbook: enroll cluster agent package → deploy inventory+agent → verify `in:public_endpoints cluster_id:…`

## 8. Validation

- [ ] 8.1 Lab: remote namespace with inventory+agent only, gateway on demo/SaaS, VIP row appears with correct cluster_id
- [ ] 8.2 Lab: attributed flow join still works when NetFlow+netprobe hit the same VIP from another path
- [ ] 8.3 Negative: agent without inventory spool stays healthy; inventory without agent leaves spool lag metric
