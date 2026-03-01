# Change: Normalize and Enrich Flow Details at Ingestion Time

## Why
Issue #2746 requests protocol-number and flow-detail enrichments in the NetFlow details modal. Performing this enrichment in `web-ng` per request would duplicate logic and force API/UI code to recompute mappings at runtime.

Issue #2799 adds a related gap: we do not currently refresh a cloud-provider CIDR dataset for IP enrichment, which limits item #5 from #2746 (provider/hosting context in analyst workflows).
Flow details also include MAC addresses, and we currently do not persist OUI vendor attribution from IEEE data for those endpoints.

## What Changes
- Add ingestion-time normalization/enrichment for flow records so canonical flow-detail fields are persisted in CNPG.
- Persist canonical protocol label/number, decoded TCP flag labels, destination port service label metadata, and directionality classification at write time.
- Add a daily AshOban-driven cloud-provider CIDR import (rezmoss dataset) and apply provider-classification enrichment during ingestion.
- Add a weekly AshOban-driven IEEE OUI import (`https://standards-oui.ieee.org/oui/oui.txt`) persisted in CNPG and apply MAC vendor enrichment during ingestion.
- Expose persisted enriched fields through SRQL/API so `web-ng` is display-only for these attributes.

## Impact
- Affected specs: `cnpg`, `ash-jobs`, `build-web-ui`, `kubernetes-network-policy`
- Affected code (expected):
  - Flow ingestion path and CNPG migrations in `elixir/serviceradar_core`
  - SRQL/API projection of enriched flow fields
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex` (consume persisted fields only)
  - AshOban job/resource wiring for scheduled provider CIDR + OUI dataset refresh in core
  - Helm demo environment values for egress allow-list (`helm/serviceradar/values-demo.yaml`)
  - NetFlow/device flow tests under `elixir/web-ng/test/phoenix/live/`
- Breaking changes: None (additive UI/API contract inside web-ng)
