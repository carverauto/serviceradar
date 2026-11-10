defmodule ServiceRadar.Analytics.StarRocks.NodeMemory do
  @moduledoc """
  Holds every warehouse node to the memory budget ServiceRadar ships, and
  reports how much memory each node leaves outside StarRocks.

  ServiceRadar does not install StarRocks, and the people who run it do not
  tune it, so StarRocks' own defaults would apply everywhere. They leave a
  ServiceRadar warehouse with little room for queries and Stream Loads: the
  datacache memory tier, the primary-key index and the lake metadata cache
  each take a large share of the process limit and give it back only under
  pressure. So core sets these on each node through
  `information_schema.be_configs`:

    * `datacache_mem_size` -- `10%` (StarRocks default `20%`). StarRocks
      resolves it against the node's own process limit. On a shared-nothing
      backend it also caps the storage page cache.
    * `update_memory_limit_percent` -- `30` (default `60`), the primary-key
      index's share of the process limit.
    * `lake_metadata_cache_limit` -- shared-data compute nodes only:
      8% of the node's process limit, rounded down to 64 MiB and kept
      between 128 MiB and StarRocks' 2 GiB default. That is 512 MiB on a
      node with a 6.3 GiB process limit, which was enough for about 2,400
      tablets across three nodes.

  A key is written only when the node's live value differs, and only when
  `be_configs` reports it `MUTABLE` there. StarRocks 4.1.7 cannot change
  `update_memory_limit_percent` at runtime (later 4.1 builds can); such a key
  is reported as `:restart_required`, for the node's config file to carry.

  Runtime values do not survive a node restart, so this runs shortly after
  start and then every two minutes. It is best effort: a warehouse that does
  not answer, or a user without the `OPERATE` privilege `be_configs` needs, is
  logged and retried, and never holds up migrations or ingest. It runs under
  `ServiceRadar.Cluster.CoordinatorChildren`, so one core replica writes.

  ## Process limit and reserve

  `mem_limit` is not runtime-changeable, so it is reported, not set. A node's
  process limit is 90% of what `mem_limit` resolves to, and a percentage
  resolves against the memory the node detects (its cgroup limit in a
  container, otherwise the host's). From the `MemLimit` the Frontend reports
  and the configured percentage, `health/0` derives the detected memory and
  the reserve left under it. StarRocks allocates about 1.4 GB outside its
  memory tracker, so a reserve below 2.5 GiB is a warning: the kernel can
  kill the node before StarRocks refuses a query. An absolute `mem_limit`
  leaves the detected memory, and so the reserve, unknown.
  """

  use GenServer

  alias ServiceRadar.Analytics.StarRocks.MySQL

  require Logger

  @type query_fun :: (String.t() -> {:ok, map()} | {:error, term()})

  @table __MODULE__
  @mib 1_048_576
  @gib 1_073_741_824
  @reserve_warning_bytes 2 * @gib + 512 * @mib
  # GlobalEnv::_init_mem_tracker sizes the process tracker at 90% of mem_limit.
  @process_share_of_mem_limit 0.9
  @datacache_mem_size "10%"
  @update_memory_limit_percent "30"
  @metadata_cache_percent 8
  @metadata_cache_step 64 * @mib
  @metadata_cache_min 128 * @mib
  @metadata_cache_max 2 * @gib
  @config_keys ~w(mem_limit datacache_mem_size update_memory_limit_percent lake_metadata_cache_limit)

  @initial_delay_ms 30_000
  @retry_ms 30_000
  @interval_ms 120_000

  @doc "The reserve under a node's detected memory below which `health/0` warns."
  @spec reserve_warning_bytes() :: pos_integer()
  def reserve_warning_bytes, do: @reserve_warning_bytes

  @doc """
  The last report: `status` (`:ok`, `:warning`, `:pending` before the first
  pass, `:error` when the warehouse could not be read, `:not_running` where
  this process does not run), `checked_at`, `nodes` and human-readable
  `warnings`.
  """
  @spec health() :: map()
  def health do
    case :ets.whereis(@table) do
      :undefined -> %{status: :not_running}
      _table -> lookup_health()
    end
  end

  defp lookup_health do
    case :ets.lookup(@table, :health) do
      [{:health, health}] -> health
      [] -> %{status: :not_running}
    end
  rescue
    ArgumentError -> %{status: :not_running}
  end

  @doc """
  Reads every node's memory configs, writes the ones that differ from what
  ServiceRadar ships, and returns one report per node.
  """
  @spec converge(query_fun()) :: {:ok, [map()]} | {:error, term()}
  def converge(query) when is_function(query, 1) do
    with {:ok, nodes} <- nodes(query),
         {:ok, configs} <- configs(query) do
      {:ok, Enum.map(nodes, &converge_node(&1, Map.get(configs, &1.id, %{}), query))}
    end
  end

  @doc "Summarises `converge/1`'s node reports for `health/0`."
  @spec summarize([map()], DateTime.t()) :: map()
  def summarize(nodes, checked_at) do
    warnings = Enum.flat_map(nodes, &node_warnings/1)

    %{
      status: if(warnings == [], do: :ok, else: :warning),
      checked_at: checked_at,
      reserve_warning_bytes: @reserve_warning_bytes,
      nodes: nodes,
      warnings: warnings
    }
  end

  ## Reading the warehouse

  # A cluster with compute nodes and no backends is shared-data, the same rule
  # SchemaMigrator uses to pick a replication factor.
  defp nodes(query) do
    with {:ok, backends} <- list_nodes(query, "SHOW BACKENDS", "BackendId", :backend),
         {:ok, compute} <- list_nodes(query, "SHOW COMPUTE NODES", "ComputeNodeId", :compute_node) do
      shared_data = backends == [] and compute != []

      case backends ++ compute do
        [] -> {:error, :no_starrocks_node}
        nodes -> {:ok, Enum.map(nodes, &Map.put(&1, :shared_data, shared_data))}
      end
    end
  end

  defp list_nodes(query, sql, id_column, kind) do
    case query.(sql) do
      {:ok, %{columns: columns, rows: rows}} ->
        index = fn name -> Enum.find_index(columns, &(&1 == name)) end
        [id, host, alive, mem] = Enum.map([id_column, "IP", "Alive", "MemLimit"], index)

        {:ok,
         for row <- rows,
             node_id = integer(at(row, id)),
             is_integer(node_id) do
           %{
             id: node_id,
             kind: kind,
             host: at(row, host),
             alive: row |> at(alive) |> to_string() |> String.downcase() == "true",
             process_limit_bytes: parse_bytes(at(row, mem))
           }
         end}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configs(query) do
    names = Enum.map_join(@config_keys, ", ", &"'#{&1}'")

    sql =
      "SELECT BE_ID, NAME, VALUE, MUTABLE FROM information_schema.be_configs WHERE NAME IN (#{names})"

    case query.(sql) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.reduce(rows, %{}, fn [id, name, value, mutable | _], acc ->
           entry = %{value: to_string(value), mutable: truthy?(mutable)}
           Map.update(acc, integer(id), %{name => entry}, &Map.put(&1, name, entry))
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Converging one node

  defp converge_node(node, configs, query) do
    mem_limit = get_in(configs, ["mem_limit", :value])

    settings =
      if node.alive, do: Enum.map(targets(node), &setting(&1, node, configs, query)), else: []

    node
    |> Map.put(:mem_limit, mem_limit)
    |> Map.merge(reserve(mem_limit, node.process_limit_bytes))
    |> Map.put(:settings, settings)
  end

  @doc "The values ServiceRadar ships for a node, as `{key, value}` pairs."
  @spec targets(map()) :: [{String.t(), String.t()}]
  def targets(node) do
    [
      {"datacache_mem_size", @datacache_mem_size},
      {"update_memory_limit_percent", @update_memory_limit_percent}
      | metadata_cache_target(node)
    ]
  end

  defp metadata_cache_target(%{
         kind: :compute_node,
         shared_data: true,
         process_limit_bytes: limit
       })
       when is_integer(limit) and limit > 0 do
    bytes =
      (limit * @metadata_cache_percent)
      |> div(100 * @metadata_cache_step)
      |> Kernel.*(@metadata_cache_step)
      |> max(@metadata_cache_min)
      |> min(@metadata_cache_max)

    [{"lake_metadata_cache_limit", Integer.to_string(bytes)}]
  end

  defp metadata_cache_target(_node), do: []

  defp setting({name, target}, node, configs, query) do
    case Map.fetch(configs, name) do
      :error ->
        %{name: name, target: target, live: nil, state: :unsupported}

      {:ok, %{value: live, mutable: mutable}} ->
        base = %{name: name, target: target, live: live}

        cond do
          normalize(live) == normalize(target) -> Map.put(base, :state, :converged)
          not mutable -> Map.put(base, :state, :restart_required)
          true -> write(base, node, query)
        end
    end
  end

  defp write(setting, node, query) do
    sql =
      "UPDATE information_schema.be_configs SET VALUE = '#{setting.target}' " <>
        "WHERE NAME = '#{setting.name}' AND BE_ID = #{node.id}"

    case query.(sql) do
      {:ok, _result} -> Map.put(setting, :state, :applied)
      {:error, reason} -> Map.merge(setting, %{state: :failed, error: inspect(reason)})
    end
  end

  defp normalize(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()

    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  ## Reserve

  defp reserve(mem_limit, limit) when is_integer(limit) and limit > 0 do
    case percent(mem_limit) do
      pct when is_number(pct) and pct > 0 ->
        physical = detected_memory(limit, pct)
        reserve = physical - limit

        %{
          detected_memory_bytes: physical,
          reserve_bytes: reserve,
          reserve: if(reserve < @reserve_warning_bytes, do: :low, else: :ok)
        }

      _absolute_or_unknown ->
        unknown_reserve()
    end
  end

  defp reserve(_mem_limit, _limit), do: unknown_reserve()

  defp unknown_reserve, do: %{detected_memory_bytes: nil, reserve_bytes: nil, reserve: :unknown}

  # StarRocks caps the process limit at the detected memory, so a percentage
  # that resolves above it leaves the limit equal to the memory and no reserve.
  defp detected_memory(limit, pct) do
    share = pct / 100 * @process_share_of_mem_limit

    if share >= 1,
      do: limit,
      else: round(limit / share / @mib) * @mib
  end

  defp percent(value) when is_binary(value) do
    with [_, number] <- Regex.run(~r/^\s*([0-9]+(?:\.[0-9]+)?)\s*%\s*$/, value),
         {pct, ""} <- Float.parse(number) do
      pct
    else
      _ -> nil
    end
  end

  defp percent(_value), do: nil

  ## Warnings

  defp node_warnings(node) do
    reserve_warning(node) ++ Enum.flat_map(node.settings, &setting_warning(node, &1))
  end

  defp reserve_warning(%{reserve: :low} = node) do
    [
      "#{label(node)}: #{gib(node.reserve_bytes)} GiB left under #{gib(node.detected_memory_bytes)} GiB " <>
        "after a #{gib(node.process_limit_bytes)} GiB process limit (mem_limit #{node.mem_limit}); " <>
        "below the #{gib(@reserve_warning_bytes)} GiB reserve, lower mem_limit in the node's config file"
    ]
  end

  defp reserve_warning(_node), do: []

  defp setting_warning(node, %{state: :restart_required} = setting) do
    [
      "#{label(node)}: #{setting.name} is #{setting.live}, ServiceRadar ships #{setting.target}; " <>
        "this StarRocks cannot change it at runtime, set it in the node's config file"
    ]
  end

  defp setting_warning(node, %{state: :failed} = setting) do
    ["#{label(node)}: #{setting.name} could not be set to #{setting.target}: #{setting.error}"]
  end

  defp setting_warning(_node, _setting), do: []

  defp label(node) do
    kind = if node.kind == :backend, do: "backend", else: "compute node"
    "StarRocks #{kind} #{node.id} (#{node.host})"
  end

  defp gib(bytes), do: :erlang.float_to_binary(bytes / @gib, decimals: 1)

  ## Parsing

  defp at(_row, nil), do: nil
  defp at(row, index), do: Enum.at(row, index)

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  defp truthy?(value), do: (value |> to_string() |> String.downcase()) in ["1", "true"]

  @units %{"B" => 1, "KB" => 1024, "MB" => @mib, "GB" => @gib, "TB" => @gib * 1024}

  # The Frontend prints MemLimit with DebugUtil.getPrettyStringBytes: three
  # decimals and a 1024-based unit, such as "5.400GB".
  defp parse_bytes(value) when is_binary(value) do
    with [_, number, unit] <-
           Regex.run(~r/^\s*([0-9]+(?:[.,][0-9]+)?)\s*([KMGT]?B)\s*$/i, value),
         {amount, ""} <- Float.parse(String.replace(number, ",", ".")) do
      round(amount * Map.fetch!(@units, String.upcase(unit)))
    else
      _ -> nil
    end
  end

  defp parse_bytes(_value), do: nil

  ## Process

  @doc """
  Options: `:query` (the statement runner, default the shared pool),
  `:initial_delay_ms`, `:retry_ms` and `:interval_ms`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(@table, {:health, %{status: :pending}})

    state = %{
      query: Keyword.get(opts, :query, &MySQL.query/1),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      reported: MapSet.new(),
      last_error: nil
    }

    Process.send_after(self(), :converge, Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    {:ok, state}
  end

  @impl true
  def handle_info(:converge, state) do
    {state, delay} =
      case converge(state.query) do
        {:ok, nodes} ->
          health = summarize(nodes, DateTime.utc_now())
          :ets.insert(@table, {:health, health})
          log_applied(nodes)
          {%{report_warnings(state, health.warnings) | last_error: nil}, state.interval_ms}

        {:error, reason} ->
          :ets.insert(
            @table,
            {:health, %{status: :error, error: inspect(reason), checked_at: DateTime.utc_now()}}
          )

          {report_error(state, reason), state.retry_ms}
      end

    Process.send_after(self(), :converge, delay)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp log_applied(nodes) do
    for node <- nodes, %{state: :applied} = setting <- node.settings do
      Logger.info(
        "StarRocks node #{node.id} (#{node.host}): set #{setting.name} to #{setting.target} (was #{setting.live})"
      )
    end
  end

  # A standing warning is logged when it first appears, not on every pass.
  defp report_warnings(state, warnings) do
    current = MapSet.new(warnings)

    for warning <- warnings, not MapSet.member?(state.reported, warning) do
      Logger.warning(warning)
    end

    %{state | reported: current}
  end

  defp report_error(%{last_error: reason} = state, reason), do: state

  defp report_error(state, reason) do
    Logger.warning("StarRocks node memory settings not checked, retrying: #{inspect(reason)}")
    %{state | last_error: reason}
  end
end
