# Change: Add Identity & Reconciliation Engine with Network Sightings

## Why
Device duplication and IP churn highlight that IP-as-identity is insufficient. We need a formal Identification & Reconciliation Engine (IRE) that treats network sightings separately from durable devices, promotes only when policies are met, and merges deterministically when strong identifiers arrive.

## What Changes
- Add network sighting lifecycle (ingest, TTL, promotion) with subnet-aware policies.
- Introduce identifier indexing (strong/middle/weak) and reconciliation engine to promote/merge devices.
- Add schema for sightings, identifiers, fingerprints, policies, audits; update sweep/agents/registry/sync paths to use it.
- Expose API/UI surfaces for sightings, promotions, policies, and merge/audit visibility.
- Ship metrics/alerts and rollout gating (feature flags, reaper profiles).

## Impact
- Affected specs: `device-identity-reconciliation`
- Affected code: registry/device identity resolver, sweep/poller ingestion, sync integrations, CNPG schema/migrations, API/UI, Helm values, metrics/alerts, background jobs/reapers.
