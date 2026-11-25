defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.ExternalProjection do
  @moduledoc """
  Pure validation, deduplication, edge collapsing, and status normalization for
  Horizon NATS JetStream topology snapshots (`Contract #4`) and outage/BGP
  state events. Rejects/ignores raw per-round hop rows.
  """

  @allowed_node_kinds MapSet.new([
                        "Vantage",
                        "TransitRouter",
                        "IXP",
                        "Facility",
                        "ASN",
                        "Prefix",
                        "AnycastPop",
                        "SaasTarget"
                      ])

  @allowed_edge_kinds MapSet.new([
                        "traceroute_hop",
                        "border_handoff",
                        "as_rel_provider",
                        "as_rel_peer",
                        "ixp_member",
                        "anycast_serves"
                      ])

  @default_ttl_secs 900
  @min_ttl_secs 60
  @max_ttl_secs 86_400

  @spec normalize_snapshot(map()) ::
          {:ok, map()} | {:ignore, :raw_per_round_hops} | {:error, term()}
  def normalize_snapshot(payload) when is_map(payload) do
    if raw_hop_payload?(payload) do
      {:ignore, :raw_per_round_hops}
    else
      do_normalize_snapshot(payload)
    end
  end

  def normalize_snapshot(_payload), do: {:error, :invalid_snapshot}

  @spec normalize_status_event(String.t(), map()) ::
          {:ok, map()} | {:ignore, :unmatched_event}
  def normalize_status_event("serviceradar.horizon.outages." <> _rest, payload)
      when is_map(payload) do
    entity_id = resolve_status_entity_id(payload)

    outage_state =
      normalize_outage_state(
        field(payload, :outage_state) || field(payload, :status) || field(payload, :belief_state)
      )

    if is_binary(entity_id) and is_binary(outage_state) do
      last_seen = normalize_time(field(payload, :timestamp) || field(payload, :last_seen))
      ttl = clamp_ttl(field(payload, :ttl_secs))

      {:ok,
       %{
         entity_id: entity_id,
         kind: normalize_node_kind(field(payload, :kind)),
         outage_state: outage_state,
         rpki_state: nil,
         rtbh_active: nil,
         last_seen: DateTime.to_iso8601(last_seen),
         expires_at: add_ttl(last_seen, ttl)
       }}
    else
      {:ignore, :unmatched_event}
    end
  end

  def normalize_status_event("serviceradar.horizon.bgp." <> _rest, payload)
      when is_map(payload) do
    entity_id = resolve_bgp_entity_id(payload)

    if is_binary(entity_id) do
      last_seen = normalize_time(field(payload, :timestamp) || field(payload, :last_seen))
      ttl = clamp_ttl(field(payload, :ttl_secs))

      {:ok,
       %{
         entity_id: entity_id,
         kind: if(String.contains?(entity_id, "/"), do: "Prefix", else: "ASN"),
         outage_state: nil,
         rpki_state: non_blank(field(payload, :rpki_state) || field(payload, :rpki_status)),
         rtbh_active: normalize_rtbh(payload),
         last_seen: DateTime.to_iso8601(last_seen),
         expires_at: add_ttl(last_seen, ttl)
       }}
    else
      {:ignore, :unmatched_event}
    end
  end

  def normalize_status_event(_subject, _payload), do: {:ignore, :unmatched_event}

  @doc "Formats `now` as a second-truncated RFC3339 timestamp for TTL pruning."
  @spec prune_timestamp(DateTime.t()) :: String.t()
  def prune_timestamp(now \\ DateTime.utc_now()) do
    now
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc "Computes the fallback `last_seen` cutoff (`now - ttl_secs`) used when `expires_at` is absent."
  @spec stale_cutoff(DateTime.t(), non_neg_integer()) :: String.t()
  def stale_cutoff(now \\ DateTime.utc_now(), ttl_secs \\ @default_ttl_secs)
  def stale_cutoff(now, 0), do: prune_timestamp(now)

  def stale_cutoff(now, ttl_secs) do
    now
    |> DateTime.truncate(:second)
    |> DateTime.shift(second: -clamp_ttl(ttl_secs))
    |> DateTime.to_iso8601()
  end

  defp do_normalize_snapshot(payload) do
    version = field(payload, :schema_version)
    raw_generated = field(payload, :generated_at)

    with true <- version == 1,
         {:ok, generated_dt} <- parse_rfc3339(raw_generated),
         nodes when is_list(nodes) <- field(payload, :nodes) || [],
         edges when is_list(edges) <- field(payload, :edges) || [] do
      ttl_secs = clamp_ttl(field(payload, :ttl_secs))
      generated_iso = DateTime.to_iso8601(generated_dt)

      normalized_nodes =
        nodes
        |> Enum.reduce(%{}, &reduce_node(&1, &2, generated_dt, ttl_secs))
        |> Map.values()

      normalized_edges =
        edges
        |> Enum.reduce(%{}, &reduce_edge(&1, &2, generated_dt, ttl_secs))
        |> Map.values()
        |> Enum.map(&finalize_edge/1)

      {:ok,
       %{
         schema_version: 1,
         generated_at: generated_iso,
         ttl_secs: ttl_secs,
         nodes: normalized_nodes,
         edges: normalized_edges
       }}
    else
      false -> {:error, :unsupported_schema_version}
      {:error, _} -> {:error, :invalid_generated_at}
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp raw_hop_payload?(payload) do
    is_list(field(payload, :raw_hops)) or
      is_list(field(payload, :path_hops)) or
      is_list(field(payload, :rounds)) or
      is_list(field(payload, :probes)) or
      not is_nil(field(payload, :round_id))
  end

  defp reduce_node(raw, acc, generated_dt, ttl_secs) when is_map(raw) do
    id = non_blank(field(raw, :id))
    kind = normalize_node_kind(field(raw, :kind))

    if is_binary(id) and kind in @allowed_node_kinds do
      last_seen_dt = normalize_time(field(raw, :last_seen), generated_dt)

      node = %{
        id: id,
        kind: kind,
        asn: int_or_nil(field(raw, :asn)),
        label: non_blank(field(raw, :label)),
        region: non_blank(field(raw, :region)),
        ip: non_blank(field(raw, :ip)),
        rpki_state: non_blank(field(raw, :rpki_state) || field(raw, :rpki_status)),
        rtbh_active: bool_or_nil(field(raw, :rtbh_active)),
        max_length: int_or_nil(field(raw, :max_length)),
        irr_status: non_blank(field(raw, :irr_status)),
        metro: non_blank(field(raw, :metro)),
        iata: non_blank(field(raw, :iata)),
        country_code: non_blank(field(raw, :country_code)),
        outage_state: normalize_outage_state(field(raw, :outage_state)),
        last_seen: DateTime.to_iso8601(last_seen_dt),
        expires_at: add_ttl(last_seen_dt, ttl_secs)
      }

      Map.update(acc, id, node, &merge_non_nil(&1, node))
    else
      acc
    end
  end

  defp reduce_node(_raw, acc, _generated_dt, _ttl_secs), do: acc

  defp reduce_edge(raw, acc, generated_dt, ttl_secs) when is_map(raw) do
    src_id = non_blank(field(raw, :src_id))
    dst_id = non_blank(field(raw, :dst_id))
    kind = normalize_edge_kind(field(raw, :kind))
    raw_round? = not is_nil(field(raw, :round_id))

    if not raw_round? and is_binary(src_id) and is_binary(dst_id) and kind in @allowed_edge_kinds do
      last_seen_dt = normalize_time(field(raw, :last_seen), generated_dt)
      rtt = int_or_nil(field(raw, :avg_rtt_us))
      loss = float_or_nil(field(raw, :loss_pct))

      entry = %{
        src_id: src_id,
        dst_id: dst_id,
        kind: kind,
        border_asn: int_or_nil(field(raw, :border_asn)),
        as_boundary_confidence: float_or_nil(field(raw, :as_boundary_confidence)),
        rtt_sum: rtt || 0,
        rtt_count: if(is_nil(rtt), do: 0, else: 1),
        loss_sum: loss || 0.0,
        loss_count: if(is_nil(loss), do: 0, else: 1),
        last_seen: DateTime.to_iso8601(last_seen_dt),
        ttl_secs: ttl_secs,
        expires_at: add_ttl(last_seen_dt, ttl_secs)
      }

      Map.update(acc, {src_id, dst_id, kind}, entry, &collapse_edge(&1, entry))
    else
      acc
    end
  end

  defp reduce_edge(_raw, acc, _generated_dt, _ttl_secs), do: acc

  defp collapse_edge(prev, next) do
    %{
      prev
      | border_asn: next.border_asn || prev.border_asn,
        as_boundary_confidence: next.as_boundary_confidence || prev.as_boundary_confidence,
        rtt_sum: prev.rtt_sum + next.rtt_sum,
        rtt_count: prev.rtt_count + next.rtt_count,
        loss_sum: prev.loss_sum + next.loss_sum,
        loss_count: prev.loss_count + next.loss_count,
        last_seen: max(prev.last_seen, next.last_seen),
        expires_at: max(prev.expires_at, next.expires_at)
    }
  end

  defp finalize_edge(entry) do
    %{
      src_id: entry.src_id,
      dst_id: entry.dst_id,
      kind: entry.kind,
      border_asn: entry.border_asn,
      as_boundary_confidence: entry.as_boundary_confidence,
      avg_rtt_us: if(entry.rtt_count > 0, do: div(entry.rtt_sum, entry.rtt_count)),
      loss_pct: if(entry.loss_count > 0, do: Float.round(entry.loss_sum / entry.loss_count, 4)),
      last_seen: entry.last_seen,
      ttl_secs: entry.ttl_secs,
      expires_at: entry.expires_at
    }
  end

  defp merge_non_nil(earlier, later) do
    Map.merge(earlier, later, fn _k, old, new -> if(is_nil(new), do: old, else: new) end)
  end

  defp resolve_status_entity_id(payload) do
    non_blank(field(payload, :entity_id)) ||
      non_blank(field(payload, :target_id)) ||
      non_blank(field(payload, :id)) ||
      asn_entity_id(field(payload, :asn) || field(payload, :origin_asn))
  end

  defp resolve_bgp_entity_id(payload) do
    non_blank(field(payload, :covering_prefix)) ||
      non_blank(field(payload, :prefix)) ||
      non_blank(field(payload, :cidr)) ||
      non_blank(field(payload, :entity_id)) ||
      asn_entity_id(field(payload, :origin_asn) || field(payload, :asn))
  end

  defp asn_entity_id(asn) when is_integer(asn) and asn > 0, do: "asn:#{asn}"

  defp asn_entity_id(asn) when is_binary(asn) do
    case Integer.parse(String.trim(asn)) do
      {n, ""} when n > 0 -> "asn:#{n}"
      _ -> non_blank(asn)
    end
  end

  defp asn_entity_id(_), do: nil

  defp normalize_rtbh(payload) do
    case bool_or_nil(field(payload, :rtbh_active)) do
      val when is_boolean(val) -> val
      nil -> field(payload, :event_type) == "rtbh_blackhole"
    end
  end

  defp normalize_outage_state(val) when is_binary(val) do
    case val |> String.trim() |> String.downcase() do
      s when s in ["up", "healthy", "resolved", "none"] ->
        "up"

      "uncertain" ->
        "uncertain"

      s when s in ["confirmed_outage", "outage", "active", "down", "critical", "major"] ->
        "confirmed_outage"

      _ ->
        nil
    end
  end

  defp normalize_outage_state(_), do: nil

  defp normalize_node_kind(kind) when is_binary(kind) do
    trimmed = String.trim(kind)

    case String.downcase(trimmed) do
      "vantage" -> "Vantage"
      s when s in ["transitrouter", "transit_router"] -> "TransitRouter"
      "ixp" -> "IXP"
      "facility" -> "Facility"
      "asn" -> "ASN"
      "prefix" -> "Prefix"
      s when s in ["anycastpop", "anycast_pop"] -> "AnycastPop"
      s when s in ["saastarget", "saas_target"] -> "SaasTarget"
      _ -> trimmed
    end
  end

  defp normalize_node_kind(_), do: nil

  defp normalize_edge_kind(kind) when is_binary(kind) do
    kind |> String.trim() |> String.downcase()
  end

  defp normalize_edge_kind(_), do: nil

  defp clamp_ttl(val) when is_integer(val) and val > 0,
    do: val |> max(@min_ttl_secs) |> min(@max_ttl_secs)

  defp clamp_ttl(_), do: @default_ttl_secs

  defp parse_rfc3339(val) when is_binary(val) do
    case DateTime.from_iso8601(String.trim(val)) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp parse_rfc3339(_), do: {:error, :invalid_timestamp}

  defp normalize_time(val, fallback \\ nil) do
    case parse_rfc3339(val) do
      {:ok, dt} -> dt
      _ -> fallback || DateTime.truncate(DateTime.utc_now(), :second)
    end
  end

  defp add_ttl(dt, ttl_secs) do
    dt |> DateTime.shift(second: ttl_secs) |> DateTime.to_iso8601()
  end

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp non_blank(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_blank(_), do: nil

  defp int_or_nil(val) when is_integer(val), do: val

  defp int_or_nil(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int_or_nil(_), do: nil

  defp float_or_nil(val) when is_float(val), do: val
  defp float_or_nil(val) when is_integer(val), do: val / 1.0
  defp float_or_nil(_), do: nil

  defp bool_or_nil(val) when is_boolean(val), do: val
  defp bool_or_nil(_), do: nil
end
