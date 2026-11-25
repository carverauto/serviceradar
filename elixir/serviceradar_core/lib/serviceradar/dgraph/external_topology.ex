defmodule ServiceRadar.Dgraph.ExternalTopology do
  @moduledoc """
  Typed Elixir facade for Horizon external topology writes, TTL pruning, and
  bounded multi-hop graph queries over `ServiceRadar.Dgraph.Native`.
  """

  alias ServiceRadar.Dgraph
  alias ServiceRadar.Dgraph.Call
  alias ServiceRadar.Dgraph.Native

  @default_max_hops 4
  @max_hops 8
  @default_limit 50
  @max_limit 200

  @spec upsert_external_topology(map()) :: {:ok, map()} | {:error, term()}
  def upsert_external_topology(snapshot) when is_map(snapshot) do
    with {:ok, url} <- Dgraph.url(),
         {:ok, payload} <- encode_snapshot(snapshot) do
      call(
        :upsert_external_topology,
        :bulk,
        true,
        &Native.upsert_external_topology(url, payload, &1)
      )
    end
  end

  def upsert_external_topology(_snapshot), do: {:error, "external snapshot must be a map"}

  @spec upsert_external_status(map()) :: :ok | {:error, term()}
  def upsert_external_status(patch) when is_map(patch) do
    with {:ok, url} <- Dgraph.url(),
         {:ok, payload} <- encode_status_patch(patch) do
      call(:upsert_external_status, :item, true, &Native.upsert_external_status(url, payload, &1))
    end
  end

  def upsert_external_status(_patch), do: {:error, "external status patch must be a map"}

  @spec prune_stale_external(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_stale_external(now_rfc3339) when is_binary(now_rfc3339) do
    trimmed = String.trim(now_rfc3339)

    if trimmed == "" do
      {:error, "timestamp must not be empty"}
    else
      with {:ok, url} <- Dgraph.url() do
        call(:prune_stale_external, :bulk, false, &Native.prune_stale_external(url, trimmed, &1))
      end
    end
  end

  def prune_stale_external(_now), do: {:error, "timestamp must be an RFC3339 string"}

  @spec blast_radius(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def blast_radius(seed_id, opts \\ []) when is_binary(seed_id) and is_list(opts) do
    seed = String.trim(seed_id)

    if seed == "" do
      {:error, "seed_id must not be empty"}
    else
      max_hops = clamp_hops(Keyword.get(opts, :max_hops, @default_max_hops))
      limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))

      with {:ok, url} <- Dgraph.url(),
           {:ok, json} <-
             call(
               :query_blast_radius,
               :item,
               false,
               &Native.query_blast_radius(url, seed, max_hops, limit, &1)
             ) do
        decode_json(json)
      end
    end
  end

  @spec shared_fate_spofs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def shared_fate_spofs(opts \\ []) when is_list(opts) do
    min_targets = opts |> Keyword.get(:min_targets, 2) |> clamp_positive(2, @max_limit)
    limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))

    with {:ok, url} <- Dgraph.url(),
         {:ok, json} <-
           call(
             :query_shared_fate_spofs,
             :bulk,
             false,
             &Native.query_shared_fate_spofs(url, min_targets, limit, &1)
           ) do
      decode_json(json)
    end
  end

  @spec customer_cone_impact(String.t() | pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def customer_cone_impact(asn_id, opts \\ []) when is_list(opts) do
    asn_str = asn_id |> to_string() |> String.trim()

    if asn_str == "" do
      {:error, "asn_id must not be empty"}
    else
      max_hops = clamp_hops(Keyword.get(opts, :max_hops, @default_max_hops))
      limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))

      with {:ok, url} <- Dgraph.url(),
           {:ok, json} <-
             call(
               :query_customer_cone,
               :item,
               false,
               &Native.query_customer_cone(url, asn_str, max_hops, limit, &1)
             ) do
        decode_json(json)
      end
    end
  end

  @spec multi_hop_trace(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def multi_hop_trace(src_id, dst_id \\ nil, opts \\ [])
      when is_binary(src_id) and is_list(opts) do
    src = String.trim(src_id)
    dst = if is_binary(dst_id) and String.trim(dst_id) != "", do: String.trim(dst_id)

    if src == "" do
      {:error, "src_id must not be empty"}
    else
      max_hops = clamp_hops(Keyword.get(opts, :max_hops, @default_max_hops))
      limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))

      with {:ok, url} <- Dgraph.url(),
           {:ok, json} <-
             call(
               :query_multi_hop_trace,
               :item,
               false,
               &Native.query_multi_hop_trace(url, src, dst, max_hops, limit, &1)
             ) do
        decode_json(json)
      end
    end
  end

  defp call(operation, class, retry?, submit) do
    Call.run(operation, submit, [cancel: &Native.cancel/1] ++ Dgraph.call_options(class, retry?))
  end

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, err} -> {:error, Exception.message(err)}
    end
  end

  defp encode_snapshot(snapshot) do
    generated_at = get_field(snapshot, :generated_at) || now_rfc3339()
    ttl_secs = get_int(snapshot, :ttl_secs) || 900
    nodes = Enum.map(get_field(snapshot, :nodes) || [], &encode_node(&1, generated_at))
    edges = Enum.map(get_field(snapshot, :edges) || [], &encode_edge(&1, generated_at, ttl_secs))

    {:ok,
     %{
       generated_at: to_string(generated_at),
       ttl_secs: max(ttl_secs, 1),
       nodes: nodes,
       edges: edges
     }}
  end

  defp encode_node(node, fallback_seen) do
    %{
      id: to_string(get_field(node, :id) || ""),
      kind: to_string(get_field(node, :kind) || ""),
      asn: get_int(node, :asn),
      label: get_str(node, :label),
      region: get_str(node, :region),
      ip: get_str(node, :ip),
      rpki_state: get_str(node, :rpki_state),
      rtbh_active: get_bool(node, :rtbh_active),
      max_length: get_int(node, :max_length),
      irr_status: get_str(node, :irr_status),
      metro: get_str(node, :metro),
      iata: get_str(node, :iata),
      country_code: get_str(node, :country_code),
      outage_state: get_str(node, :outage_state),
      last_seen: get_str(node, :last_seen) || to_string(fallback_seen),
      expires_at: get_str(node, :expires_at)
    }
  end

  defp encode_edge(edge, fallback_seen, default_ttl) do
    %{
      src_id: to_string(get_field(edge, :src_id) || ""),
      dst_id: to_string(get_field(edge, :dst_id) || ""),
      kind: to_string(get_field(edge, :kind) || ""),
      border_asn: get_int(edge, :border_asn),
      as_boundary_confidence: get_float(edge, :as_boundary_confidence),
      avg_rtt_us: get_int(edge, :avg_rtt_us),
      loss_pct: get_float(edge, :loss_pct),
      last_seen: get_str(edge, :last_seen) || to_string(fallback_seen),
      ttl_secs: get_int(edge, :ttl_secs) || default_ttl,
      expires_at: get_str(edge, :expires_at)
    }
  end

  defp encode_status_patch(patch) do
    entity_id = get_str(patch, :entity_id)

    if is_nil(entity_id) do
      {:error, "external status patch entity_id is required"}
    else
      {:ok,
       %{
         entity_id: entity_id,
         kind: get_str(patch, :kind),
         outage_state: get_str(patch, :outage_state),
         rpki_state: get_str(patch, :rpki_state),
         rtbh_active: get_bool(patch, :rtbh_active),
         last_seen: get_str(patch, :last_seen) || now_rfc3339(),
         expires_at: get_str(patch, :expires_at)
       }}
    end
  end

  defp clamp_hops(val) when is_integer(val) and val > 0, do: min(val, @max_hops)
  defp clamp_hops(_), do: @default_max_hops

  defp clamp_limit(val), do: clamp_positive(val, @default_limit, @max_limit)

  defp clamp_positive(val, _default, max) when is_integer(val) and val > 0, do: min(val, max)
  defp clamp_positive(_val, default, _max), do: default

  defp get_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get_str(map, key) do
    case get_field(map, key) do
      val when is_binary(val) ->
        trimmed = String.trim(val)
        if trimmed == "", do: nil, else: trimmed

      val when is_atom(val) and not is_nil(val) ->
        Atom.to_string(val)

      _ ->
        nil
    end
  end

  defp get_int(map, key) do
    case get_field(map, key) do
      val when is_integer(val) -> val
      _ -> nil
    end
  end

  defp get_float(map, key) do
    case get_field(map, key) do
      val when is_float(val) -> val
      val when is_integer(val) -> val / 1.0
      _ -> nil
    end
  end

  defp get_bool(map, key) do
    case get_field(map, key) do
      val when is_boolean(val) -> val
      _ -> nil
    end
  end

  defp now_rfc3339 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
