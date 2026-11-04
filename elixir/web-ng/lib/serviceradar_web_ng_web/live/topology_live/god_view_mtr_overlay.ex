defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewMtrOverlay do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  require Logger

  @mtr_paths_cache_ttl_ms 10_000
  @max_mtr_paths 500
  @path_fields [
    :source,
    :target,
    :source_addr,
    :target_addr,
    :avg_us,
    :loss_pct,
    :jitter_us,
    :from_hop,
    :to_hop,
    :agent_id
  ]

  def clear_path_data(socket) do
    push_event(socket, "god_view:mtr_path_data", %{paths: []})
  end

  @doc """
  Pushes the current MTR path edges to the God View hook. A failed topology
  graph read is shown as a flash rather than drawn as an empty layer.
  """
  def push_path_data(socket) do
    case cached_mtr_paths(socket) do
      {:ok, paths, socket} ->
        push_event(socket, "god_view:mtr_path_data", %{paths: paths})

      {:error, socket} ->
        socket
        |> put_flash(:error, "MTR paths are unavailable: the topology graph could not be read.")
        |> clear_path_data()
    end
  end

  defp cached_mtr_paths(socket) do
    now_ms = System.monotonic_time(:millisecond)

    case socket.assigns do
      %{mtr_paths_cache: %{at_ms: at_ms, paths: paths}}
      when is_integer(at_ms) and now_ms - at_ms < @mtr_paths_cache_ttl_ms and is_list(paths) ->
        {:ok, paths, socket}

      _ ->
        case load_mtr_paths() do
          {:ok, paths} ->
            {:ok, paths, assign(socket, :mtr_paths_cache, %{at_ms: now_ms, paths: paths})}

          :error ->
            {:error, assign(socket, :mtr_paths_cache, nil)}
        end
    end
  end

  defp load_mtr_paths do
    case ServiceRadar.Dgraph.query_mtr_paths(@max_mtr_paths) do
      {:ok, paths} ->
        {:ok, Enum.map(paths, &Map.take(&1, @path_fields))}

      {:error, reason} ->
        Logger.warning("God View MTR path read failed: #{inspect(reason)}")
        :error
    end
  end
end
