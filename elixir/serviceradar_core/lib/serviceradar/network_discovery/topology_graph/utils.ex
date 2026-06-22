defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Utils do
  @moduledoc false

  alias ServiceRadar.Graph

  @default_stale_minutes 180
  @physical_direct_protocols MapSet.new(["lldp", "cdp", "unifi-api"])
  @logical_direct_protocols MapSet.new(["wireguard-derived", "bgp", "ospf", "ipsec"])
  @hosted_protocols MapSet.new(["proxmox", "proxmox-api", "vmware", "esxi", "hyperv", "kvm"])
  @strict_ifindex_protocols MapSet.new(["lldp", "cdp"])
  @segment_evidence_classes MapSet.new(["inferred-segment"])
  @auxiliary_relations MapSet.new([
                         "LOGICAL_PEER",
                         "HOSTED_ON",
                         "ATTACHED_TO",
                         "INFERRED_TO",
                         "OBSERVED_TO"
                       ])

  @packet_metric_names ["ifInUcastPkts", "ifOutUcastPkts", "ifHCInUcastPkts", "ifHCOutUcastPkts"]
  @octet_metric_names ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"]

  def physical_direct_protocols, do: @physical_direct_protocols
  def logical_direct_protocols, do: @logical_direct_protocols
  def hosted_protocols, do: @hosted_protocols
  def strict_ifindex_protocols, do: @strict_ifindex_protocols
  def segment_evidence_classes, do: @segment_evidence_classes
  def auxiliary_relations, do: @auxiliary_relations
  def packet_metric_names, do: @packet_metric_names
  def octet_metric_names, do: @octet_metric_names

  def stale_cutoff_iso8601 do
    stale_minutes =
      :serviceradar_core
      |> Application.get_env(
        :mapper_topology_edge_stale_minutes,
        @default_stale_minutes
      )
      |> normalize_positive_int(@default_stale_minutes)

    DateTime.utc_now()
    |> DateTime.add(-stale_minutes * 60, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  def normalize_positive_int(_value, default), do: default

  def parse_confidence_score(value) when is_integer(value), do: value

  def parse_confidence_score(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def parse_confidence_score(_value), do: nil

  def normalize_protocol(nil), do: "unknown"

  def normalize_protocol(protocol) do
    protocol
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def normalize_evidence_class(nil), do: "inferred-segment"

  def normalize_evidence_class(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "direct" -> "direct-physical"
      "inferred" -> "inferred-segment"
      "endpoint-attachment" -> "endpoint-attachment"
      normalized -> normalized
    end
  end

  def normalize_confidence_tier(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def normalize_confidence_reason(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  def map_value(_map, _key), do: nil

  def normalize_endpoint_inventory_risk_summary(summary) do
    %{
      pkg_worst_severity:
        summary
        |> map_value(:pkg_worst_severity)
        |> normalize_risk_summary_severity(),
      pkg_critical_count:
        summary
        |> map_value(:pkg_critical_count)
        |> non_negative_integer(0),
      pkg_kev_count:
        summary
        |> map_value(:pkg_kev_count)
        |> non_negative_integer(0),
      pkg_has_unpatched_rce:
        summary
        |> map_value(:pkg_has_unpatched_rce)
        |> truthy?(),
      pkg_risk_summary_at:
        summary
        |> map_value(:pkg_risk_summary_at)
        |> normalize_risk_summary_timestamp()
    }
  end

  def normalize_risk_summary_severity(value) do
    case value |> non_blank() |> normalize_confidence_tier() do
      "critical" -> "critical"
      "high" -> "high"
      "medium" -> "medium"
      "low" -> "low"
      "none" -> "none"
      _ -> "unknown"
    end
  end

  def normalize_risk_summary_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def normalize_risk_summary_timestamp(value) when is_binary(value) do
    case non_blank(value) do
      nil -> current_iso8601_second()
      timestamp -> timestamp
    end
  end

  def normalize_risk_summary_timestamp(_value), do: current_iso8601_second()

  def current_iso8601_second do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def non_negative_integer(value, _default) when is_integer(value), do: max(value, 0)
  def non_negative_integer(value, _default) when is_float(value), do: value |> round() |> max(0)

  def non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> max(int, 0)
      :error -> default
    end
  end

  def non_negative_integer(_value, default), do: default

  def truthy?(true), do: true
  def truthy?(value) when value in [false, nil, 0], do: false
  def truthy?(value) when is_integer(value), do: value != 0

  def truthy?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["true", "1", "yes", "y"])
  end

  def truthy?(_value), do: false

  def default_evidence_class_for_protocol(protocol) do
    normalized = normalize_protocol(protocol)

    cond do
      MapSet.member?(@physical_direct_protocols, normalized) -> "direct-physical"
      MapSet.member?(@logical_direct_protocols, normalized) -> "direct-logical"
      MapSet.member?(@hosted_protocols, normalized) -> "hosted-virtual"
      true -> "inferred-segment"
    end
  end

  def normalize_relation_family(nil), do: nil

  def normalize_relation_family(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      family -> String.upcase(family)
    end
  end

  def default_relation_family_for_payload(protocol, source, evidence_class, confidence_reason) do
    normalized_protocol = normalize_protocol(protocol)
    normalized_source = normalize_protocol(source)
    normalized_evidence = normalize_evidence_class(evidence_class)
    normalized_confidence_reason = normalize_confidence_reason(confidence_reason)

    cond do
      normalized_evidence == "direct-physical" ->
        "CONNECTS_TO"

      normalized_evidence == "direct-logical" ->
        "LOGICAL_PEER"

      normalized_evidence == "hosted-virtual" ->
        "HOSTED_ON"

      normalized_evidence == "observed-only" ->
        "OBSERVED_TO"

      normalized_evidence == "endpoint-attachment" ->
        "ATTACHED_TO"

      normalized_evidence == "inferred-segment" and
        normalized_confidence_reason == "single_identifier_inference" and
          (normalized_protocol == "snmp-l2" or normalized_source == "snmp-arp-fdb") ->
        "OBSERVED_TO"

      normalized_evidence == "inferred-segment" and
          normalized_confidence_reason == "single_identifier_inference" ->
        nil

      normalized_evidence == "inferred-segment" and
          (normalized_protocol == "snmp-l2" or normalized_source == "snmp-arp-fdb") ->
        "INFERRED_TO"

      true ->
        "OBSERVED_TO"
    end
  end

  def link_value(link, key) do
    Map.get(link, key) || Map.get(link, to_string(key))
  end

  def interface_id(nil, _if_name, _if_index), do: nil

  def interface_id(device_id, if_name, if_index) do
    cond do
      is_binary(if_name) and String.trim(if_name) != "" ->
        "#{device_id}/#{String.trim(if_name)}"

      is_integer(if_index) ->
        "#{device_id}/ifindex:#{if_index}"

      true ->
        nil
    end
  end

  def default_interface_id(device_id, label), do: "#{device_id}/#{label}"

  def non_blank(nil), do: nil

  def non_blank(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.downcase(trimmed) in ["nil", "null", "undefined"] -> nil
      true -> trimmed
    end
  end

  def non_blank(value) when is_atom(value) do
    if value in [nil, :null, :undefined], do: nil, else: Atom.to_string(value)
  end

  def non_blank(value), do: value |> to_string() |> non_blank()

  def set_prop(_node, _field, nil), do: ""
  def set_prop(_node, _field, ""), do: ""

  def set_prop(node, field, value) when is_list(value) do
    list = Enum.map_join(value, ", ", &cypher_value/1)
    "SET #{node}.#{field} = [#{list}]"
  end

  def set_prop(node, field, value) do
    "SET #{node}.#{field} = #{cypher_value(value)}"
  end

  def cypher_value(nil), do: "null"
  def cypher_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  def cypher_value(value) when is_integer(value), do: Integer.to_string(value)

  def cypher_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 8])

  def cypher_value(value) when is_binary(value), do: "'#{Graph.escape(value)}'"
  def cypher_value(value) when is_atom(value), do: "'#{Graph.escape(value)}'"
  def cypher_value(value), do: "'#{Graph.escape(to_string(value))}'"

  def value_to_non_negative_int(value) when is_integer(value) and value >= 0, do: value
  def value_to_non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)

  def value_to_non_negative_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  def value_to_non_negative_int(_), do: nil

  def min_non_zero(a, b) do
    av = value_to_non_negative_int(a) || 0
    bv = value_to_non_negative_int(b) || 0

    cond do
      av > 0 and bv > 0 -> min(av, bv)
      av > 0 -> av
      bv > 0 -> bv
      true -> 0
    end
  end

  def parse_ifindex(value) when is_integer(value) and value > 0, do: value

  def parse_ifindex(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  def parse_ifindex(_), do: nil
end
