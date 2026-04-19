## 1. Investigation and topology contract
- [x] 1.1 Document the current cluster assumptions for `core`, `web-ng`, and `agent-gateway`, including coordinator duties, PubSub/Horde dependencies, and any node-local tracker state that is not currently replica-safe.
- [x] 1.2 Define the target demo topology for `core`, `web-ng`, `agent-gateway`, and NATS, including replica counts, services, and storage expectations.
- [x] 1.3 Identify rollout blockers for multi-replica `core`, including migration ownership, singleton background work, and restart behavior.

## 2. Replicated Elixir control plane
- [x] 2.1 Add configurable replica support for `core` and `web-ng` in Helm instead of hardcoded singleton deployments.
- [x] 2.2 Ensure `core` coordinator-only responsibilities remain single-owner when multiple `core` pods are running.
- [ ] 2.3 Ensure web and gateway features that depend on live cluster state remain correct when requests land on any healthy replica.

## 3. Cluster-visible live state
- [ ] 3.1 Standardize how live gateway and agent tracker data is made authoritative across replicas instead of assuming node-local ETS is sufficient.
- [ ] 3.2 Validate that operator pages such as `/settings/cluster`, infrastructure views, and gateway/agent detail pages continue to render correct live state when pods restart or move.

## 4. NATS clustering
- [x] 4.1 Replace the single-pod NATS deployment contract with a clustered Kubernetes topology appropriate for demo.
- [ ] 4.2 Define JetStream storage and peer discovery behavior so one pod loss does not take the demo message bus offline.
- [ ] 4.3 Validate client connectivity and recovery across NATS pod restarts and rolling upgrades.

## 5. Verification
- [ ] 5.1 Exercise rolling restarts and single-pod loss for `core`, `web-ng`, `agent-gateway`, and NATS in `demo`.
- [ ] 5.2 Verify that recurring work, cluster health, live agent/gateway state, and operator workflows remain correct throughout the scaled rollout.
- [ ] 5.3 Run `openspec validate update-demo-control-plane-ha --strict`.
