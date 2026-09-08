defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Projection.Policy do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

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

  defp backbone_projectable_link?(payload) when is_map(payload) do
    protocol = Utils.normalize_protocol(payload.protocol)
    relation = evidence_relation_type(payload)

    relation == "CONNECTS_TO" and
      protocol in Utils.physical_direct_protocols() and
      interface_contract_valid?(protocol, payload)
  end

  defp auxiliary_evidence_link?(payload) when is_map(payload) do
    relation = evidence_relation_type(payload)
    inferred_allowed = relation == "INFERRED_TO" and inferred_evidence_projectable?(payload)

    auxiliary_relation_allowed =
      relation != "INFERRED_TO" and relation in Utils.auxiliary_relations()

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
    strict_ifindex? = protocol in Utils.strict_ifindex_protocols()

    cond do
      confidence_reason == "single_identifier_inference" and
          not allow_single_identifier_inference_projection?(payload) ->
        :skip_single_identifier_inference

      strict_ifindex? and not strict_protocol_interface_identity?(payload) ->
        :skip_missing_ifindex

      evidence_class in Utils.segment_evidence_classes() ->
        :skip_inferred_low_confidence

      true ->
        :skip_policy_filtered
    end
  end

  defp inferred_evidence_projectable?(payload) when is_map(payload) do
    evidence_class = Utils.normalize_evidence_class(payload.evidence_class)
    confidence_tier = Utils.normalize_confidence_tier(payload.confidence_tier)
    confidence_reason = Utils.normalize_confidence_reason(payload.confidence_reason)

    evidence_class in Utils.segment_evidence_classes() and
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
    if protocol in Utils.strict_ifindex_protocols() do
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
end
