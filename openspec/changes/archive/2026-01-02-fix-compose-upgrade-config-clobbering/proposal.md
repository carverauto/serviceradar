# Change: Fix Docker Compose upgrade config clobbering

## Why
- Docker Compose upgrades (especially `docker compose up -d --force-recreate` or running the stack under a different project name) can result in ServiceRadar starting with missing or reset configuration state.
- When configuration state is lost or reset, core/poller/agent fall back to default bootstrap templates, which can silently disable monitoring. In the UI this shows up as device pages reporting stale/no data (e.g., “No system metrics are currently available…”).
- This is unacceptable UX: upgrading images should not overwrite or “forget” existing config.

### Observed regression (example)
- After a Compose upgrade, System Metrics pages show “Last data: 3h ago” and “No system metrics…”.
- The poller configuration stored in KV can lose user-added checks during upgrade/recreate if bootstrap/repair paths rewrite KV from on-disk defaults.
- A second (related) issue can occur when poller configuration is stored as a partial KV overlay (common for UI edits). The KV placeholder-repair logic treats missing critical fields as “placeholder”, and overwrites the KV entry from on-disk defaults during restarts/upgrades—dropping user-added checks.

## What Changes
1. **Make Compose persistence stable**
   - Explicitly name Compose volumes that contain configuration state (notably `nats-data` and `generated-config`) so running Compose from a different directory/project name cannot silently create new, empty volumes.
2. **Make Compose bootstrap non-destructive**
   - Update `docker/compose/update-config.sh` to be idempotent and safe on reruns:
     - Never write empty values over existing non-empty config fields.
     - Only set defaults when missing.
     - Avoid checker-specific “magic” in bootstrap; checkers are configured via KV/UI and templates.
   - Update KV placeholder-repair logic so missing critical fields do not trigger destructive rewrites of partial overlays during upgrades.
3. **Define an upgrade contract**
   - Document and enforce a “safe upgrade” path for Compose:
     - upgrades MUST preserve KV + config state
     - bootstrap jobs MUST NOT overwrite existing configs during upgrades
     - provide a single documented command (e.g., `make compose-upgrade`) that does not destroy volumes and makes config-updater behavior explicit.

## Impact
- Affected specs: `kv-configuration`
- Affected code:
  - `docker-compose.yml` (volume naming)
  - `docker/compose/update-config.sh` (bootstrap behavior)
  - `docs/docs/docker-setup.md` (upgrade guidance)

## Non-Goals
- Changing the system-metrics data model, retention, or UI rendering logic.
- Adding new checker types or changing checker semantics.
