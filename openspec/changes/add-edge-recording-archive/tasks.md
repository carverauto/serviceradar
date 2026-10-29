## 1. Implementation

- [ ] 1.1 Bind recorder/archiver to a qualified exclusive filesystem lifetime and durable journal; capture cannot require central CNPG, a remote quorum or JetStream media staging.
- [ ] 1.2 Provision finite offline policy/credential windows and fenced assignment identity before disconnect. Keep state in a long-lived host worker rather than stateless per-check Wasm; restart cannot renew expired grants.
- [ ] 1.3 Seal bounded segments and initialization dependencies; reconcile crashes between completion and durable journaling and clean up partial work safely.
- [ ] 1.4 In S3-backed mode, upload each completed segment promptly when S3 is reachable, independently of hub connectivity. Bound concurrency/bandwidth and persist retry/multipart state.
- [ ] 1.5 Verify media, initialization objects and immutable recovery manifests; persist a receipt before reclaiming local media. Retry central index delivery separately and recover it from manifests after edge loss.
- [ ] 1.6 Keep NATS reconnect/PubAck separate from archive proof and remove media stream sourcing/mirroring as an implementation option.
- [ ] 1.7 Require byte/age/segment/in-flight limits, qualified placement and failure headroom, telemetry/control reservations and drain-before-disable behavior; pressure stops new capture rather than deleting unarchived data.
- [ ] 1.8 Implement the scalable proposal's local-only publication/retention path without S3 or SaaS requirements.

## 2. Acceptance

- [ ] Multi-hour invented capture survives offline operation and recorder/archiver restart; exact segment/digest inventories reconcile.
- [ ] With S3 reachable and hub unavailable, uploads continue and verified local bytes are reclaimed; later duplicate receipts do not duplicate the central index.
- [ ] Edge loss after reclamation permits index recovery from archived manifests.
- [ ] Full disk, partial records/uploads, slow/broken uplink and policy/credential expiry produce explicit gaps/admission decisions without evicting telemetry or claiming unlimited retention.
- [ ] Dashboard/status reports captured/provisional-local/retained-local/uploading/archived-but-not-indexed/available/gap states, backlog age/bytes, goodput, drain ETA and time-to-full.
- [ ] Sizing/runbook covers outage plus catch-up: archival goodput must exceed ongoing ingest to drain backlog, with replication/I/O/failure headroom included.
- [ ] Local-only recording, playback, holds and recovery work with no S3 or SaaS connectivity; expiry/reboot/clock rollback do not restore stale offline authority.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
