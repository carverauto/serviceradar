# Change: Fix DIRE to resolve devices using detected IP aliases

## Why

GitHub Issue: #2577

Sweep results create duplicate device records when an IP alias exists in `detected` state but hasn't reached the confirmation threshold. The current alias lookup in `DeviceLookup.batch_lookup_by_ip/2` and `IdentityReconciler.lookup_alias_device_id/3` only matches aliases with `state in [:confirmed, :updated]`, ignoring `detected` aliases entirely.

**Concrete example from live system:**
- Device `sr:7588d12c-e8da-4b9e-a21d-8cc5c7faef38` (tonka01) has interface with IP `216.17.46.98`
- Alias for `216.17.46.98` was created at 01:07:32 with `state: detected`, `sighting_count: 2`
- Sweep result for `216.17.46.98` arrived at 01:39:11 (32 minutes later)
- Lookup missed the alias because it wasn't `confirmed` (threshold: 3)
- New device `sweep-216.17.46.98-65064175` was created as a duplicate
- The original alias is now orphaned and will never reach 3 sightings

## What Changes

1. **Detected alias fallback lookup** - When sweep/reconciliation finds no device via strong identifiers AND no confirmed alias, fall back to checking `detected` aliases before creating a new device

2. **Auto-confirm on sweep resolution** - When a `detected` alias is used to resolve a sweep host, immediately promote it to `confirmed` state (the sweep result itself is a strong signal)

3. **Alias creation for sweep devices** - When a sweep device IS created (no alias match), create an alias record so future sightings can trigger reconciliation

4. **Scheduled reconciliation enhancement** - The existing scheduled reconciliation job should also scan for devices that share `detected` alias IPs and merge them

## Impact

- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/identity/device_lookup.ex` - Add detected alias fallback
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex` - Use fallback, create aliases
  - `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex` - Include detected aliases
  - `elixir/serviceradar_core/lib/serviceradar/identity/device_alias_state.ex` - Add confirm_from_sweep action
