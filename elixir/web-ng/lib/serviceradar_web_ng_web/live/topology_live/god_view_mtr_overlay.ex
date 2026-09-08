defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewMtrOverlay do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias ServiceRadarWebNG.Graph, as: AgeGraph

  @mtr_paths_cache_ttl_ms 10_000

  def clear_path_data(socket) do
    push_event(socket, "god_view:mtr_path_data", %{paths: []})
  end

  def push_path_data(socket) do
    {paths, socket} = cached_mtr_paths(socket)
    push_event(socket, "god_view:mtr_path_data", %{paths: paths})
  end

  defp cached_mtr_paths(socket) do
    now_ms = System.monotonic_time(:millisecond)

    case socket.assigns do
      %{mtr_paths_cache: %{at_ms: at_ms, paths: paths}}
      when is_integer(at_ms) and now_ms - at_ms < @mtr_paths_cache_ttl_ms and is_list(paths) ->
        {paths, socket}

      _ ->
        paths = load_mtr_paths()
        {paths, assign(socket, :mtr_paths_cache, %{at_ms: now_ms, paths: paths})}
    end
  end

  defp load_mtr_paths do
    cypher = """
    MATCH (a)-[r:MTR_PATH]->(b)
    WHERE a.id IS NOT NULL AND b.id IS NOT NULL
    RETURN {
      source: a.id,
      target: b.id,
      source_addr: coalesce(a.addr, ''),
      target_addr: coalesce(b.addr, ''),
      avg_us: coalesce(r.avg_us, 0),
      loss_pct: coalesce(r.loss_pct, 0.0),
      jitter_us: coalesce(r.jitter_us, 0),
      from_hop: coalesce(r.from_hop, 0),
      to_hop: coalesce(r.to_hop, 0),
      agent_id: coalesce(r.agent_id, '')
    }
    LIMIT 500
    """

    case AgeGraph.query(cypher) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.map(&normalize_mtr_path_row/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp normalize_mtr_path_row(%{} = row) do
    row =
      if map_size(row) == 1 do
        [{_k, v}] = Map.to_list(row)
        if is_map(v), do: v, else: row
      else
        row
      end

    source = Map.get(row, "source") || Map.get(row, :source)
    target = Map.get(row, "target") || Map.get(row, :target)

    if is_binary(source) and is_binary(target) do
      %{
        source: source,
        target: target,
        source_addr: mtr_str(row, "source_addr"),
        target_addr: mtr_str(row, "target_addr"),
        avg_us: mtr_int(row, "avg_us"),
        loss_pct: mtr_float(row, "loss_pct"),
        jitter_us: mtr_int(row, "jitter_us"),
        from_hop: mtr_int(row, "from_hop"),
        to_hop: mtr_int(row, "to_hop"),
        agent_id: mtr_str(row, "agent_id")
      }
    end
  end

  defp normalize_mtr_path_row(_), do: nil

  defp mtr_str(row, key) do
    case mtr_get(row, key) do
      nil -> ""
      val -> to_string(val)
    end
  end

  defp mtr_get(row, key) when is_map(row) and is_binary(key) do
    case Map.get(row, key) do
      nil ->
        mtr_atom_key_value(row, key)

      value ->
        value
    end
  end

  defp mtr_get(_row, _key), do: nil

  defp mtr_atom_key_value(row, key) do
    Enum.find_value(row, fn
      {k, v} when is_atom(k) -> mtr_atom_match(k, key, v)
      _ -> nil
    end)
  end

  defp mtr_atom_match(k, key, value) do
    if Atom.to_string(k) == key, do: value
  end

  defp mtr_int(row, key) do
    val = mtr_get(row, key)

    case val do
      v when is_integer(v) ->
        v

      v when is_float(v) ->
        round(v)

      v when is_binary(v) ->
        case Integer.parse(v) do
          {i, _} -> i
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp mtr_float(row, key) do
    val = mtr_get(row, key)

    case val do
      v when is_float(v) ->
        v

      v when is_integer(v) ->
        v * 1.0

      v when is_binary(v) ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> 0.0
        end

      _ ->
        0.0
    end
  end
end
