defmodule ServiceRadar.PrefixTags.Loader do
  @moduledoc """
  Per-node loader for per-source prefix-tag LPM tries.

  Builds tries from active CNPG snapshots at boot (one trie per snapshot
  source), reloads a single source on `prefix_tags:snapshot` PubSub invalidation
  when metadata carries `:source`, and re-checks snapshot-backed sources after
  cluster reconnect (`:nodeup`). CNPG remains the source of truth.
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.ExternalSources
  alias ServiceRadar.PrefixTags.SnapshotReader
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @pubsub_topic "prefix_tags:snapshot"
  @status_key {__MODULE__, :status}
  @initial_load_retry_ms 5_000
  @initial_load_retry_max_ms 60_000
  # Re-emit snapshot age/freshness even when reloads fail so last-value gauges
  # age and sources without a durable timestamp remain observable.
  @snapshot_age_tick_ms 60_000

  @load_active_sql """
  SELECT DISTINCT source FROM platform.prefix_tag_snapshots WHERE is_active = TRUE ORDER BY source
  """

  @snapshot_meta_sql """
  SELECT id::text, promoted_at FROM platform.prefix_tag_snapshots
  WHERE is_active = TRUE AND source = $1 ORDER BY id
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
  FROM platform.prefix_tag_snapshots s
  LEFT JOIN platform.prefix_tags p ON p.snapshot_id = s.id
  WHERE s.is_active = TRUE AND s.source = $1
  ORDER BY p.prefix, p.vrf
  """

  @type state :: %{
          loaded_at: DateTime.t() | nil,
          sources: %{String.t() => map()},
          last_error: String.t() | nil,
          external_errors: %{String.t() => String.t()},
          initial_boot_complete?: boolean()
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
    GenServer.call(__MODULE__, {:reload, :all}, to_timeout(minute: 1))
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Force a single-source reload from CNPG on this node (synchronous)."
  @spec reload(String.t()) :: :ok | {:error, term()}
  def reload(source) when is_binary(source) do
    GenServer.call(__MODULE__, {:reload, source}, to_timeout(minute: 1))
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Current loader status (for ops/debug)."
  @spec status(GenServer.server()) :: state() | {:error, term()}
  def status(server \\ __MODULE__) do
    if server == __MODULE__ do
      case :persistent_term.get(@status_key, :not_found) do
        :not_found ->
          GenServer.call(server, :status)

        state ->
          state
      end
    else
      GenServer.call(server, :status)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  def put_status_for_test(status) when is_map(status) do
    :persistent_term.put(@status_key, status)
  end

  @doc false
  def clear_status_for_test do
    :persistent_term.erase(@status_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    if pubsub_available?() do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, @pubsub_topic)
    end

    _ = :net_kernel.monitor_nodes(true, [:nodedown_reason])
    schedule_snapshot_age_tick()

    name = Keyword.get(opts, :name, __MODULE__)
    reload_runner = Keyword.get(opts, :reload_runner, &execute_reload/2)

    state = %{
      name: name,
      reload_runner: reload_runner,
      loaded_at: nil,
      sources: %{},
      last_error: nil,
      external_errors: %{},
      initial_boot_complete?: false,
      reload_task: nil,
      reload_target: nil,
      waiters: []
    }

    publish_status(state)

    if Keyword.get(opts, :load_on_init, true) do
      {:ok, state, {:continue, :initial_load}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:initial_load, state) do
    state = do_reload(state, :all)
    state = reload_all_external_sources(state)
    state = finalize_boot_state(state)
    publish_status(state)
    state = maybe_schedule_initial_retry(state, @initial_load_retry_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call({:reload, target}, from, state) do
    {:noreply, start_reload_task(state, target, from)}
  end

  def handle_call(:status, _from, state) do
    clean_state = status_snapshot(state)
    publish_status(state)
    {:reply, clean_state, state}
  end

  @impl true
  def handle_info({ref, {new_state, reply}}, %{reload_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    merged_state =
      state
      |> Map.put(:loaded_at, new_state.loaded_at)
      |> Map.put(:sources, new_state.sources)
      |> Map.put(:last_error, new_state.last_error)
      |> Map.put(:external_errors, new_state.external_errors)
      |> Map.put(:initial_boot_complete?, new_state.initial_boot_complete?)
      |> publish_status()

    completed_target = state.reload_target

    {satisfied, remaining} =
      if completed_target == :all do
        {state.waiters, []}
      else
        Enum.split_with(state.waiters, fn {_from, target} -> target == completed_target end)
      end

    for {from, target} <- satisfied, not is_nil(from) do
      GenServer.reply(from, reply_for_waiter(new_state, completed_target, target, reply))
    end

    state_after_reply = %{merged_state | reload_task: nil, reload_target: nil, waiters: remaining}

    case remaining do
      [] ->
        {:noreply, state_after_reply}

      [{next_from, next_target} | rest] ->
        st = %{state_after_reply | waiters: rest}
        {:noreply, start_reload_task(st, next_target, next_from)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reload_task: %Task{ref: ref}} = state) do
    Logger.warning("PrefixTags.Loader reload task died: #{inspect(reason)}")
    merged_state = publish_status(%{state | last_error: inspect(reason)})

    for {from, _target} <- state.waiters, not is_nil(from) do
      GenServer.reply(from, {:error, reason})
    end

    {:noreply, %{merged_state | reload_task: nil, reload_target: nil, waiters: []}}
  end

  def handle_info({:retry_initial_load, delay_ms}, state) when is_integer(delay_ms) do
    # Boot complete only when snapshot :all succeeded AND externals have no
    # pending errors. Targeted reloads must not cancel this loop.
    if state.initial_boot_complete? do
      {:noreply, state}
    else
      Logger.info("PrefixTags.Loader retrying initial load after failure")
      state = start_reload_task(state, :all, nil)
      next_delay = min(delay_ms * 2, @initial_load_retry_max_ms)
      state = maybe_schedule_initial_retry(state, next_delay)
      {:noreply, state}
    end
  end

  def handle_info({:prefix_tags_snapshot_changed, meta}, state) when is_map(meta) do
    if locally_reloaded?(meta) do
      Logger.debug("PrefixTags.Loader skipping locally completed snapshot reload",
        source: inspect(Map.get(meta, :source) || Map.get(meta, "source"))
      )

      {:noreply, state}
    else
      source = Map.get(meta, :source) || Map.get(meta, "source")

      Logger.info("PrefixTags.Loader reloading after snapshot invalidation",
        source: inspect(source)
      )

      if is_binary(source) and source != "" do
        {:noreply, start_reload_task(state, source, nil)}
      else
        {:noreply, start_reload_task(state, :all, nil)}
      end
    end
  end

  def handle_info({:prefix_tags_snapshot_changed, _meta}, state) do
    {:noreply, start_reload_task(state, :all, nil)}
  end

  def handle_info({:nodeup, _node, _info}, state) do
    Logger.debug("PrefixTags.Loader re-checking active snapshots after nodeup")
    {:noreply, start_reload_task(state, :snapshots_only, nil)}
  end

  def handle_info({:nodeup, _node}, state) do
    {:noreply, start_reload_task(state, :snapshots_only, nil)}
  end

  def handle_info({:nodedown, _node, _info}, state), do: {:noreply, state}
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  def handle_info(:emit_snapshot_ages, state) do
    # Advance gauges even when reloads are failing (retained snapshot_at).
    emit_snapshot_age_for_sources(state.sources)
    schedule_snapshot_age_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_reload_task(%{reload_task: nil} = state, target, from) do
    runner = state.reload_runner
    task_input_state = Map.drop(state, [:reload_task, :reload_target, :waiters])

    task =
      Task.async(fn ->
        try do
          runner.(task_input_state, target)
        rescue
          e ->
            msg = Exception.message(e)
            Logger.warning("PrefixTags.Loader reload failed: #{msg}", source: inspect(target))
            {Map.put(task_input_state, :last_error, msg), {:error, msg}}
        catch
          :exit, reason ->
            msg = inspect(reason)
            Logger.warning("PrefixTags.Loader reload exited: #{msg}", source: inspect(target))
            {Map.put(task_input_state, :last_error, msg), {:error, reason}}
        end
      end)

    waiters = if from, do: [{from, target} | state.waiters], else: state.waiters
    %{state | reload_task: task, reload_target: target, waiters: waiters}
  end

  defp start_reload_task(state, target, from) do
    if is_nil(from) and Enum.any?(state.waiters, fn {_queued_from, queued} -> queued == target end) do
      state
    else
      %{state | waiters: [{from, target} | state.waiters]}
    end
  end

  defp execute_reload(state, :all) do
    new_state = do_reload(state, :all)
    new_state = reload_all_external_sources(new_state)
    new_state = finalize_boot_state(new_state)
    reply = reload_reply(new_state, :all)
    {new_state, reply}
  end

  defp execute_reload(state, :snapshots_only) do
    new_state = do_reload(state, :all)
    {new_state, :ok}
  end

  defp execute_reload(state, source) when is_binary(source) do
    if external_source?(source) do
      {st, result} = reload_external_source(state, source)
      {st, result}
    else
      st = do_reload(state, source)
      {st, reload_reply(st, source)}
    end
  end

  defp reply_for_waiter(_new_state, completed, target, reply) when completed == target do
    reply
  end

  defp reply_for_waiter(new_state, :all, target, _reply) when is_binary(target) do
    reload_reply(new_state, target)
  end

  defp reply_for_waiter(_new_state, :all, :snapshots_only, _reply), do: :ok

  defp publish_status(state) do
    if Map.get(state, :name) == __MODULE__ do
      :persistent_term.put(@status_key, status_snapshot(state))
    end

    state
  end

  defp status_snapshot(state) do
    Map.take(state, [
      :loaded_at,
      :sources,
      :last_error,
      :external_errors,
      :initial_boot_complete?
    ])
  end

  # --- load path -------------------------------------------------------------

  defp do_reload(state, scope) do
    started = System.monotonic_time(:microsecond)

    case load_active_sources(scope) do
      {:ok, sources_meta} ->
        # Drop tries for snapshot-backed sources that are no longer active.
        # External materializers (provider/ti/dns-policy) are never cleared here.
        sources_meta =
          case scope do
            source when is_binary(source) ->
              if Map.has_key?(sources_meta, source) do
                sources_meta
              else
                if !external_source?(source), do: Store.clear(source)

                prev_at = get_in(state.sources, [source, :snapshot_at])

                Map.put(sources_meta, source, %{
                  version: nil,
                  row_count: 0,
                  snapshot_ids: [],
                  stats: %{ipv4_prefixes: 0, ipv6_prefixes: 0, total_prefixes: 0},
                  loaded_at: DateTime.utc_now(),
                  snapshot_at: prev_at
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
        emit_snapshot_age_for_sources(sources_meta)

        log_install(Map.keys(sources_meta), total_rows, agg.total_prefixes, duration_us, scope)

        merged_sources =
          case scope do
            :all ->
              # Keep external-source freshness across full snapshot reloads.
              merge_preserving_external_freshness(state.sources, sources_meta)

            source when is_binary(source) ->
              Map.merge(state.sources, sources_meta)
          end

        # Mark boot complete only after a successful full (:all) load so a
        # targeted PubSub reload cannot cancel the initial-recovery timer.
        loaded_at =
          case scope do
            :all -> DateTime.utc_now()
            _ -> state.loaded_at
          end

        %{
          state
          | loaded_at: loaded_at,
            sources: merged_sources,
            last_error: nil
        }

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - started
        message = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)

        emit_rebuild_telemetry(Store.stats(), duration_us, 0, :error, scope)
        # Still emit ages from retained snapshot_at so the gauge advances.
        emit_snapshot_age_for_sources(state.sources)

        Logger.warning("PrefixTags.Loader failed to load active prefixes: #{message}",
          source: inspect(scope)
        )

        %{state | last_error: message}
    end
  end

  defp load_active_sources(scope) do
    sources =
      case scope do
        :all -> Enum.map(SQL.query!(Repo, @load_active_sql, []).rows, &hd/1)
        source when is_binary(source) -> [source]
      end

    Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, acc} ->
      case load_snapshot_source(source) do
        {:ok, %{active?: false}} -> {:cont, {:ok, acc}}
        {:ok, metadata} -> {:cont, {:ok, Map.put(acc, source, metadata)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  rescue
    e -> {:error, e}
  end

  @doc "Load one snapshot-backed source without requiring the Loader process."
  def load_snapshot_source(source) when is_binary(source) do
    with {:ok, result} <- Store.put_stream(source, fn -> snapshot_rows(source) end) do
      {:ok, Map.merge(result, %{stats: Store.stats(source), loaded_at: DateTime.utc_now()})}
    end
  rescue
    e -> {:error, e}
  end

  defp snapshot_rows(source) do
    metadata = SQL.query!(Repo, @snapshot_meta_sql, [source]).rows
    ids = Enum.map(metadata, &hd/1)

    times =
      metadata |> Enum.map(fn [_, time] -> normalize_datetime(time) end) |> Enum.reject(&is_nil/1)

    snapshot_at = Enum.min(times, DateTime, fn -> nil end)

    rows =
      @load_active_for_source_sql
      |> SnapshotReader.stream([source])
      |> Stream.flat_map(fn batch ->
        {:ok, by_source, _metadata} = parse_active_rows(batch)
        Map.get(by_source, source, [])
      end)

    {rows, %{snapshot_ids: ids, snapshot_at: snapshot_at, active?: ids != []}}
  end

  defp merge_preserving_external_freshness(old_sources, new_sources) do
    Enum.reduce(old_sources, new_sources, fn {source, meta}, acc ->
      if external_source?(source) and not Map.has_key?(acc, source) do
        Map.put(acc, source, meta)
      else
        acc
      end
    end)
  end

  @doc false
  @spec parse_active_rows(map()) :: {:ok, %{String.t() => [map()]}, map()}
  def parse_active_rows(%{rows: rows, columns: columns}) do
    col_index = columns |> Enum.with_index() |> Map.new()

    parsed =
      Enum.flat_map(rows, fn row ->
        prefix = Enum.at(row, col_index["prefix"])
        source = Enum.at(row, col_index["source"])

        if is_binary(prefix) and is_binary(source) do
          [
            %{
              prefix: prefix,
              tags: normalize_tags(Enum.at(row, col_index["tags"])),
              vrf: Enum.at(row, col_index["vrf"]),
              site: Enum.at(row, col_index["site"]),
              role: Enum.at(row, col_index["role"]),
              tenant: Enum.at(row, col_index["tenant"]),
              status: Enum.at(row, col_index["status"]),
              source: source
            }
          ]
        else
          []
        end
      end)

    source_names =
      rows
      |> Enum.map(&Enum.at(&1, col_index["source"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    by_source =
      Enum.reduce(source_names, Enum.group_by(parsed, & &1.source), fn source, acc ->
        Map.put_new(acc, source, [])
      end)

    snapshot_ids_by_source =
      rows
      |> Enum.group_by(&Enum.at(&1, col_index["source"]))
      |> Enum.reduce(%{}, fn {source, source_rows}, acc ->
        if is_binary(source) do
          ids =
            source_rows
            |> Enum.map(&Enum.at(&1, col_index["snapshot_id"]))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.map(&to_string/1)

          promoted_ats =
            source_rows
            |> Enum.map(&Enum.at(&1, col_index["promoted_at"]))
            |> Enum.map(&normalize_datetime/1)
            |> Enum.reject(&is_nil/1)

          # Oldest promotion among active snapshots for this source (conservative age).
          snapshot_at =
            case promoted_ats do
              [] -> nil
              dts -> Enum.min(dts, DateTime)
            end

          acc
          |> Map.put(source, ids)
          |> Map.put({:promoted_at, source}, snapshot_at)
        else
          acc
        end
      end)

    {:ok, by_source, snapshot_ids_by_source}
  end

  defp normalize_datetime(%DateTime{} = dt), do: dt

  defp normalize_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp normalize_datetime(_), do: nil

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

  defp emit_snapshot_age_for_sources(sources_meta) when is_map(sources_meta) do
    Enum.each(sources_meta, fn {source, meta} ->
      case Map.get(meta, :snapshot_at) do
        %DateTime{} = dt ->
          :telemetry.execute(
            [:serviceradar, :prefix_tags, :snapshot_age],
            %{age_seconds: max(DateTime.diff(DateTime.utc_now(), dt, :second), 0)},
            %{source: source}
          )

          emit_snapshot_freshness(source, 1)

        _ ->
          emit_snapshot_freshness(source, 0)
      end
    end)
  rescue
    _ -> :ok
  end

  defp emit_snapshot_age_for_sources(_), do: :ok

  defp emit_snapshot_freshness(source, known) when known in [0, 1] do
    :telemetry.execute(
      [:serviceradar, :prefix_tags, :snapshot_freshness],
      %{known: known},
      %{source: source}
    )
  end

  defp log_install(source_names, total_rows, total_prefixes, duration_us, scope) do
    message =
      "PrefixTags.Loader installed sources=#{inspect(source_names)} " <>
        "rows=#{total_rows} total_prefixes=#{total_prefixes} duration_us=#{duration_us}"

    # Empty snapshot reloads (no active CNPG rows) are expected when only
    # external tries (ti/provider/dns-policy) are populated. Those used to
    # spam info on every PubSub/nodeup bounce.
    if source_names == [] and total_rows == 0 do
      Logger.debug(message, source: inspect(scope))
    else
      Logger.info(message)
    end
  end

  defp locally_reloaded?(metadata) do
    (Map.get(metadata, :reloaded_on) || Map.get(metadata, "reloaded_on")) == node()
  end

  # Sources compiled from tables other than prefix_tag_snapshots/prefix_tags.
  # Invalidating these must re-run the materializer, never a prefix_tags SELECT
  # (which would be empty and wipe the trie). See PrefixTags.ExternalSources.
  defp external_source?(source), do: ExternalSources.external?(source)

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

  defp finalize_boot_state(state) do
    complete? =
      is_nil(state.last_error) and map_size(state.external_errors) == 0 and
        not is_nil(state.loaded_at)

    %{state | initial_boot_complete?: complete?}
  end

  defp maybe_schedule_initial_retry(%{initial_boot_complete?: false} = state, delay_ms)
       when is_integer(delay_ms) and delay_ms > 0 do
    # Retry while snapshot load failed or any external materializer is unhealthy.
    if is_binary(state.last_error) or map_size(state.external_errors) > 0 do
      Process.send_after(self(), {:retry_initial_load, delay_ms}, delay_ms)
    end

    state
  end

  defp maybe_schedule_initial_retry(state, _delay_ms), do: state

  defp reload_reply(state, :all) do
    cond do
      is_binary(state.last_error) ->
        {:error, state.last_error}

      map_size(state.external_errors) > 0 ->
        {:error, {:external_errors, state.external_errors}}

      true ->
        :ok
    end
  end

  defp reload_reply(state, source) when is_binary(source) do
    cond do
      err = Map.get(state.external_errors, source) ->
        {:error, err}

      is_binary(state.last_error) and not external_source?(source) ->
        {:error, state.last_error}

      true ->
        :ok
    end
  end

  defp reload_all_external_sources(state) do
    Enum.reduce(Map.keys(ExternalSources.by_name()), state, fn source, acc ->
      {acc, _} = reload_external_source(acc, source)
      acc
    end)
  end

  defp reload_external_source(state, source) when is_binary(source) do
    if ExternalSources.enabled?() do
      reload_enabled_external_source(state, source)
    else
      {clear_external_error(state, source), :ok}
    end
  end

  defp reload_enabled_external_source(state, source) do
    case ExternalSources.module_for(source) do
      nil ->
        {clear_external_error(state, source), :ok}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :reload, 1) do
          # broadcast?: false — we are already handling a broadcast (or boot).
          case mod.reload(broadcast?: false) do
            {:ok, %{row_count: count, snapshot_at: snapshot_at}}
            when is_integer(count) and count >= 0 ->
              Logger.debug("PrefixTags.Loader external source reloaded",
                source: source,
                rows: count
              )

              now = DateTime.utc_now()
              state = clear_external_error(state, source)

              state = %{
                state
                | sources:
                    Map.put(state.sources, source, %{
                      row_count: count,
                      loaded_at: now,
                      snapshot_at: snapshot_at,
                      stats: Store.stats(source)
                    })
              }

              emit_snapshot_age_for_sources(Map.take(state.sources, [source]))
              {state, :ok}

            {:ok, result} ->
              msg = "invalid_reload_result: #{inspect(result)}"

              Logger.warning("PrefixTags.Loader external source returned invalid result",
                source: source,
                result: inspect(result)
              )

              {put_external_error(state, source, msg), {:error, msg}}

            {:error, reason} ->
              msg = inspect(reason)

              Logger.warning("PrefixTags.Loader external source reload failed",
                source: source,
                reason: msg
              )

              # Keep prior snapshot_at so periodic age ticks keep advancing.
              emit_snapshot_age_for_sources(Map.take(state.sources, [source]))
              {put_external_error(state, source, msg), {:error, msg}}
          end
        else
          msg = "module_unavailable"
          {put_external_error(state, source, msg), {:error, msg}}
        end
    end
  rescue
    e ->
      msg = Exception.message(e)

      Logger.warning("PrefixTags.Loader external source reload crashed",
        source: source,
        error: msg
      )

      {put_external_error(state, source, msg), {:error, msg}}
  end

  defp put_external_error(state, source, msg) do
    %{state | external_errors: Map.put(state.external_errors || %{}, source, msg)}
  end

  defp clear_external_error(state, source) do
    %{state | external_errors: Map.delete(state.external_errors || %{}, source)}
  end

  defp schedule_snapshot_age_tick do
    Process.send_after(self(), :emit_snapshot_ages, @snapshot_age_tick_ms)
  end

  defp pubsub_available? do
    Process.whereis(ServiceRadar.PubSub) != nil
  end
end
