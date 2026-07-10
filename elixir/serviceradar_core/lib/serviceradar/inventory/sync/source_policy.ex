defmodule ServiceRadar.Inventory.Sync.SourcePolicy do
  @moduledoc """
  Source-aware identifier policy: which sources are observers (their
  agent_id must not become a device identifier), when MACs are eligible,
  and the effective identifier set for an update.
  """

  alias ServiceRadar.Inventory.IdentityReconciler

  def valid_ip?(value) when is_binary(value), do: String.trim(value) != ""
  def valid_ip?(_value), do: false

  def include_agent_identifier?(update, ids) do
    ids.agent_id not in [nil, ""] and not observer_agent_source?(update)
  end

  def include_mac_identifier?(update) do
    metadata = update.metadata || %{}

    if mapper_like_source?(update), do: mapper_primary_mac?(metadata), else: true
  end

  def mapper_like_source?(update) do
    source = String.downcase(update.source || "")
    metadata = update.metadata || %{}
    identity_source = String.downcase(to_string(metadata["identity_source"] || ""))

    source in ["mapper", "sweep", "network_discovery"] or
      identity_source in ["mapper_ip_seed", "mapper_primary_mac_seed"]
  end

  def observer_agent_source?(update) do
    source = String.downcase(update.source || "")

    mapper_like_source?(update) or
      source in ["armis", "snmp", "snmp-metrics", "snmp_metrics"]
  end

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
