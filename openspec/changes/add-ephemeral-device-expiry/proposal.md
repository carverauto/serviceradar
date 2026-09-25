# Change: Expire ephemeral devices on last-seen

## Why

Nothing expires a device that stops being seen (#4603). `DeviceCleanupWorker` only purges rows
that are already soft-deleted. A phone or IoT endpoint seen under a randomized
(locally-administered) MAC, or a host a sweep found once at an address, stays in inventory
forever, and so does every later identity it rotates to. Such a device can never be
recognized again with certainty (update-dire-strong-identity-goal D4: randomized MACs never
identify a device), so its record needs a lifetime.

The chart's `core.reaper` and `core.identity.reaper` values describe an "IP-only ghost device"
reaper, but nothing reads them: they render into the legacy `serviceradar-config.yaml`, whose
Go consumer no longer exists, and the Elixir core has no reaper. This change is the first
implementation.

## What Changes

- `DeviceCleanupWorker` gains an expiry pass (`ServiceRadar.Inventory.EphemeralDeviceExpiry`)
  that runs before the purge: a live device unseen past `ephemeral_expiry_days` that holds no
  strong identifier is soft-deleted through `Device :soft_delete` with
  `deleted_reason: "stale_ephemeral"` and `deleted_by: "system:ephemeral_device_expiry"`.
- Eligibility is by identity strength, never by source. A device is never expired while it
  holds an agent, a source-authoritative identifier (Armis, integration, NetBox), a hardware
  serial or a globally-unique MAC -- in `device_identifiers`, `device_interface_macs`, its
  `mac` attribute or its metadata -- or when an operator created it (`discovery_sources`
  contains `manual`), or when it matches the configured SRQL exclusion query. The identifier
  rule is one SQL function, `platform.device_holds_strong_identifier(uid)`, applied both when
  selecting candidates and in the soft delete's `WHERE`, so selection and delete agree.
- Settings (`DeviceCleanupSettings`, edited on Settings -> Networks -> Inventory Cleanup):
  `ephemeral_expiry_enabled` (default off), `ephemeral_expiry_days` (default 30),
  `ephemeral_expiry_exclusion_query`, `ephemeral_expiry_max_fraction` (default 0.5) and
  `ephemeral_expiry_guard_override` (default off).
- A mass-expiry guard on the same terms as the canonical topology prune: a pass that would
  expire more than the configured fraction of live devices is refused, logged at error level
  with the counts and the override, and counted in telemetry.
- An expired device that is seen again comes back through the existing restore paths, which
  bump `identity_revision` and leave a `device_revival_audit` row carrying `stale_ephemeral`.
- The DIRE lifecycle model gains an `Expire` action and the property
  `ExpiryKeepsStrongIdentity` (expiry never removes a device holding a strong identifier),
  checked in `lifecycle_goal` and `lifecycle_current`, with a vacuity configuration and a
  trace recorded from the real code.

## Impact

- Affected specs: `device-inventory` (ADDED "Ephemeral Device Expiry").
- Affected code: `elixir/serviceradar_core` inventory cleanup, one migration, the web-ng
  Inventory Cleanup settings form, `formal/dire`.
- Relation to `add-estate-decommissioning-controls`: its "Device Expiry By Last Seen" covers
  every device and is still open. This change implements the ephemeral subset under that
  change's constraints (disabled by default, the prune-style mass-deletion guard, revival
  recorded). Its blocker 0b.1 (an inventory integration refreshing `last_seen_time`) does not
  reach this subset: a device an integration lists carries that integration's identifier and
  is never ephemeral.
