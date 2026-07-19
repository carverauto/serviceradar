defmodule ServiceRadar.PrefixTags.Loader do
  @moduledoc """
  Per-node loader for the prefix-tag LPM trie.

  Builds the trie from active CNPG snapshots at boot, reloads on
  `prefix_tags:snapshot` PubSub invalidation, and re-checks after cluster
  reconnect (`:nodeup`). CNPG remains the source of truth; the trie is a
  derived cache stored in `:persistent_term` via `ServiceRadar.PrefixTags.Store`.
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @pubsub_topic "prefix_tags:snapshot"
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

  @type state :: %{
          loaded_at: DateTime.t() | nil,
          snapshot_ids: [String.t()],
          row_count: non_neg_integer(),
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

  Call after promoting a snapshot (import worker or manual promote).
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

  @doc "Force a reload from CNPG on this node (synchronous)."
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload, to_timeout(second: 60))
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
      snapshot_ids: [],
      row_count: 0,
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
    {:noreply, do_reload(state)}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    new_state = do_reload(state)
    reply = if new_state.last_error, do: {:error, new_state.last_error}, else: :ok
    {:reply, reply, new_state}
  end

  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:prefix_tags_snapshot_changed, _meta}, state) do
    Logger.info("PrefixTags.Loader reloading after snapshot invalidation")
    {:noreply, do_reload(state)}
  end

  def handle_info({:nodeup, _node, _info}, state) do
    Logger.debug("PrefixTags.Loader re-checking active snapshot after nodeup")
    {:noreply, do_reload(state)}
  end

  def handle_info({:nodeup, _node}, state) do
    {:noreply, do_reload(state)}
  end

  def handle_info({:nodedown, _node, _info}, state), do: {:noreply, state}
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- load path -------------------------------------------------------------

  defp do_reload(state) do
    started = System.monotonic_time(:microsecond)

    case fetch_active_rows() do
      {:ok, rows, snapshot_ids} ->
        version = Store.put_rows(rows)
        duration_us = System.monotonic_time(:microsecond) - started
        stats = Store.stats()

        emit_rebuild_telemetry(stats, duration_us, length(rows), :ok)

        Logger.info(
          "PrefixTags.Loader installed trie version=#{version} rows=#{length(rows)} " <>
            "ipv4=#{stats.ipv4_prefixes} ipv6=#{stats.ipv6_prefixes} " <>
            "duration_us=#{duration_us}"
        )

        %{
          state
          | loaded_at: DateTime.utc_now(),
            snapshot_ids: snapshot_ids,
            row_count: length(rows),
            last_error: nil
        }

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - started
        message = Exception.message(reason)

        # Keep previous trie if any; only clear when nothing was ever loaded.
        if is_nil(state.loaded_at) do
          Store.clear()
        end

        emit_rebuild_telemetry(Store.stats(), duration_us, 0, :error)

        Logger.warning("PrefixTags.Loader failed to load active prefixes: #{message}")

        %{state | last_error: message}
    end
  end

  defp fetch_active_rows do
    case SQL.query(Repo, @load_active_sql, []) do
      {:ok, %{rows: rows, columns: columns}} ->
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

        snapshot_ids =
          rows
          |> Enum.map(&Enum.at(&1, col_index["snapshot_id"]))
          |> Enum.uniq()
          |> Enum.map(&to_string/1)

        {:ok, parsed, snapshot_ids}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp normalize_tags(nil), do: []
  defp normalize_tags(tags) when is_list(tags), do: Enum.map(tags, &to_string/1)

  defp normalize_tags(tags) when is_map(tags) do
    # Defensive: some JSONB paths return objects; ignore keys, keep values.
    tags |> Map.values() |> Enum.map(&to_string/1)
  end

  defp normalize_tags(tag) when is_binary(tag), do: [tag]
  defp normalize_tags(_), do: []

  defp emit_rebuild_telemetry(stats, duration_us, row_count, outcome) do
    :telemetry.execute(
      [:serviceradar, :prefix_tags, :rebuild],
      %{
        duration_us: duration_us,
        row_count: row_count,
        ipv4_prefixes: stats.ipv4_prefixes,
        ipv6_prefixes: stats.ipv6_prefixes,
        total_prefixes: stats.total_prefixes
      },
      %{outcome: outcome}
    )
  end

  defp pubsub_available? do
    Process.whereis(ServiceRadar.PubSub) != nil
  end
end
