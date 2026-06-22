defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Projection do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @type projection_payload :: %{
          local_device_id: String.t(),
          local_device_ip: term(),
          neighbor_device_id: String.t(),
          local_interface_id: String.t(),
          neighbor_interface_id: String.t(),
          protocol: String.t(),
          local_if_name: term(),
          local_if_index: term(),
          neighbor_port_name: term(),
          neighbor_name: term(),
          neighbor_ip: term(),
          evidence_class: String.t(),
          relation_family: String.t(),
          confidence_tier: String.t(),
          confidence_score: number(),
          confidence_reason: String.t(),
          observed_at: String.t()
        }

  @doc """
  Pure classifier for mapper topology projection decisions.
  """
  @spec classify_projection(map()) ::
          {:ok,
           %{
             mode: :backbone | :auxiliary | :skip,
             relation: String.t() | nil,
             payload: projection_payload()
           }}
          | {:error, :missing_ids}
  def classify_projection(link) when is_map(link) do
    with {:ok, payload} <- build_link_payload(link) do
      case projection_mode(payload) do
        {:backbone, reason} ->
          {:ok, %{mode: :backbone, relation: "CONNECTS_TO", payload: payload, reason: reason}}

        {:auxiliary, reason} ->
          {:ok,
           %{
             mode: :auxiliary,
             relation: evidence_relation_type(payload),
             payload: payload,
             reason: reason
           }}

        {:skip, reason} ->
          {:ok, %{mode: :skip, relation: nil, payload: payload, reason: reason}}
      end
    end
  end

  @spec projection_diagnostics([map()]) :: %{
          accepted: map(),
          rejected: map(),
          total: non_neg_integer()
        }
  def projection_diagnostics(links) when is_list(links) do
    Enum.reduce(links, empty_projection_diagnostics(), fn link, diagnostics ->
      case projection_payload(link) do
        nil ->
          increment_diagnostic(diagnostics, :rejected, :missing_ids)

        payload ->
          increment_projection_diagnostic(diagnostics, payload)
      end
    end)
  end

  @spec build_link_payload(map()) :: {:ok, projection_payload()} | {:error, :missing_ids}
  def build_link_payload(link) when is_map(link) do
    case projection_payload(link) do
      nil -> {:error, :missing_ids}
      payload -> {:ok, payload}
    end
  end

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

  def projection_mode(payload) when is_map(payload) do
    cond do
      backbone_projectable_link?(payload) -> {:backbone, :projected_backbone}
      auxiliary_evidence_link?(payload) -> {:auxiliary, auxiliary_reason(payload)}
      true -> {:skip, skip_reason(payload)}
    end
  end

  def evidence_relation_type(payload) do
    Utils.normalize_relation_family(payload.relation_family) ||
      Utils.default_relation_family_for_payload(
        payload.protocol,
        payload.protocol,
        payload.evidence_class,
        payload.confidence_reason
      )
  end

  def empty_projection_diagnostics do
    %{accepted: %{}, rejected: %{}, total: 0}
  end

  def increment_projection_diagnostic(diagnostics, payload) do
    case projection_mode(payload) do
      {:backbone, reason} ->
        increment_diagnostic(diagnostics, :accepted, reason)

      {:auxiliary, reason} ->
        increment_diagnostic(diagnostics, :accepted, reason)

      {:skip, reason} ->
        increment_diagnostic(diagnostics, :rejected, reason)
    end
  end

  def increment_diagnostic(diag, bucket, reason) when is_map(diag) do
    reason_key = to_string(reason)

    diag
    |> update_in([bucket, reason_key], fn
      nil -> 1
      existing -> existing + 1
    end)
    |> Map.update!(:total, &(&1 + 1))
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

  defp backbone_projectable_link?(payload) when is_map(payload) do
    protocol = Utils.normalize_protocol(payload.protocol)
    relation = evidence_relation_type(payload)

    relation == "CONNECTS_TO" and
      MapSet.member?(Utils.physical_direct_protocols(), protocol) and
      interface_contract_valid?(protocol, payload)
  end

  defp auxiliary_evidence_link?(payload) when is_map(payload) do
    relation = evidence_relation_type(payload)
    inferred_allowed = relation == "INFERRED_TO" and inferred_evidence_projectable?(payload)
    auxiliary_relation_allowed = MapSet.member?(Utils.auxiliary_relations(), relation)

    inferred_allowed or auxiliary_relation_allowed
  end

  defp auxiliary_reason(payload) do
    case evidence_relation_type(payload) do
      "LOGICAL_PEER" -> :projected_logical
      "HOSTED_ON" -> :projected_hosted
      "ATTACHED_TO" -> :projected_attachment
      "INFERRED_TO" -> :projected_inferred
      _ -> :projected_observed
    end
  end

  defp skip_reason(payload) do
    evidence_class = Utils.normalize_evidence_class(payload.evidence_class)
    confidence_reason = Utils.normalize_confidence_reason(payload.confidence_reason)
    protocol = Utils.normalize_protocol(payload.protocol)
    strict_ifindex? = MapSet.member?(Utils.strict_ifindex_protocols(), protocol)

    cond do
      confidence_reason == "single_identifier_inference" and
          not allow_single_identifier_inference_projection?(payload) ->
        :skip_single_identifier_inference

      strict_ifindex? and not strict_protocol_interface_identity?(payload) ->
        :skip_missing_ifindex

      MapSet.member?(Utils.segment_evidence_classes(), evidence_class) ->
        :skip_inferred_low_confidence

      true ->
        :skip_policy_filtered
    end
  end

  defp inferred_evidence_projectable?(payload) when is_map(payload) do
    evidence_class = Utils.normalize_evidence_class(payload.evidence_class)
    confidence_tier = Utils.normalize_confidence_tier(payload.confidence_tier)
    confidence_reason = Utils.normalize_confidence_reason(payload.confidence_reason)

    MapSet.member?(Utils.segment_evidence_classes(), evidence_class) and
      (confidence_reason != "single_identifier_inference" or
         allow_single_identifier_inference_projection?(payload)) and
      (confidence_tier in ["high", "medium"] or payload.confidence_score >= 60)
  end

  defp allow_single_identifier_inference_projection?(payload) when is_map(payload) do
    protocol = Utils.normalize_protocol(payload.protocol)
    confidence_tier = Utils.normalize_confidence_tier(payload.confidence_tier)

    protocol == "snmp-l2" and confidence_tier in ["high", "medium"]
  end

  defp interface_contract_valid?(protocol, payload) do
    if MapSet.member?(Utils.strict_ifindex_protocols(), protocol) do
      strict_protocol_interface_identity?(payload)
    else
      true
    end
  end

  defp strict_protocol_interface_identity?(payload) when is_map(payload) do
    valid_ifindex?(payload.local_if_index) or is_binary(Utils.non_blank(payload.local_if_name))
  end

  defp valid_ifindex?(value) when is_integer(value), do: value > 0
  defp valid_ifindex?(_value), do: false

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
