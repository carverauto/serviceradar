defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Projection.Payload do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  def projection_payload(link) when is_map(link) do
    with local_device_id when is_binary(local_device_id) <-
           Utils.non_blank(Utils.link_value(link, :local_device_id)),
         neighbor_device_id when is_binary(neighbor_device_id) <-
           Utils.non_blank(neighbor_device_id(link)) do
      local_interface_id = local_interface_id(link, local_device_id)
      neighbor_port = neighbor_port(link)
      neighbor_interface_id = neighbor_interface_id(neighbor_device_id, neighbor_port)
      metadata = Utils.link_value(link, :metadata) || %{}
      protocol = Utils.link_value(link, :protocol) || "unknown"
      source = Utils.map_value(metadata, :source) || protocol

      evidence_class =
        Utils.map_value(metadata, :evidence_class) ||
          Utils.default_evidence_class_for_protocol(protocol)

      relation_family =
        Utils.map_value(metadata, :relation_family) ||
          Utils.default_relation_family_for_payload(
            protocol,
            source,
            evidence_class,
            confidence_reason(link, metadata)
          )

      %{
        local_device_id: local_device_id,
        local_device_ip: Utils.link_value(link, :local_device_ip),
        neighbor_device_id: neighbor_device_id,
        local_interface_id: local_interface_id,
        neighbor_interface_id: neighbor_interface_id,
        protocol: protocol,
        local_if_name: Utils.link_value(link, :local_if_name),
        local_if_index: Utils.link_value(link, :local_if_index),
        neighbor_port_name: neighbor_port,
        neighbor_name: Utils.link_value(link, :neighbor_system_name),
        neighbor_ip: Utils.link_value(link, :neighbor_mgmt_addr),
        evidence_class: evidence_class,
        relation_family: relation_family,
        confidence_tier: confidence_tier(link, metadata),
        confidence_score: confidence_score(link, metadata),
        confidence_reason: confidence_reason(link, metadata),
        observed_at: observed_at(link)
      }
    else
      _ -> nil
    end
  end

  defp local_interface_id(link, local_device_id) do
    Utils.interface_id(
      local_device_id,
      Utils.link_value(link, :local_if_name),
      Utils.link_value(link, :local_if_index)
    ) || Utils.default_interface_id(local_device_id, "unknown-local")
  end

  defp neighbor_port(link) do
    Enum.find_value(
      [
        :neighbor_port_id,
        :neighbor_port_descr,
        :neighbor_chassis_id,
        :neighbor_system_name,
        :neighbor_mgmt_addr
      ],
      fn key -> Utils.non_blank(Utils.link_value(link, key)) end
    )
  end

  defp neighbor_interface_id(neighbor_device_id, neighbor_port) do
    Utils.interface_id(neighbor_device_id, neighbor_port, nil) ||
      Utils.default_interface_id(neighbor_device_id, "unknown-neighbor")
  end

  # Only resolved canonical `sr:` identities may become AGE Device vertices.
  # The historical fallback (neighbor_device_id ← mgmt_addr ← chassis_id ←
  # system_name) fabricated raw-IP/MAC pseudo-vertices that every downstream
  # consumer (canonical rebuild, runtime projection, god-view) filters out with
  # `STARTS WITH 'sr:'` gates — dead weight that only bloated the graph.
  # Unresolved neighbors are dropped before projection instead; see
  # drop_reason/1 and the `[:serviceradar, :mapper_topology, :neighbor_dropped]`
  # counter emitted by the link reducer.
  defp neighbor_device_id(link) do
    with value when is_binary(value) <-
           Utils.non_blank(Utils.link_value(link, :neighbor_device_id)),
         true <- String.starts_with?(value, "sr:") do
      value
    else
      _ -> nil
    end
  end

  @doc """
  Why `projection_payload/1` returns (or would return) nil for a link.

  Returns `:missing_local_id`, `:neighbor_unresolved` (no resolved neighbor
  device id), `:neighbor_not_canonical` (a neighbor id that is not a canonical
  `sr:` identity), or nil when the link projects.
  """
  def drop_reason(link) when is_map(link) do
    local = Utils.non_blank(Utils.link_value(link, :local_device_id))
    neighbor = Utils.non_blank(Utils.link_value(link, :neighbor_device_id))

    cond do
      is_nil(local) -> :missing_local_id
      is_nil(neighbor) -> :neighbor_unresolved
      not String.starts_with?(neighbor, "sr:") -> :neighbor_not_canonical
      true -> nil
    end
  end

  def drop_reason(_link), do: :missing_local_id

  defp confidence_tier(link, metadata) do
    Utils.link_value(link, :confidence_tier) ||
      Utils.map_value(metadata, :confidence_tier) ||
      "low"
  end

  defp confidence_score(link, metadata) do
    link
    |> Utils.link_value(:confidence_score)
    |> Utils.parse_confidence_score()
    |> case do
      nil ->
        metadata
        |> Utils.map_value(:confidence_score)
        |> Utils.parse_confidence_score()
        |> Kernel.||(0)

      score ->
        score
    end
  end

  defp confidence_reason(link, metadata) do
    Utils.link_value(link, :confidence_reason) ||
      Utils.map_value(metadata, :confidence_reason) ||
      "unspecified"
  end

  defp observed_at(link) do
    case Utils.link_value(link, :timestamp) do
      %DateTime{} = dt ->
        dt
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      value when is_binary(value) ->
        value

      _ ->
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
    end
  end
end
