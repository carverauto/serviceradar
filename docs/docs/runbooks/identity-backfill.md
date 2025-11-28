# Identity Reconciliation Backfill & Subnet Policy Seeding

Use this runbook to seed subnet policies for the Identity Reconciliation Engine (IRE), run a one-time backfill to reconcile legacy duplicates, and outline rollback steps. Commands assume CNPG is reachable via `CNPG_DSN` (e.g., `postgres://user:pass@host:5432/serviceradar?sslmode=disable`).

## Prerequisites
- CNPG migrations applied (run `cmd/tools/cnpg-migrate`).
- Core identity reconciliation enabled (`core.identity.enabled=true`) with promotion/reaper settings set via Helm/KV.
- Capture a fresh backup/snapshot of CNPG before making changes.

## 1) Seed Subnet Policies
Seed default subnet policies so sightings have promotion/reaper rules. Adjust CIDRs to your environment; the defaults align with Helm values (dynamic TTL 6h, guest TTL 1h, static TTL 72h, default TTL 24h, minPersistence 24h).

```bash
export CNPG_DSN="postgres://user:pass@host:5432/serviceradar?sslmode=disable"
export DYNAMIC_CIDR=${DYNAMIC_CIDR:-"10.0.0.0/12"}
export GUEST_CIDR=${GUEST_CIDR:-"10.20.0.0/16"}
export STATIC_CIDR=${STATIC_CIDR:-"10.99.0.0/16"}

psql "$CNPG_DSN" <<SQL
INSERT INTO subnet_policies (cidr, classification, promotion_rules, reaper_profile, allow_ip_as_id)
VALUES
  ('${DYNAMIC_CIDR}', 'dynamic', '{"min_persistence":"24h","require_hostname":false,"require_fingerprint":false}'::jsonb, 'dynamic', false),
  ('${GUEST_CIDR}', 'guest',   '{"min_persistence":"24h","require_hostname":true,"require_fingerprint":false}'::jsonb, 'guest',   false),
  ('${STATIC_CIDR}', 'static',  '{"min_persistence":"24h","require_hostname":false,"require_fingerprint":false}'::jsonb, 'static',  true)
ON CONFLICT (cidr) DO UPDATE
SET classification  = EXCLUDED.classification,
    promotion_rules = EXCLUDED.promotion_rules,
    reaper_profile  = EXCLUDED.reaper_profile,
    allow_ip_as_id  = EXCLUDED.allow_ip_as_id,
    updated_at      = now();

-- Baseline catch-all for anything not matched above (defaults to dynamic rules)
INSERT INTO subnet_policies (cidr, classification, promotion_rules, reaper_profile, allow_ip_as_id)
VALUES ('0.0.0.0/0', 'dynamic', '{"min_persistence":"24h","require_hostname":false,"require_fingerprint":false}'::jsonb, 'default', false)
ON CONFLICT (cidr) DO UPDATE
SET classification  = EXCLUDED.classification,
    promotion_rules = EXCLUDED.promotion_rules,
    reaper_profile  = EXCLUDED.reaper_profile,
    allow_ip_as_id  = EXCLUDED.allow_ip_as_id,
    updated_at      = now();
SQL
```

Verify:
```bash
psql "$CNPG_DSN" -c "SELECT cidr, classification, reaper_profile, promotion_rules FROM subnet_policies ORDER BY cidr;"
```

### Scripted seeding/backfill
You can run the helper script instead of manual psql. By default it seeds policies and dry-runs the backfill:

```bash
CNPG_DSN="postgres://user:pass@host:5432/serviceradar?sslmode=disable" \
RUN_BACKFILL=true \
DRY_RUN=true \
CORE_BIN=serviceradar-core \
CORE_CONFIG=/etc/serviceradar/core.json \
scripts/identity-backfill.sh
```

Set `DRY_RUN=false` to apply merges, `BACKFILL_IPS=false` to skip alias reconciliation, and override CIDRs via `DYNAMIC_CIDR/GUEST_CIDR/STATIC_CIDR`.

## 2) Run Identity Backfill (dry-run then apply)
Use the core binary to reconcile legacy duplicates and IP aliases. Start with dry-run; the job emits metrics/logs and uses the existing merge logic.

```bash
# Dry-run: observe actions only
serviceradar-core --config /etc/serviceradar/core.json --backfill-identities --backfill-dry-run

# Apply with KV seeding + tombstones (includes IP alias backfill by default)
serviceradar-core --config /etc/serviceradar/core.json --backfill-identities

# Skip IP alias stage if not needed
serviceradar-core --config /etc/serviceradar/core.json --backfill-identities --backfill-ips=false
```

Post-run checks:
- `merge_audit` rows present for recent merges: `SELECT count(*) FROM merge_audit WHERE created_at > now() - interval '1 hour';`
- No active sightings for promoted items: `SELECT count(*) FROM network_sightings WHERE status='active';`
- Cardinality within baseline/tolerance: confirm `identity_cardinality_*` gauges or query `unified_devices` count if available.

## 3) Rollback/Recovery
- If backfill results are unsatisfactory, restore CNPG from the snapshot taken in prerequisites.
- To undo only subnet policy seeding, delete the inserted rows: `DELETE FROM subnet_policies WHERE cidr IN ('${DYNAMIC_CIDR}','${GUEST_CIDR}','${STATIC_CIDR}','0.0.0.0/0');`
- To clear backfill audits (while keeping data), remove recent merge audit rows: `DELETE FROM merge_audit WHERE created_at > now() - interval '1 hour';`
- Re-run with `--backfill-dry-run` after adjustments before reapplying.

## 4) Demo Validation Loop
1. Truncate identity tables if performing a full reseed: `TRUNCATE network_sightings, sighting_events, merge_audit;`
2. Replay ingestion (faker/sync/poller) until ~50k sightings land.
3. Run reconciliation once promotions are eligible; verify device count hovers at 50k (+internal) and that newly promoted devices remain unavailable until probed.
4. Monitor identity metrics/alerts added in `identity-alerts.md` and `identity-metrics.md`.
