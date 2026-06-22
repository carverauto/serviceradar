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

  defp neighbor_device_id(link) do
    Utils.link_value(link, :neighbor_device_id) ||
      Utils.link_value(link, :neighbor_mgmt_addr) ||
      Utils.link_value(link, :neighbor_chassis_id) ||
      Utils.link_value(link, :neighbor_system_name)
  end

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
