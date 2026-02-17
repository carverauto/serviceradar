---
title: Topology Reset and Rebuild Runbook
---

# Topology Reset and Rebuild Runbook

Use this runbook when topology is polluted (hairball edges, stale islands, missing uplinks after fixes) and you need a deterministic reset + rebuild cycle.

This workflow is operator-safe:
- Read-only by default
- Destructive cleanup requires explicit confirmation flags
- Post-rebuild gate checks fail fast with non-zero exit code

## Script

Use:

```bash
./scripts/topology-reset-rebuild.sh
```

Modes:
- `status`: pre/post snapshot metrics (read-only)
- `cleanup`: clears mapper topology evidence + derived AGE mapper edges
- `gates`: validates rebuilt topology against threshold gates

## 1. Pre-check (read-only)

Collect baseline metrics:

```bash
./scripts/topology-reset-rebuild.sh --mode status --lookback-minutes 60
```

Returns:
- `raw_links`
- `unique_pairs`
- `final_direct`
- `final_inferred`
- `final_attachment`
- `final_edges`
- `unresolved_endpoints`

## 2. Cleanup (destructive, explicit)

This removes:
- `platform.mapper_topology_links` evidence rows
- AGE edges with `r.ingestor='mapper_topology_v1'` and relation in `CONNECTS_TO|INFERRED_TO|ATTACHED_TO`

Run only with explicit confirmation:

```bash
./scripts/topology-reset-rebuild.sh --mode cleanup --apply --yes
```

Without `--apply --yes`, cleanup is refused.

## 3. Deterministic Rebuild

After cleanup:
1. Ensure updated mapper/ingestor/web deployments are running.
1. Trigger mapper discovery jobs (the intended jobs/agents only).
1. Wait for mapper results to stream and ingestion to complete.
1. Verify recent topology evidence exists with `--mode status`.

Recommended quick check:

```bash
./scripts/topology-reset-rebuild.sh --mode status --lookback-minutes 30
```

## 4. Post-rebuild Gates (failure guardrails)

Run gate checks:

```bash
./scripts/topology-reset-rebuild.sh \
  --mode gates \
  --lookback-minutes 30 \
  --min-raw-links 20 \
  --min-direct-edges 2 \
  --max-inferred-ratio 0.95 \
  --max-unresolved-endpoints 200 \
  --max-edge-churn-ratio 0.40
```

Gate behavior:
- exits `0` on pass
- exits non-zero on any threshold failure

Evaluated gates:
- `raw_links >= min_raw_links`
- `final_direct >= min_direct_edges`
- `inferred_ratio <= max_inferred_ratio`
  - where `inferred_ratio = final_inferred / (final_direct + final_inferred)`
- `unresolved_endpoints <= max_unresolved_endpoints`
- `edge_churn_ratio <= max_edge_churn_ratio`
  - where `edge_churn_ratio` is unique-pair symmetric-diff ratio between the current and previous lookback windows

## 5. Notes

- This runbook intentionally resets mapper-derived topology only.
- It does not delete device inventory (`platform.ocsf_devices`) or non-topology datasets.
- For a per-run operator report (devices by source, observations by type, projection accept/reject reasons, unresolved IDs), run:

```bash
cd elixir/serviceradar_core
mix serviceradar.topology_report --lookback-minutes 30
```
- If identity drift remains after rebuild, run:

```bash
cd elixir/serviceradar_core
mix serviceradar.mapper_topology_cleanup
```

Then rerun discovery and gate checks.

## 6. Rollback switches

If rollout quality degrades, use these env toggles for immediate rollback:

- Core v2 contract consumption off:
  - `SERVICERADAR_TOPOLOGY_V2_CONSUMPTION_ENABLED=false`
- Web AGE-authoritative render cutover off (legacy mapper-topology-links source):
  - `SERVICERADAR_AGE_AUTHORITATIVE_TOPOLOGY_ENABLED=false`

Recovery sequence:
1. Set rollback env vars in Helm values/manifests.
1. Redeploy/restart `core-elx` and `web-ng`.
1. Re-run discovery jobs.
1. Re-check with:
   - `./scripts/topology-reset-rebuild.sh --mode status --lookback-minutes 30`
   - `./scripts/topology-reset-rebuild.sh --mode gates --lookback-minutes 30 ...`
1. Once stable, re-enable one flag at a time and monitor gate metrics.
