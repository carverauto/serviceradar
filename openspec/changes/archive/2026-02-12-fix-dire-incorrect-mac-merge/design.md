## Context

Two bugs combined to destroy farm01's inventory record:

**Bug 1 (immediate trigger):** Commit `b3d162fb9` (Feb 10, "fix: missing agent id #2784") changed `register_interface_mac` from `agent_id: nil` to `agent_id: agent_id` (extracted from the interface record). The interface record's `agent_id` field identifies the *polling agent* (who discovered the interface via SNMP), not the device that owns the interface. When agent-dusk (on `192.168.2.22`) polls tonka01 (`192.168.10.1`), the mapper registers tonka01's MACs with `agent_id: "agent-dusk"`, creating a false conflict that triggers a merge.

**Bug 2 (underlying gap):** The `remove-sweep-device-creation` change stopped sweeps from creating devices. The mapper's `resolve_device_ids` also never creates devices — it only looks up existing ones. So farm01 (a router at `192.168.1.1`/`192.168.2.1`/`192.168.3.1`/`152.117.116.178`, polled via SNMP, no agent running on it) has no creation path. Its interfaces are discovered but dropped because no device record exists.

**Downstream cascade:** Because farm01 had no device, its interface MACs and IPs got attributed to tonka01 via the agent_id merge bug. Tonka01 now owns 13 of farm01's MACs as strong identifiers and 3 of farm01's IPs as confirmed aliases.

## Goals / Non-Goals

- **Goals:**
  - Fix the agent_id attribution bug (revert the broken part of `b3d162fb9`)
  - Create a device creation path for mapper-discovered hosts
  - Add defensive layers (MAC classification, hostname guard) for future safety
  - Enable reversal of incorrect merges
  - Farm01 recovers automatically through normal mapper/sweep cycles after fix

- **Non-Goals:**
  - Changing DIRE's overall identifier priority hierarchy
  - Re-enabling sweep device creation for non-responding hosts
  - Rearchitecting how agents report interface discovery results

## Decisions

### Decision 1: Revert agent_id in interface MAC registration

Set `agent_id: nil` in `register_interface_mac`. Remove the `agent_id` extraction at line 176.

Before commit `b3d162fb9` (Feb 10), this was always `nil`. The commit's intent was to ensure agent_id gets registered as a strong identifier, but interface MAC registration is the wrong path for that. The `agent_id` in interface records means "who polled this device", not "who is this device". Agent identity is already registered through:
- Agent self-registration (when an agent connects and reports sysmon data)
- Device updates that carry agent_id in metadata
- `extract_strong_identifiers` which reads agent_id from update metadata

The `identity_reconciler.ex` changes from that commit (the `get_agent_id_from_update` fallback in `extract_strong_identifiers`) are correct and should be kept — those handle device updates where agent_id is at the top level.

### Decision 2: Mapper creates devices for unresolved IPs

In `resolve_device_ids`, when `lookup_device_uids_by_ip` returns no match for a device_ip:

1. Call `IdentityReconciler.resolve_device_id` with the interface data (IP, partition, MACs from the interface group)
2. DIRE generates a deterministic `sr:` UUID for the device
3. Create the device record in `ocsf_devices` with `discovery_sources: ["mapper"]`
4. Return the new device_id so interface records can be processed

This closes the device creation gap for SNMP-polled devices that don't run agents. It mirrors what sweeps used to do but goes through DIRE for proper `sr:` UUID generation.

**Alternatives considered:**
- Re-enable sweep device creation: Would re-introduce the "devices for non-responding hosts" problem that `remove-sweep-device-creation` fixed.
- Create devices only on second sighting: Adds complexity without clear benefit — if the mapper discovered interfaces, the device is real.

### Decision 3: Locally-Administered MAC Classification (Defensive Layer)

Add `locally_administered_mac?/1` that checks IEEE bit 1 of the first octet: `band(first_byte, 0x02) != 0`.

Register locally-administered MACs with `confidence: :medium`. Only merge when at least one shared identifier is `strong` confidence. This prevents false merges from virtual bridge MACs, Docker-generated MACs, etc.

### Decision 4: Hostname Conflict Guard (Safety Net)

Before any merge in `merge_conflicting_devices`, compare hostnames. Block merge and log warning when both devices have different non-empty hostnames.

### Decision 5: Unmerge via Merge Audit Trail

Add `unmerge_device/2` that recreates the from-device, reassigns its identifiers, and records an audit entry.

## Risks / Trade-offs

- **Risk**: Mapper-created devices could inflate inventory if SNMP returns many IPs.
  - **Mitigation**: Devices are only created for IPs that have actual interface records. The mapper only reports IPs it was explicitly configured to poll.

- **Risk**: Reverting agent_id means interface-discovered MACs won't carry agent_id.
  - **Mitigation**: Agent identity is registered through other paths. MACs are still linked to the correct device.

## Data Recovery

After deploying fixes 1 and 2, farm01 will self-heal:
1. Next mapper cycle: agent-dusk polls farm01 → no device found for `192.168.2.1` → DIRE creates `sr:` device → interfaces registered with correct MACs (no agent_id contamination)
2. Next sweep cycle: farm01 responds at its IPs → sweep updates availability on the new device
3. Tonka01's incorrectly-claimed identifiers need one-time cleanup: remove farm01's MACs and IP aliases from tonka01 (migration or manual SQL)

## Open Questions

- Should we retroactively reclassify existing locally-administered MAC identifiers from `strong` to `medium` confidence? (Recommended: yes, as a migration)
- Should the mapper device creation also update the alias state when it discovers a device at an IP that's currently aliased to another device? (Probably yes — if DIRE creates a new device for that IP, the alias should be invalidated)
