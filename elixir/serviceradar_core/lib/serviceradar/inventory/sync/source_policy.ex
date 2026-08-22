defmodule ServiceRadar.Inventory.Sync.SourcePolicy do
  @moduledoc """
  Source-aware identifier policy: which sources are observers (their
  agent_id must not become a device identifier), when MACs are eligible,
  and the effective identifier set for an update.
  """
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.IdentityReconciler

  def valid_ip?(value) when is_binary(value), do: String.trim(value) != ""
  def valid_ip?(_value), do: false

  def include_agent_identifier?(update, ids) do
    ids.agent_id not in [nil, ""] and not observer_agent_source?(update)
  end

  @doc """
  Return the identifier types that may be looked up and registered for an
  update.

  Armis has a typed, source-authoritative identifier. Its raw integration_id
  is a compatibility field in the payload, not a second device identity.
  Keeping that rule here makes both batch lookup and registration use the same
  policy instead of relying on the extractor's current representation.
  """
  def identifier_types(update, ids) do
    Ids.identifier_priority()
    |> Enum.reject(&(&1 == :mac))
    |> Enum.reject(&(&1 == :agent_id and not include_agent_identifier?(update, ids)))
    |> Enum.reject(&(&1 == :integration_id and armis_source?(update)))
  end

  def include_mac_identifier?(update) do
    metadata = update.metadata || %{}

    cond do
      passive_census_source?(update) -> census_anchorable_mac?(metadata)
      mapper_like_source?(update) -> mapper_primary_mac?(metadata)
      true -> true
    end
  end

  @doc """
  True for the netprobe passive L2 device census (ARP/NDP sightings).

  The census sees whatever is on the wire, which is excellent evidence that
  something was present and poor evidence of what it durably is.
  """
  def passive_census_source?(update) when is_map(update) do
    source = String.downcase(to_string(update.source || ""))
    metadata = update.metadata || %{}
    identity_source = String.downcase(to_string(metadata["identity_source"] || ""))

    source in ["passive-census", "netprobe-census"] or
      identity_source in ["passive_census", "netprobe_census"]
  end

  def passive_census_source?(_update), do: false

  # A randomized MAC must never anchor a canonical device.
  #
  # iOS and Android rotate their MAC per SSID, so a passive census would mint a
  # fresh device on every rotation -- the anchorless-device and IP-squatting
  # failure mode, at far higher volume than any sweep produces.
  #
  # This is deliberately scoped to the census source rather than applied inside
  # `Ids.generate_deterministic_device_id/1`. Locally administered MACs are also
  # how virtualization, Docker and overlay networks address themselves
  # (`Identity.Mac`), so a global rule would stop existing VM and container
  # devices re-deriving their UID -- a silent migration hazard well outside this
  # feature. Here the same address keeps its meaning for those sources and loses
  # only its anchoring power when it arrives from a passive sighting.
  defp census_anchorable_mac?(metadata) when is_map(metadata) do
    case metadata["mac"] || metadata["identity_mac"] do
      nil -> false
      mac -> not Mac.locally_administered_mac?(mac)
    end
  end

  defp census_anchorable_mac?(_metadata), do: false

  def mapper_like_source?(update) do
    source = String.downcase(update.source || "")
    metadata = update.metadata || %{}
    identity_source = String.downcase(to_string(metadata["identity_source"] || ""))

    source in ["mapper", "sweep", "network_discovery"] or
      identity_source in ["mapper_ip_seed", "mapper_primary_mac_seed"]
  end

  def observer_agent_source?(update) do
    source = String.downcase(to_string(update.source || ""))

    mapper_like_source?(update) or
      source in ["armis", "snmp", "snmp-metrics", "snmp_metrics"]
  end

  def armis_source?(update) when is_map(update) do
    source = String.downcase(to_string(update.source || ""))
    metadata = update.metadata || %{}
    integration_type = String.downcase(to_string(metadata["integration_type"] || ""))

    source == "armis" or integration_type == "armis"
  end

  def armis_source?(_update), do: false

  defp mapper_primary_mac?(metadata) when is_map(metadata) do
    kind =
      metadata
      |> Map.get("identity_mac_kind", "")
      |> to_string()
      |> String.downcase()

    kind in ["primary", "management", "chassis"]
  end

  defp mapper_primary_mac?(_metadata), do: false

  def effective_identifiers(update) do
    ids = IdentityReconciler.extract_strong_identifiers(update)

    if observer_agent_source?(update) do
      # Observer agent_id identifies the scanner/poller, not the discovered endpoint.
      %{ids | agent_id: nil}
    else
      ids
    end
  end
end
