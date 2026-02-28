## 1. CNPG Schema & Storage
- [ ] 1.1 Add migrations (platform schema) for persisted flow enrichment fields required by flow details.
- [ ] 1.2 Add storage for cloud-provider CIDR dataset snapshots and active version metadata.
- [ ] 1.3 Add storage for IEEE OUI dataset snapshots and active version metadata in CNPG.
- [ ] 1.4 Add indexes/constraints needed for provider CIDR and OUI lookup plus enriched field query performance.

## 2. Ingestion-Time Enrichment
- [ ] 2.1 Implement protocol number -> canonical protocol label mapping at ingestion.
- [ ] 2.2 Implement TCP flag bitmask decoding and persist decoded labels alongside raw bitmask.
- [ ] 2.3 Implement destination port service-label enrichment with source/confidence metadata.
- [ ] 2.4 Implement directionality classification from directional byte counters.
- [ ] 2.5 Implement provider-hosting classification by CIDR match against refreshed cloud-provider dataset.
- [ ] 2.6 Implement source/destination MAC vendor enrichment by OUI match against refreshed IEEE OUI dataset.

## 3. Scheduled Dataset Refresh (#2799 + OUI)
- [ ] 3.1 Add AshOban daily job to fetch rezmoss cloud-provider IP dataset.
- [ ] 3.2 Validate and normalize fetched dataset, then atomically promote to active snapshot.
- [ ] 3.3 Preserve last-known-good snapshot on fetch/validation failure and emit job telemetry/logs.
- [ ] 3.4 Add AshOban weekly job to fetch IEEE `oui.txt` dataset.
- [ ] 3.5 Validate/normalize OUI prefixes and atomically promote the active OUI snapshot.
- [ ] 3.6 Preserve last-known-good OUI snapshot on fetch/validation failure and emit job telemetry/logs.

## 4. Demo Network Policy / Helm Egress
- [ ] 4.1 Update `helm/serviceradar/values-demo.yaml` `networkPolicy.egress.allowedCIDRs` to permit egress for both dataset sources (`standards-oui.ieee.org` and rezmoss/GitHub raw endpoint path).
- [ ] 4.2 Add/update comments in demo values documenting resolution date and endpoint-to-CIDR rationale.
- [ ] 4.3 Verify rendered network policies include the new CIDR allows when templated with demo values.

## 5. Query/API/UI Consumption
- [ ] 5.1 Update SRQL/API flow projections to return persisted enriched fields.
- [ ] 5.2 Update `/flows` and device-flow drill-ins in web-ng to render persisted enrichment fields without recomputing mappings.
- [ ] 5.3 Add regression tests confirming both entry points render identical enriched values (including MAC vendor labels) for the same flow.

## 6. Validation
- [ ] 6.1 Add ingestion-path tests for protocol/tcp/service/direction/provider/OUI enrichment.
- [ ] 6.2 Add job tests for provider and OUI dataset refresh success/failure/last-known-good behavior.
- [ ] 6.3 Run `openspec validate add-flow-detail-normalization-and-enrichment --strict`.
