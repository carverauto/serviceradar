## 1. Implementation

- [ ] 1.1 Bind recorder/archiver to a persistent local JetStream domain/account/bucket. Capture cannot require central CNPG or a remote Raft quorum.
- [ ] 1.2 Provision finite offline policy/credential windows and fenced assignment identity before disconnect. Keep upload state in a long-lived host worker rather than stateless per-check Wasm.
- [ ] 1.3 Finalize bounded objects and maintain a durable pending-work journal; reconcile a crash between object completion and journaling.
- [ ] 1.4 Upload each completed segment immediately whenever S3 is reachable, independently of leaf/hub connectivity. Bound concurrency/bandwidth and persist retry/multipart state.
- [ ] 1.5 Verify media, initialization objects and immutable recovery manifests; persist a receipt before reclaiming local media. Central index delivery retries separately. Manifests must recover the index after edge loss.
- [ ] 1.6 A NATS leaf reconnect or PubAck is not archival proof, and does not automatically mirror Object Store contents. Any stream sourcing/mirroring is explicitly configured and tested.
- [ ] 1.7 Require TTL/byte/object limits, replicas/placement, reserved telemetry/control capacity, safe upload deadlines and drain-before-disable behavior.

## 2. Acceptance

- [ ] Multi-hour invented capture survives offline operation and recorder/archiver restart; exact segment/digest inventories reconcile.
- [ ] With S3 reachable and hub unavailable, uploads continue and verified local bytes are reclaimed; later duplicate receipts do not duplicate the central index.
- [ ] Edge loss after reclamation permits index recovery from archived manifests.
- [ ] Full bucket, partial-object expiry, slow/broken uplink and policy/credential expiry produce explicit gaps/admission decisions without evicting telemetry or claiming unlimited retention.
- [ ] Dashboard/status reports captured/staged/uploading/archived-but-not-indexed/available/gap states, backlog age/bytes, goodput, drain ETA and time-to-full.
- [ ] Sizing/runbook covers outage plus catch-up: archival goodput must exceed ongoing ingest to drain backlog, with replication/IO/failure headroom included.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
