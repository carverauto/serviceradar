defmodule ServiceRadar.PrefixTags.Loader do
  @moduledoc """
  Per-node loader for per-source prefix-tag LPM tries.

  Builds tries from active CNPG snapshots at boot (one trie per snapshot
  source), reloads a single source on `prefix_tags:snapshot` PubSub invalidation
  when metadata carries `:source`, and re-checks all sources after cluster
  reconnect (`:nodeup`). CNPG remains the source of truth.
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @pubsub_topic "prefix_tags:snapshot"
  @initial_load_retry_ms 5_000
  @initial_load_retry_max_ms 60_000

  @load_active_sql """
  SELECT
    host(p.prefix) || '/' || masklen(p.prefix) AS prefix,
    p.tags,
    p.vrf,
    p.site,
    p.role,
    p.tenant,
    p.status,
    s.source,
    s.id AS snapshot_id,
    s.promoted_at
  FROM platform.prefix_tags p
  JOIN platform.prefix_tag_snapshots s ON s.id = p.snapshot_id
  WHERE s.is_active = TRUE
  """

  @load_active_for_source_sql """
  SELECT
    host(p.prefix) || '/' || masklen(p.prefix) AS prefix,
    p.tags,
    p.vrf,
    p.site,
    p.role,
    p.tenant,
    p.status,
    s.source,
    s.id AS snapshot_id,
    s.promoted_at
  FROM platform.prefix_tags p
  JOIN platform.prefix_tag_snapshots s ON s.id = p.snapshot_id
  WHERE s.is_active = TRUE AND s.source = $1
  """

  @type state :: %{
          loaded_at: DateTime.t() | nil,
          sources: %{String.t() => map()},
          last_error: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Topic used for snapshot invalidation broadcasts."
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc """
  Broadcast a snapshot invalidation so every node reloads from CNPG.

  Prefer including `%{source: "netbox"}` so peers rebuild only that source.
  """
  @spec broadcast_invalidation(map()) :: :ok | {:error, term()}
  def broadcast_invalidation(metadata \\ %{}) when is_map(metadata) do
    if pubsub_available?() do
      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        @pubsub_topic,
        {:prefix_tags_snapshot_changed, metadata}
      )
    else
      :ok
    end
  end

  @doc "Force a full reload from CNPG on this node (synchronous)."
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, {:reload, :all}, to_timeout(second: 60))
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Force a single-source reload from CNPG on this node (synchronous)."
  @spec reload(String.t()) :: :ok | {:error, term()}
  def reload(source) when is_binary(source) do
    GenServer.call(__MODULE__, {:reload, source}, to_timeout(second: 60))
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Current loader status (for ops/debug)."
  @spec status() :: state() | {:error, term()}
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, reason -> {:error, reason}
  end

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    if pubsub_available?() do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, @pubsub_topic)
    end

    _ = :net_kernel.monitor_nodes(true, [:nodedown_reason])

    state = %{
      loaded_at: nil,
      sources: %{},
      last_error: nil
    }

    if Keyword.get(opts, :load_on_init, true) do
      {:ok, state, {:continue, :initial_load}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:initial_load, state) do
    state = do_reload(state, :all)
    # External sources (provider/ti/dns-policy) are compiled from other tables,
    # not platform.prefix_tags — reload them after snapshot-backed sources.
    _ = reload_all_external_sources()
    state = maybe_schedule_initial_retry(state, @initial_load_retry_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call({:reload, source}, _from, state) do
    new_state = do_reload(state, source)
    reply = if new_state.last_error, do: {:error, new_state.last_error}, else: :ok
    {:reply, reply, new_state}
  end

  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:retry_initial_load, delay_ms}, state) when is_integer(delay_ms) do
    if is_nil(state.loaded_at) do
      Logger.info("PrefixTags.Loader retrying initial load after failure")
      state = do_reload(state, :all)
      _ = reload_all_external_sources()
      next_delay = min(delay_ms * 2, @initial_load_retry_max_ms)
      state = maybe_schedule_initial_retry(state, next_delay)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:prefix_tags_snapshot_changed, meta}, state) when is_map(meta) do
    source = Map.get(meta, :source) || Map.get(meta, "source")

    Logger.info("PrefixTags.Loader reloading after snapshot invalidation", source: inspect(source))

    cond do
      is_binary(source) and external_source?(source) ->
        _ = reload_external_source(source)
        {:noreply, state}

      is_binary(source) and source != "" ->
        {:noreply, do_reload(state, source)}

      true ->
        state = do_reload(state, :all)
        _ = reload_all_external_sources()
        {:noreply, state}
    end
  end

  def handle_info({:prefix_tags_snapshot_changed, _meta}, state) do
    state = do_reload(state, :all)
    _ = reload_all_external_sources()
    {:noreply, state}
  end

  def handle_info({:nodeup, _node, _info}, state) do
    Logger.debug("PrefixTags.Loader re-checking active snapshots after nodeup")
    {:noreply, do_reload(state, :all)}
  end

  def handle_info({:nodeup, _node}, state) do
    {:noreply, do_reload(state, :all)}
  end

  def handle_info({:nodedown, _node, _info}, state), do: {:noreply, state}
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- load path -------------------------------------------------------------

  defp do_reload(state, scope) do
    started = System.monotonic_time(:microsecond)

    case fetch_active_rows(scope) do
      {:ok, rows_by_source, snapshot_ids_by_source} ->
        sources_meta =
          Map.new(rows_by_source, fn {source, rows} ->
            version = Store.put_rows(source, rows)
            stats = Store.stats(source)

            {source,
             %{
               version: version,
               row_count: length(rows),
               snapshot_ids: Map.get(snapshot_ids_by_source, source, []),
               stats: stats,
               loaded_at: DateTime.utc_now()
             }}
          end)

        # Drop tries for snapshot-backed sources that are no longer active.
        # External materializers (provider/ti/dns-policy) are never cleared here.
        sources_meta =
          case scope do
            source when is_binary(source) ->
              if Map.has_key?(sources_meta, source) do
                sources_meta
              else
                unless external_source?(source), do: Store.clear(source)

                Map.put(sources_meta, source, %{
                  version: nil,
                  row_count: 0,
                  snapshot_ids: [],
                  stats: %{ipv4_prefixes: 0, ipv6_prefixes: 0, total_prefixes: 0},
                  loaded_at: DateTime.utc_now()
                })
              end

            :all ->
              clear_stale_snapshot_sources(Map.keys(sources_meta))
              sources_meta
          end

        duration_us = System.monotonic_time(:microsecond) - started
        agg = Store.stats()
        total_rows = sources_meta |> Map.values() |> Enum.map(& &1.row_count) |> Enum.sum()

        emit_rebuild_telemetry(agg, duration_us, total_rows, :ok, scope)

        Logger.info(
          "PrefixTags.Loader installed sources=#{inspect(Map.keys(sources_meta))} " <>
            "rows=#{total_rows} total_prefixes=#{agg.total_prefixes} duration_us=#{duration_us}"
        )

        merged_sources =
          case scope do
            :all -> sources_meta
            source when is_binary(source) -> Map.merge(state.sources, sources_meta)
          end

        %{
          state
          | loaded_at: DateTime.utc_now(),
            sources: merged_sources,
            last_error: nil
        }

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - started
        message = Exception.message(reason)

        if is_nil(state.loaded_at) and scope == :all do
          Store.clear()
        end

        emit_rebuild_telemetry(Store.stats(), duration_us, 0, :error, scope)

        Logger.warning("PrefixTags.Loader failed to load active prefixes: #{message}",
          source: inspect(scope)
        )

        %{state | last_error: message}
    end
  end

  defp fetch_active_rows(:all) do
    case SQL.query(Repo, @load_active_sql, []) do
      {:ok, result} -> parse_rows(result)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp fetch_active_rows(source) when is_binary(source) do
    case SQL.query(Repo, @load_active_for_source_sql, [source]) do
      {:ok, result} -> parse_rows(result)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp parse_rows(%{rows: rows, columns: columns}) do
    col_index = columns |> Enum.with_index() |> Map.new()

    parsed =
      Enum.map(rows, fn row ->
        tags = normalize_tags(Enum.at(row, col_index["tags"]))

        %{
          prefix: Enum.at(row, col_index["prefix"]),
          tags: tags,
          vrf: Enum.at(row, col_index["vrf"]),
          site: Enum.at(row, col_index["site"]),
          role: Enum.at(row, col_index["role"]),
          tenant: Enum.at(row, col_index["tenant"]),
          status: Enum.at(row, col_index["status"]),
          source: Enum.at(row, col_index["source"])
        }
      end)

    by_source = Enum.group_by(parsed, & &1.source)

    snapshot_ids_by_source =
      rows
      |> Enum.group_by(&Enum.at(&1, col_index["source"]))
      |> Map.new(fn {source, source_rows} ->
        ids =
          source_rows
          |> Enum.map(&Enum.at(&1, col_index["snapshot_id"]))
          |> Enum.uniq()
          |> Enum.map(&to_string/1)

        {source, ids}
      end)

    {:ok, by_source, snapshot_ids_by_source}
  end

  defp normalize_tags(nil), do: []
  defp normalize_tags(tags) when is_list(tags), do: Enum.map(tags, &to_string/1)

  defp normalize_tags(tags) when is_map(tags) do
    tags |> Map.values() |> Enum.map(&to_string/1)
  end

  defp normalize_tags(tag) when is_binary(tag), do: [tag]
  defp normalize_tags(_), do: []

  defp emit_rebuild_telemetry(stats, duration_us, row_count, outcome, scope) do
    :telemetry.execute(
      [:serviceradar, :prefix_tags, :rebuild],
      %{
        duration_us: duration_us,
        row_count: row_count,
        ipv4_prefixes: stats.ipv4_prefixes,
        ipv6_prefixes: stats.ipv6_prefixes,
        total_prefixes: stats.total_prefixes
      },
      %{outcome: outcome, scope: scope}
    )
  end

  # Sources compiled from tables other than prefix_tag_snapshots/prefix_tags.
  # Invalidating these must re-run the materializer, never a prefix_tags SELECT
  # (which would be empty and wipe the trie).
  @external_source_modules %{
    "provider" => ServiceRadar.PrefixTags.ProviderSource,
    "ti" => ServiceRadar.PrefixTags.ThreatIntelSource,
    "dns-policy" => ServiceRadar.PrefixTags.DnsPolicySource
  }

  defp external_source?(source), do: Map.has_key?(@external_source_modules, source)

  defp clear_stale_snapshot_sources(active_sources) when is_list(active_sources) do
    active = MapSet.new(active_sources)

    Store.sources()
    |> Enum.reject(&external_source?/1)
    |> Enum.reject(&MapSet.member?(active, &1))
    |> Enum.each(fn stale ->
      Logger.info("PrefixTags.Loader clearing deactivated snapshot source", source: stale)
      Store.clear(stale)
    end)

    :ok
  end

  defp maybe_schedule_initial_retry(%{loaded_at: nil, last_error: err} = state, delay_ms)
       when is_binary(err) and is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), {:retry_initial_load, delay_ms}, delay_ms)
    state
  end

  defp maybe_schedule_initial_retry(state, _delay_ms), do: state

  defp reload_all_external_sources do
    Enum.each(Map.keys(@external_source_modules), &reload_external_source/1)
    :ok
  end

  defp reload_external_source(source) when is_binary(source) do
    case Map.get(@external_source_modules, source) do
      nil ->
        :ok

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :reload, 1) do
          # broadcast?: false — we are already handling a broadcast (or boot).
          case mod.reload(broadcast?: false) do
            {:ok, count} ->
              Logger.debug("PrefixTags.Loader external source reloaded",
                source: source,
                rows: count
              )

              :ok

            {:error, reason} ->
              Logger.debug("PrefixTags.Loader external source reload skipped",
                source: source,
                reason: inspect(reason)
              )

              :ok
          end
        else
          :ok
        end
    end
  rescue
    e ->
      Logger.debug("PrefixTags.Loader external source reload failed",
        source: source,
        error: Exception.message(e)
      )

      :ok
  end

  defp pubsub_available? do
    Process.whereis(ServiceRadar.PubSub) != nil
  end
end
