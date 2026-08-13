defmodule ServiceRadar.Inventory.IdentityReconciler do
  @moduledoc """
  Device Identity and Reconciliation Engine (DIRE) — public facade.

  This module is the single entry point for device identity resolution.
  The implementation lives in focused submodules under
  `ServiceRadar.Inventory.Identity`:

    * `Identity.Mac` — MAC normalization, validation, confidence
    * `Identity.Ids` — identifier extraction, priority, deterministic UIDs
    * `Identity.Resolver` — canonical resolution, lookups, alias/IP fallback,
      merge-audit canonical following (tombstone resurrection protection)
    * `Identity.AliasGuard` — strong-identity guards for IP-alias merges
    * `Identity.MergePolicy` — evidence policy for automatic merges
    * `Identity.Registrar` — identifier registration + conflict resolution
    * `Identity.MergeEngine` — transactional merge/unmerge with stability
      guards (distinct-agent veto, per-pair cooldown)
    * `Identity.Reassignments` — device-linked record moves during merges
    * `Identity.EndpointInventoryMoves` — endpoint-inventory ownership moves
    * `Identity.DuplicateSweep` — scheduled duplicate reconciliation

  ## Resolution Priority

  1. Strong identifiers (Agent ID > Armis ID > Integration ID > NetBox ID >
     manufacturer-scoped hardware serial > MAC)
  2. Existing `sr:` UUID in update (re-validated against canonical mapping)
  3. IP-only fallback (only when no strong identifier is present)

  IP is a weak identifier. Passive fingerprints are corroborating evidence
  only; they are never used as lookup or merge keys.
  """

  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.DuplicateSweep
  alias ServiceRadar.Inventory.Identity.EndpointInventoryMoves
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.Registrar
  alias ServiceRadar.Inventory.Identity.Resolver

  @type strong_identifiers :: Ids.strong_identifiers()
  @type device_update :: Ids.device_update()

  # Resolution
  defdelegate resolve_device_id(update, opts \\ []), to: Resolver
  defdelegate follow_canonical_device_id(device_id, actor), to: Resolver
  defdelegate lookup_by_strong_identifiers(ids, actor, preferred_device_id \\ nil), to: Resolver
  defdelegate lookup_by_ip(ids, actor, opts \\ []), to: Resolver
  defdelegate lookup_alias_device_id(ip, partition, actor, opts \\ []), to: Resolver

  # Identifier extraction / vocabulary
  defdelegate extract_strong_identifiers(update), to: Ids
  defdelegate has_strong_identifier?(ids), to: Ids
  defdelegate highest_priority_identifier(ids), to: Ids
  defdelegate generate_deterministic_device_id(ids), to: Ids
  defdelegate mac_lookup_values(ids), to: Ids
  defdelegate serviceradar_uuid?(device_id), to: Ids
  defdelegate service_device_id?(device_id), to: Ids
  defdelegate legacy_ip_based_id?(device_id), to: Ids

  # MAC handling
  defdelegate normalize_mac(mac), to: Mac
  defdelegate normalize_mac_list(raw), to: Mac
  defdelegate locally_administered_mac?(mac), to: Mac
  defdelegate hardware_mac_sibling(mac), to: Mac
  defdelegate hardware_mac_siblings?(left, right), to: Mac
  defdelegate mac_confidence(mac), to: Mac

  # Registration
  defdelegate register_identifiers(device_id, ids, opts \\ []), to: Registrar
  defdelegate repair_agent_identifier(agent_id, device_id, actor), to: Registrar

  # Alias guards
  defdelegate distinct_agent_identity_conflict?(device_a, device_b, actor), to: AliasGuard

  defdelegate invalidate_ip_alias(ip, partition, alias_device_id, device_id, actor),
    to: AliasGuard

  # Merge / unmerge
  defdelegate merge_devices(from_device_id, to_device_id, opts \\ []), to: MergeEngine
  defdelegate unmerge_device(from_device_id, opts \\ []), to: MergeEngine
  defdelegate record_merge(from_device_id, to_device_id, reason, opts \\ []), to: MergeEngine

  # Scheduled reconciliation
  defdelegate reconcile_duplicates(opts \\ []), to: DuplicateSweep

  # Endpoint inventory
  defdelegate backfill_endpoint_inventory_device_uid_for_agent(agent_id, device_uid, opts \\ []),
    to: EndpointInventoryMoves
end
