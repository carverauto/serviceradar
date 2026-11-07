defmodule ServiceRadar.Analytics.StarRocks.Workload do
  @moduledoc """
  Keeps interactive warehouse queries apart from background ones.

  Every statement ServiceRadar sends a Frontend runs as `root` from one pool
  per node, so without this StarRocks puts dashboard reads, SRQL and the MCP
  in the same `default_wg` resource group as trace-summary maintenance, flow
  attribution probes and other background jobs, and a background peak can
  leave an interactive query without memory.

  Two resource groups split them:

    * `sr_interactive` -- the web-ng node: LiveViews, SRQL, the API and MCP.
      Four times the background CPU weight on nodes of four or more cores,
      and a per-query memory cap that stops one runaway read from taking the
      compute node's headroom.
    * `sr_background` -- the core node: EventWriter lookups, Oban jobs and
      maintenance. Capped at a small share of the query pool, with tighter
      per-query memory and concurrency limits.

  Asynchronous materialized-view refreshes already run in StarRocks'
  `default_mv_wg`, and Stream Loads are charged to the load tracker, not to a
  resource group; neither is changed here.

  A node's workload comes from `config :serviceradar_core, #{inspect(__MODULE__)},
  workload: ...` (`:background` unless the release says otherwise; web-ng sets
  `:interactive`). `ServiceRadar.Analytics.StarRocks.MySQL` pins every pooled
  session to that group with `SET resource_group` when it connects. A group
  that does not exist yet is not an error: StarRocks then classifies the query
  as before, into `default_wg`.

  `ensure/1` creates the groups, or converges their limits to the values here
  when they exist. `SchemaMigrator` runs it after the versioned DDL, under the
  same lock, on every start. It is best effort: a warehouse user without the
  privilege to manage resource groups keeps working, unisolated, and the
  failure is logged rather than blocking later migrations.

  ## Sizing

  Limits are per compute node. `mem_limit` is a share of the node's query
  pool and is a cap, not a reservation; `big_query_mem_limit` is per query.
  They were sized from a day of Frontend audit log on a measured three-node
  deployment: background statements peaked at four concurrent and about
  320 MB summed across the cluster (the largest single one about 230 MB);
  interactive ones peaked at six concurrent, the largest about 1.3 GB summed
  across three nodes. Background gets twice its measured concurrency and a
  per-query cap above its largest statement; interactive gets four times its
  measured concurrency and a per-query cap above its largest read per node.
  StarRocks requires exactly one CPU setting, which must not exceed a node's
  core count, so the weights are derived from the smallest live node.
  """

  require Logger

  @type workload :: :interactive | :background

  @groups %{interactive: "sr_interactive", background: "sr_background"}

  @limits %{
    interactive: [
      {"mem_limit", "80%"},
      {"concurrency_limit", "24"},
      {"big_query_mem_limit", "1073741824"}
    ],
    background: [
      {"mem_limit", "15%"},
      {"concurrency_limit", "8"},
      {"big_query_mem_limit", "536870912"}
    ]
  }

  @doc "The workload this node's warehouse sessions belong to."
  @spec current() :: workload()
  def current do
    case :serviceradar_core |> Application.get_env(__MODULE__, []) |> Keyword.get(:workload) do
      :interactive -> :interactive
      _ -> :background
    end
  end

  @doc "The StarRocks resource group a workload runs in."
  @spec resource_group(workload()) :: String.t()
  def resource_group(workload), do: Map.fetch!(@groups, workload)

  @doc """
  Pins a freshly connected session to `group`. Used as the pool's
  `after_connect`; a failure is logged and leaves the session in the group
  StarRocks would have classified it into anyway.
  """
  @spec pin_session(term(), String.t(), (term(), String.t() -> {:ok, term()} | {:error, term()})) ::
          :ok
  def pin_session(conn, group, query \\ &text_query/2) do
    case query.(conn, "SET resource_group = '#{group}'") do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("StarRocks session not pinned to resource group #{group}",
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp text_query(conn, sql), do: MyXQL.query(conn, sql, [], query_type: :text)

  @doc """
  Creates the resource groups, or converges their limits when they exist.
  `query` is the migrator's statement runner.
  """
  @spec ensure((String.t() -> {:ok, map()} | {:error, term()})) :: :ok | {:error, term()}
  def ensure(query) when is_function(query, 1) do
    with {:ok, cores} <- min_cpu_cores(query),
         {:ok, existing} <- existing_groups(query) do
      Enum.reduce_while([:interactive, :background], :ok, fn workload, :ok ->
        case query.(statement(workload, cores, existing)) do
          {:ok, _result} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {resource_group(workload), reason}}}
        end
      end)
    end
  end

  defp statement(workload, cores, existing) do
    group = resource_group(workload)
    properties = properties(workload, cores)

    if MapSet.member?(existing, group) do
      "ALTER RESOURCE GROUP #{group} WITH (#{properties})"
    else
      # StarRocks requires a classifier. The session variable is what routes
      # queries here, so this names a user ServiceRadar never connects as.
      "CREATE RESOURCE GROUP #{group} TO (user='#{group}') WITH (#{properties})"
    end
  end

  defp properties(workload, cores) do
    Enum.map_join(
      [
        {"cpu_weight", Integer.to_string(cpu_weight(workload, cores))}
        | Map.fetch!(@limits, workload)
      ],
      ", ",
      fn {key, value} -> ~s("#{key}" = "#{value}") end
    )
  end

  defp cpu_weight(:interactive, cores), do: max(cores, 1)
  defp cpu_weight(:background, cores), do: max(div(cores, 4), 1)

  defp existing_groups(query) do
    case query.("SHOW RESOURCE GROUPS ALL") do
      {:ok, %{columns: columns, rows: rows}} ->
        index = Enum.find_index(columns, &(String.downcase(to_string(&1)) == "name")) || 0
        {:ok, MapSet.new(rows, &to_string(Enum.at(&1, index)))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The smallest live node bounds a valid cpu_weight. Shared-nothing clusters
  # report backends, shared-data clusters compute nodes.
  defp min_cpu_cores(query) do
    cores =
      Enum.flat_map(["SHOW BACKENDS", "SHOW COMPUTE NODES"], fn sql ->
        case query.(sql) do
          {:ok, %{columns: columns, rows: rows}} -> live_cores(columns, rows)
          {:error, _reason} -> []
        end
      end)

    case cores do
      [] -> {:error, :no_live_starrocks_node}
      cores -> {:ok, Enum.min(cores)}
    end
  end

  defp live_cores(columns, rows) do
    alive = Enum.find_index(columns, &(&1 == "Alive"))
    cpu = Enum.find_index(columns, &(&1 == "CpuCores"))

    if is_nil(alive) or is_nil(cpu) do
      []
    else
      for row <- rows,
          row |> Enum.at(alive) |> to_string() |> String.downcase() == "true",
          {count, _} <- [row |> Enum.at(cpu) |> to_string() |> Integer.parse()],
          count > 0,
          do: count
    end
  end
end
