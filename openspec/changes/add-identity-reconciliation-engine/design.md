## Context
IP churn created duplicate devices because weak identifiers were promoted as durable records. We need a cross-service Identification & Reconciliation Engine (IRE) that ingests sightings, correlates identifiers, and promotes/merges devices per policy with auditability and safe rollout.

## Goals / Non-Goals
- Goals: formalize network sighting lifecycle; introduce identifier/fingerprint indexing; policy-driven promotion/merge; subnet-aware TTLs; observability/audit; feature-gated rollout with shadow evaluation.
- Non-Goals: automatic subnet classification (manual config first); new external discovery sources beyond existing sweep/agents/sync; SIEM/third-party export; destructive cleanup of legacy data without audit.

## Decisions
- Data model: add `network_sightings`, `device_identifiers`, `fingerprints`, `subnet_policies`, `sighting_events`, `merge_audit` with indexes for IP/subnet/status, identifier uniqueness, and fingerprint lookups.
- Confidence tiers: Tier 3 (sightings) held with TTL; Tier 2 promotions require policy match (persistence/fingerprint/hostname/subnet rules); Tier 1 anchored by strong IDs (MAC, serial, agent, cloud/ext IDs) absorbs merges.
- Ingestion responsibility: sweep/poller/agents/sync emit sightings + identifiers; registry owns reconciliation (caches, scoring, promotion/merge, audit); reaper enforces TTL by subnet profile.
- Feature gating/rollout: helm/flag toggles for sightings-only ingestion, fingerprinting, promotion automation; start shadow-mode promotion with logging; enable partial unique constraints after stability.

## Risks / Trade-offs
- Over-promotion/false merges → mitigate with multi-signal scoring, shadow mode, manual promotion UI, reversible soft-merge markers.
- Under-promotion/stale sightings → metrics/alerts on aged sightings; operator overrides; policy tuning.
- Performance on churny subnets → batch reconciliation with indexes and caches; rate limits; background workers.
- Operational complexity → centralize policy defaults, docs/runbooks, and dashboards; prefer simple JSON rules per subnet.

## Migration Plan
1) Add schema + indexes; seed default subnet policies. 2) Ship ingestion split with flag (sightings store) while keeping legacy path toggleable. 3) Enable reaper v2 for sightings only. 4) Run promotion/merge in shadow mode with metrics/audit. 5) Backfill identifiers/fingerprints and merge existing duplicates with audit trail. 6) Enable automated promotion per subnet class; then tighten partial unique constraints. 7) Remove legacy IP-as-ID paths except where policy allows.

## Open Questions
- Default TTLs per class (guest/dynamic/static) for first rollout? 
- Do we require hostname + fingerprint for auto-promotion in dynamic subnets or allow persistence-only?
- How to surface operator overrides in API contracts (PATCH sighting vs dedicated promotion endpoint)?
