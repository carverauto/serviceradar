## 1. Implementation
- [ ] 1.1 Inventory the NetFlow rule bundle (path `rust/netflow-collector/data/flows/netflow_to_ocsf.json`, key `netflow_to_ocsf`, subject `flows.raw.netflow`, output `flows.raw.netflow.processed`) and document in the change.
- [ ] 1.2 Package the NetFlow rule bundle with NetFlow collector artifacts (rpm/deb/docker/helm assets).
- [ ] 1.3 Add a Helm bootstrap step (job/init container) that runs `zen-put-rule` with retry/backoff when NetFlow collector is enabled.
- [ ] 1.4 Add a k8s manifest bootstrap step for NetFlow rule seeding in the demo/prod manifests.
- [ ] 1.5 Add a Docker Compose bootstrap step for NetFlow rule seeding (with retry/backoff) when the NetFlow collector is enabled.
- [ ] 1.6 Add a verification step (serviceradar-tools + `nats` CLI) to confirm KV contains the NetFlow rule bundle.
- [ ] 1.7 Update docs/runbook notes if required.
