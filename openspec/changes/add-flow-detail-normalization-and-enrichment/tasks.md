## 1. CNPG Schema & Storage
- [x] 1.1 Add migrations (platform schema) for persisted flow enrichment fields required by flow details.
- [x] 1.2 Add storage for cloud-provider CIDR dataset snapshots and active version metadata.
- [x] 1.3 Add storage for IEEE OUI dataset snapshots and active version metadata in CNPG.
- [x] 1.4 Add indexes/constraints needed for provider CIDR and OUI lookup plus enriched field query performance.

## 2. Ingestion-Time Enrichment
- [x] 2.1 Implement protocol number -> canonical protocol label mapping at ingestion.
- [x] 2.2 Implement TCP flag bitmask decoding and persist decoded labels alongside raw bitmask.
- [x] 2.3 Implement destination port service-label enrichment with source/confidence metadata.
- [x] 2.4 Implement directionality classification from directional byte counters.
- [x] 2.5 Implement provider-hosting classification by CIDR match against refreshed cloud-provider dataset.
- [x] 2.6 Implement source/destination MAC vendor enrichment by OUI match against refreshed IEEE OUI dataset.

## 3. Scheduled Dataset Refresh (#2799 + OUI)
- [x] 3.1 Add AshOban daily job to fetch rezmoss cloud-provider IP dataset.
- [x] 3.2 Validate and normalize fetched dataset, then atomically promote to active snapshot.
- [x] 3.3 Preserve last-known-good snapshot on fetch/validation failure and emit job telemetry/logs.
- [x] 3.4 Add AshOban weekly job to fetch IEEE `oui.txt` dataset.
- [x] 3.5 Validate/normalize OUI prefixes and atomically promote the active OUI snapshot.
- [x] 3.6 Preserve last-known-good OUI snapshot on fetch/validation failure and emit job telemetry/logs.

## 4. Demo Network Policy / Helm Egress
- [x] 4.1 Update `helm/serviceradar/values-demo.yaml` `networkPolicy.egress.allowedCIDRs` to permit egress for both dataset sources (`standards-oui.ieee.org` and rezmoss/GitHub raw endpoint path).
- [x] 4.2 Add/update comments in demo values documenting resolution date and endpoint-to-CIDR rationale.
- [x] 4.3 Verify rendered network policies include the new CIDR allows when templated with demo values.

## 5. Query/API/UI Consumption
- [x] 5.1 Update SRQL/API flow projections to return persisted enriched fields.
- [x] 5.2 Update `/flows` and device-flow drill-ins in web-ng to render persisted enrichment fields without recomputing mappings.
- [x] 5.3 Add regression tests confirming both entry points render identical enriched values (including MAC vendor labels) for the same flow.

## 6. Validation
- [x] 6.1 Add ingestion-path tests for protocol/tcp/service/direction/provider/OUI enrichment.
- [x] 6.2 Add job tests for provider and OUI dataset refresh success/failure/last-known-good behavior.
- [ ] 6.3 Run `openspec validate add-flow-detail-normalization-and-enrichment --strict`.
