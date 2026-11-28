defmodule ServiceRadar.Inventory.Sync.AttributeStrength do
  @moduledoc """
  Source and evidence strength of single-valued device attributes
  (`fix-device-attribute-source-precedence`).

  Several sources write the same attribute, and a last-writer-wins upsert let a
  source that knows less erase what a better source recorded, which the better
  source then wrote back: the attribute oscillated, and every flip re-versioned
  the agent configs compiled from it. Each write is therefore tagged with its
  source and strength (`tag/3`), the tag is stored in
  `ocsf_devices.attribute_provenance` beside the value, and a write replaces
  the stored value only when `accepted?/4` says so.

  ## Groups and ladders (weakest first)

    * `name` -- name and hostname, one value: agent check-in (only on the
      device the check-in creates) < address fallback (the update has
      no hostname, so the name is its kept non-link-local address) < observed
      hostname (passive census, mDNS, sweep) < automation inventory (AWX) <
      SNMP `sysName` (mapper) < platform inventory (hypervisor, camera, WiFi
      map and any other integration inventory) < manual.
    * `vendor` -- vendor_name and model, one value: SNMP agent software
      (Net-SNMP) < IEEE OUI registrant < hardware vendor < manual. OS,
      software and platform names are not vendor evidence at all
      (`Enrichment.not_vendor_evidence?/1`).
    * `type` -- type, type_id and metadata device_role, one value: agent
      check-in (only on the device the check-in creates) < generic
      (`host`, or an automation inventory's type) < fingerprint or
      classification rule < SNMP-derived < platform inventory < manual.
    * `integration_type` -- generic (automation inventory and non-inventory
      sources) < platform inventory that discovers the device as its own object.
    * `management_device_id` -- mapper < platform inventory (camera), including
      a platform clear to none.

  ## The decision (`accepted?/4`)

  A tagged write replaces the stored group when it is strictly stronger, or
  equally strong and from the source that recorded it. With no recorded
  strength it fills an empty group, and replaces a populated one (a row written
  before this change) only when it is above the weakest tier, so a census
  address fallback never renames a pre-rollout device. A group the write does
  not tag is not carried and stays stored. A recorded clear (a tag with an
  empty value) is a stored decision like any other.

  `platform.sr_attribute_write_accepted/4` is the same decision in SQL, used by
  the sync upsert's ON CONFLICT update and by the ranked direct writes, so
  concurrent writers cannot race a read-then-write; this module is its mirror
  for in-batch merging (`DeviceRecords.merge_records_by_uid/1`), so batch
  composition cannot change the outcome.
  """

  alias ServiceRadar.Inventory.Identity.Address
  alias ServiceRadar.Inventory.Sync.MacVendor
  alias ServiceRadar.Inventory.Sync.SourcePolicy

  @groups ~w(name vendor type integration_type management_device_id)

  @tiers %{
    "name" => %{
      agent_check_in: 0,
      address_fallback: 1,
      observed: 2,
      automation_inventory: 3,
      snmp: 4,
      platform_inventory: 5,
      manual: 6
    },
    "vendor" => %{agent_software: 1, oui: 2, hardware: 3, manual: 4},
    "type" => %{
      agent_check_in: 0,
      generic: 1,
      observed: 2,
      snmp: 3,
      platform_inventory: 4,
      manual: 5
    },
    "integration_type" => %{generic: 1, platform_inventory: 2, manual: 3},
    "management_device_id" => %{mapper: 1, platform_inventory: 2}
  }

  # Sources that are integration inventories by name. Any other update that
  # carries a metadata integration_type (DeviceDiscoveryIngestor stamps one on
  # every plugin inventory) is one too, unless it is listed in
  # @non_inventory_integration_types.
  @platform_sources MapSet.new(~w(
    hypervisor_enrichment
    proxmox
    wifi_map
    armis
    netbox
    camera_plugin
    endpoint_inventory
  ))
  @automation_sources MapSet.new(~w(awx))
  @snmp_sources MapSet.new(~w(mapper network_discovery snmp snmp-metrics snmp_metrics))
  @non_inventory_integration_types MapSet.new(~w(mapper agent))

  # Metadata keys with one owning writer (design decision 12). Another writer
  # may only fill an absent key. The owner is named by the record's discovery
  # source.
  @owned_metadata_keys %{
    "hypervisor_enrichment" => ~w(
      hypervisor_provider_ref
      proxmox_node
      proxmox_cluster
      hypervisor_guest_type
      hypervisor_vmid
      proxmox_base_url
    ),
    "mapper" => ~w(proxmox_candidate proxmox_tls_sans_recorded proxmox_tls_san_ips)
  }

  @type group :: String.t()
  @type tag :: %{String.t() => String.t() | non_neg_integer()}

  @doc "The attribute groups, in the order they appear in `attribute_provenance`."
  def groups, do: @groups

  @doc "Owned metadata keys by owning discovery source."
  def owned_metadata_keys, do: @owned_metadata_keys

  @doc "The strength of `tier` on `group`'s ladder."
  @spec strength(group(), atom()) :: non_neg_integer()
  def strength(group, tier), do: @tiers |> Map.fetch!(group) |> Map.fetch!(tier)

  @doc "The tag a write of `group` at `tier` from `source` carries."
  @spec tag(group(), atom(), String.t() | nil) :: tag()
  def tag(group, tier, source) do
    %{"source" => normalize_source(source), "strength" => strength(group, tier)}
  end

  @doc """
  Whether a write tagged `incoming` (a provenance map) replaces `group` given
  the `stored` provenance map and whether the stored group holds a value.
  Mirrors `platform.sr_attribute_write_accepted/4`.
  """
  @spec accepted?(map() | nil, map() | nil, group(), boolean()) :: boolean()
  def accepted?(stored, incoming, group, stored_populated?) do
    case {tag_of(incoming, group), tag_of(stored, group)} do
      {nil, _stored} ->
        false

      {incoming_tag, nil} ->
        not stored_populated? or incoming_tag["strength"] > 1

      {incoming_tag, stored_tag} ->
        incoming_tag["strength"] > stored_tag["strength"] or
          (incoming_tag["strength"] == stored_tag["strength"] and
             incoming_tag["source"] == stored_tag["source"])
    end
  end

  defp tag_of(provenance, group) when is_map(provenance) do
    case Map.get(provenance, group) do
      %{"strength" => strength} = tag when is_integer(strength) -> tag
      _ -> nil
    end
  end

  defp tag_of(_provenance, _group), do: nil

  @doc """
  The class of evidence a sync update's source provides:
  `:manual | :passive | :automation_inventory | :snmp | :platform_inventory |
  :observed`.
  """
  def source_class(update) do
    source = normalize_source(update.source)
    integration_type = integration_type(update)

    cond do
      source == "manual" ->
        :manual

      SourcePolicy.passive_census_source?(update) or SourcePolicy.enrichment_only_source?(update) ->
        :passive

      MapSet.member?(@automation_sources, source) or
          MapSet.member?(@automation_sources, integration_type) ->
        :automation_inventory

      MapSet.member?(@snmp_sources, source) ->
        :snmp

      MapSet.member?(@platform_sources, source) or
          (integration_type != nil and
             not MapSet.member?(@non_inventory_integration_types, integration_type)) ->
        :platform_inventory

      true ->
        :observed
    end
  end

  @doc """
  The name / hostname write of a sync update: `{name, hostname, tag}`, or
  `{nil, nil, nil}` when it carries no name.

  A hostname is ranked by the source class. An update with no hostname (or
  whose hostname is only its own address, as the mapper reports a device that
  has no `sysName`) is an address fallback: the update's address as the name,
  at the weakest tier, and nothing at all when that address is link-local or
  not an address -- a link-local sighting never names a device.

  The fallback leaves `hostname` unwritten (the group's stored hostname stays,
  and is empty whenever a fallback is accepted). Design decision 7 has it carry
  the address in `hostname` too, but a stored hostname is identity evidence: an
  address there made a different device later polled at the same address
  resolve to the first device's record (the mapper's "a device polled at an
  address another device's record still holds gets its own record" case).
  """
  def name_write(update) do
    hostname = blank_to_nil(update.hostname)
    ip = blank_to_nil(update.ip)

    if hostname != nil and not same_address?(hostname, ip) and not ip_literal?(hostname) do
      tier =
        case source_class(update) do
          :passive -> :observed
          class -> class
        end

      {hostname, hostname, tag("name", tier, update.source)}
    else
      address_fallback(ip, update.source)
    end
  end

  defp ip_literal?(value) when is_binary(value), do: Address.classify(value) != :invalid
  defp ip_literal?(_value), do: false

  defp address_fallback(ip, source) when is_binary(ip) do
    if Address.classify(ip) in [:global, :private, :unique_local] do
      {ip, nil, tag("name", :address_fallback, source)}
    else
      {nil, nil, nil}
    end
  end

  defp address_fallback(_ip, _source), do: {nil, nil, nil}

  defp same_address?(hostname, ip) when is_binary(ip),
    do: String.downcase(String.trim(hostname)) == String.downcase(String.trim(ip))

  defp same_address?(_hostname, _ip), do: false

  @doc """
  The tag of a vendor write. `class` is `:hardware`, `:agent_software` or
  `:oui`; nil means no vendor.
  """
  def vendor_tag(nil, _update), do: nil

  def vendor_tag(class, update) do
    tier = if source_class(update) == :manual, do: :manual, else: class
    tag("vendor", tier, update.source)
  end

  @doc """
  The tag of a type write. `evidence` comes from `Enrichment.infer_device_type/2`;
  a role in metadata without a derived type still tags the group (a role-only
  write).
  """
  def type_tag(type, evidence, update) do
    role = blank_to_nil(get_in(update.metadata || %{}, ["device_role"]))

    if blank_to_nil(type) == nil and role == nil,
      do: nil,
      else: tag("type", type_tier(type, evidence, update), update.source)
  end

  defp type_tier(type, evidence, update) do
    class = source_class(update)

    cond do
      class == :manual -> :manual
      generic_type?(type) -> :generic
      evidence == :rule -> :observed
      evidence == :snmp -> :snmp
      class == :platform_inventory -> :platform_inventory
      class == :snmp -> :snmp
      class == :automation_inventory -> :generic
      true -> :observed
    end
  end

  defp generic_type?(type) when is_binary(type),
    do: String.downcase(String.trim(type)) in ["host", "unknown", "generic"]

  defp generic_type?(_type), do: false

  @doc "The tag of an integration_type write carried in `metadata`."
  def integration_type_tag(metadata, update) do
    if blank_to_nil(Map.get(metadata || %{}, "integration_type")) == nil do
      nil
    else
      tier =
        case source_class(update) do
          :manual -> :manual
          :platform_inventory -> :platform_inventory
          _ -> :generic
        end

      tag("integration_type", tier, update.source)
    end
  end

  # The record fields and metadata keys of each group. Decided as one value: a
  # write is accepted or rejected for all of them together.
  @group_fields %{
    "name" => {[:name, :hostname], []},
    "vendor" => {[:vendor_name, :model], []},
    "type" => {[:type, :type_id], ["device_role"]},
    "integration_type" => {[], ["integration_type"]},
    "management_device_id" => {[:management_device_id], []}
  }

  @doc """
  Resolves the ranked groups of two upsert records for one device in one batch
  the way the upsert resolves them across two batches: `existing` is the
  earlier record (the stored row's stand-in), `incoming` the later, and
  `merged` the record the caller built from both, whose ranked fields this
  rewrites. An accepted group takes the incoming fields, keeping the existing
  value of a field the incoming write does not carry; a rejected group keeps the
  existing fields and tag. The OUI provenance keys follow the kept vendor, and
  an owned metadata key keeps the existing value unless the incoming writer
  owns it.
  """
  def fold_ranked(existing, incoming, merged) do
    stored_prov = Map.get(existing, :attribute_provenance) || %{}
    incoming_prov = Map.get(incoming, :attribute_provenance) || %{}
    existing_meta = Map.get(existing, :metadata) || %{}
    incoming_meta = Map.get(incoming, :metadata) || %{}

    merged =
      Enum.reduce(@groups, merged, fn group, acc ->
        {fields, keys} = Map.fetch!(@group_fields, group)
        populated? = populated?(existing, fields, keys)

        if accepted?(stored_prov, incoming_prov, group, populated?) do
          acc
          |> take_fields(fields, incoming, existing)
          |> take_metadata(keys, incoming_meta, existing_meta)
          |> follow_oui_provenance(group, incoming_meta)
          |> put_tag(group, Map.get(incoming_prov, group))
        else
          acc
          |> keep_fields(fields, existing)
          |> keep_metadata(keys, existing_meta)
          |> follow_oui_provenance(group, existing_meta)
          |> put_tag(group, Map.get(stored_prov, group))
        end
      end)

    keep_owned_metadata(merged, incoming, existing_meta)
  end

  defp populated?(record, fields, keys) do
    metadata = Map.get(record, :metadata) || %{}

    Enum.any?(fields, &present?(Map.get(record, &1))) or
      Enum.any?(keys, &present?(Map.get(metadata, &1)))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: value > 0
  defp present?(value), do: not is_nil(value)

  defp take_fields(record, fields, incoming, existing) do
    fields
    |> carried_by(incoming, existing)
    |> Enum.reduce(record, fn field, acc ->
      value = Map.get(incoming, field)
      Map.put(acc, field, if(present?(value), do: value, else: Map.get(existing, field)))
    end)
  end

  defp keep_fields(record, fields, existing) do
    fields
    |> carried_by(existing, record)
    |> Enum.reduce(record, &Map.put(&2, &1, Map.get(existing, &1)))
  end

  # Fields neither record has (management_device_id on most records) stay absent,
  # so the insert leaves them to the column default.
  defp carried_by(fields, a, b),
    do: Enum.filter(fields, &(Map.has_key?(a, &1) or Map.has_key?(b, &1)))

  defp take_metadata(record, keys, incoming_meta, existing_meta) do
    update_metadata(record, fn metadata ->
      Enum.reduce(keys, metadata, fn key, acc ->
        if present?(Map.get(incoming_meta, key)),
          do: Map.put(acc, key, Map.get(incoming_meta, key)),
          else: put_or_delete(acc, key, existing_meta)
      end)
    end)
  end

  defp keep_metadata(record, keys, existing_meta) do
    update_metadata(record, fn metadata ->
      Enum.reduce(keys, metadata, &put_or_delete(&2, &1, existing_meta))
    end)
  end

  defp follow_oui_provenance(record, "vendor", source_meta) do
    update_metadata(record, fn metadata ->
      Enum.reduce(oui_provenance_keys(), metadata, &put_or_delete(&2, &1, source_meta))
    end)
  end

  defp follow_oui_provenance(record, _group, _source_meta), do: record

  defp keep_owned_metadata(record, incoming, existing_meta) do
    sources = Map.get(incoming, :discovery_sources) || []

    update_metadata(record, fn metadata ->
      @owned_metadata_keys
      |> Enum.reject(fn {owner, _keys} -> owner in sources end)
      |> Enum.flat_map(fn {_owner, keys} -> keys end)
      |> Enum.filter(&Map.has_key?(existing_meta, &1))
      |> Enum.reduce(metadata, &Map.put(&2, &1, Map.get(existing_meta, &1)))
    end)
  end

  defp put_or_delete(metadata, key, source_meta) do
    case Map.fetch(source_meta, key) do
      {:ok, value} -> Map.put(metadata, key, value)
      :error -> Map.delete(metadata, key)
    end
  end

  defp update_metadata(record, fun),
    do: Map.put(record, :metadata, fun.(Map.get(record, :metadata) || %{}))

  defp put_tag(record, group, nil),
    do: Map.update(record, :attribute_provenance, %{}, &Map.delete(&1 || %{}, group))

  defp put_tag(record, group, tag),
    do:
      Map.update(record, :attribute_provenance, %{group => tag}, &Map.put(&1 || %{}, group, tag))

  @doc "The metadata keys that record an OUI-derived vendor; they follow the kept vendor."
  def oui_provenance_keys, do: ["mac_vendor" | MacVendor.metadata_keys()]

  defp integration_type(update) do
    case blank_to_nil(Map.get(update.metadata || %{}, "integration_type")) do
      nil -> nil
      value -> normalize_source(value)
    end
  end

  defp normalize_source(source) when is_binary(source),
    do: source |> String.trim() |> String.downcase()

  defp normalize_source(_source), do: "unknown"

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
