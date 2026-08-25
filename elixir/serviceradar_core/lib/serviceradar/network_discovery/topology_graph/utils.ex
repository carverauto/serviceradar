defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Utils do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils.Cypher
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils.RiskSummary

  require Logger

  @default_stale_minutes 180
  @default_multiplier 3
  @physical_direct_protocols ["lldp", "cdp", "unifi-api"]
  @logical_direct_protocols ["wireguard-derived", "bgp", "ospf", "ipsec"]
  @hosted_protocols ["proxmox", "proxmox-api", "vmware", "esxi", "hyperv", "kvm"]
  @strict_ifindex_protocols ["lldp", "cdp"]
  @segment_evidence_classes ["inferred-segment"]
  @auxiliary_relations [
    "LOGICAL_PEER",
    "HOSTED_ON",
    "ATTACHED_TO",
    "INFERRED_TO",
    "OBSERVED_TO"
  ]

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

  def base_metric_name(name) when is_binary(name) do
    case String.split(name, "::", parts: 2) do
      [base | _] -> String.trim(base)
      _ -> name
    end
  end

  def base_metric_name(name) when is_atom(name) and not is_nil(name),
    do: base_metric_name(Atom.to_string(name))

  def base_metric_name(_), do: nil

  @doc """
  The instant before which a projected topology edge is no longer asserted as
  current.

  Derived from how often discovery actually runs, not from a fixed wall-clock
  window. A topology edge is a claim about how the network is wired *now*; the
  only thing that keeps it true is re-observation. So the question "is this
  stale?" is really "has this survived several chances to be re-observed?", and
  that depends on the discovery interval.

  A fixed cutoff gets this wrong in both directions. At 180 minutes against an
  hourly job it is three chances -- fine. Against a 6-hour job it is half of one
  interval, so every healthy edge is deleted between runs and re-created on the
  next, flapping the map forever. Against a 5-minute job it lets a dead link
  stand for 36 intervals.

  So: `multiplier * slowest enabled discovery interval`, floored at
  #{@default_stale_minutes} minutes so a very fast job cannot prune edges faster
  than downstream consumers can read them. The SLOWEST interval is used rather
  than a per-edge one because an edge records no job -- pruning on anything
  faster would delete links the slowest job has not yet had a chance to refresh.

  `:mapper_topology_edge_stale_minutes` still overrides everything when set, for
  an operator who wants a fixed window.
  """
  def stale_cutoff_iso8601 do
    DateTime.utc_now()
    |> DateTime.add(-stale_minutes() * 60, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc false
  @spec stale_minutes() :: pos_integer()
  def stale_minutes do
    case Application.get_env(:serviceradar_core, :mapper_topology_edge_stale_minutes) do
      explicit when is_integer(explicit) and explicit > 0 ->
        explicit

      _ ->
        derive_stale_minutes(discovery_interval_strings(), stale_interval_multiplier())
    end
  end

  @doc false
  @spec stale_interval_multiplier() :: pos_integer()
  def stale_interval_multiplier do
    :serviceradar_core
    |> Application.get_env(:mapper_topology_edge_stale_interval_multiplier, @default_multiplier)
    |> normalize_positive_int(@default_multiplier)
  end

  @doc """
  Pure half of `stale_minutes/0`: the window implied by a set of discovery
  intervals.

  Split out so the rule is testable without a database, and so the failure mode
  is explicit -- with no intervals to reason about (no jobs, or none parseable)
  it returns the floor rather than something derived from nothing.
  """
  @spec derive_stale_minutes([String.t()], pos_integer()) :: pos_integer()
  def derive_stale_minutes(interval_strings, multiplier) when is_list(interval_strings) do
    interval_strings
    |> Enum.map(&parse_interval_minutes/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> @default_stale_minutes
      minutes -> max(@default_stale_minutes, Enum.max(minutes) * multiplier)
    end
  end

  @doc """
  Parse a discovery interval (`"15m"`, `"2h"`, `"90s"`, `"1d"`) into whole
  minutes, rounding up so a sub-minute interval never becomes zero.
  """
  @spec parse_interval_minutes(term()) :: pos_integer() | nil
  def parse_interval_minutes(value) when is_binary(value) do
    case Regex.run(~r/^\s*(\d+)\s*([smhd])?\s*$/i, value) do
      [_, digits] -> to_minutes(String.to_integer(digits), "m")
      [_, digits, unit] -> to_minutes(String.to_integer(digits), String.downcase(unit))
      _ -> nil
    end
  end

  def parse_interval_minutes(_value), do: nil

  defp to_minutes(0, _unit), do: nil
  defp to_minutes(n, "s"), do: max(1, div(n + 59, 60))
  defp to_minutes(n, "m"), do: n
  defp to_minutes(n, "h"), do: n * 60
  defp to_minutes(n, "d"), do: n * 60 * 24
  defp to_minutes(_n, _unit), do: nil

  # Enabled jobs only: a disabled job will never refresh anything, so holding
  # the cutoff open for its interval would keep dead edges alive indefinitely --
  # which is the exact failure this change exists to fix.
  defp discovery_interval_strings do
    import Ecto.Query, only: [from: 2]

    ServiceRadar.Repo.all(
      from(j in "mapper_jobs",
        prefix: "platform",
        where: j.enabled == true,
        select: j.interval
      )
    )
  rescue
    error ->
      Logger.warning(
        "Topology stale window: could not read discovery intervals: #{inspect(error)}"
      )

      []
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

  defdelegate normalize_endpoint_inventory_risk_summary(summary),
    to: RiskSummary

  defdelegate normalize_risk_summary_severity(value),
    to: RiskSummary

  defdelegate normalize_risk_summary_timestamp(value),
    to: RiskSummary

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
      normalized in @physical_direct_protocols -> "direct-physical"
      normalized in @logical_direct_protocols -> "direct-logical"
      normalized in @hosted_protocols -> "hosted-virtual"
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
        "#{device_id}/#{normalize_interface_label(if_name)}"

      is_integer(if_index) ->
        "#{device_id}/ifindex:#{if_index}"

      true ->
        nil
    end
  end

  # Canonicalize an interface label so the same physical port keyed by a MAC in
  # different formats (colon vs no-colon vs dot, mixed case) resolves to one id.
  # LLDP/CDP neighbor port-ids are frequently MACs in varying encodings, which was
  # producing duplicate Interface vertices (e.g. "d021f9d2e16d" vs
  # "d0:21:f9:d2:e1:6d"). Non-MAC labels (named ports) are returned trimmed,
  # unchanged.
  @spec normalize_interface_label(String.t()) :: String.t()
  def normalize_interface_label(label) when is_binary(label) do
    trimmed = String.trim(label)

    case canonical_mac(trimmed) do
      nil -> trimmed
      mac -> mac
    end
  end

  defp canonical_mac(value) do
    hex =
      value
      |> String.replace([":", "-", ".", " "], "")
      |> String.downcase()

    if hex =~ ~r/\A[0-9a-f]{12}\z/ do
      hex
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map_join(":", &Enum.join/1)
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

  defdelegate set_prop(node, field, value),
    to: Cypher

  defdelegate cypher_value(value), to: Cypher

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
