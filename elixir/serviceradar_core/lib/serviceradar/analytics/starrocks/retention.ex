defmodule ServiceRadar.Analytics.StarRocks.Retention do
  @moduledoc """
  Applies the operator-configured telemetry retention to the StarRocks
  warehouse tables.

  The telemetry tables are partitioned by day, so retention is enforced by
  StarRocks itself: keeping the most recent N daily partitions drops anything
  older without a delete job. Retention is per dataset -- flows and metrics
  default to 90 days, logs and event history to the hosted one year -- and each
  is configurable through `SERVICERADAR_STARROCKS_RETENTION_DAYS_<DATASET>`
  (Helm `analytics.starrocks.retentionDays.<dataset>`, Compose
  `STARROCKS_RETENTION_DAYS_<DATASET>`).

  A warehouse Frontend is routinely slower to answer than core is to boot, and
  a value that never lands means partitions are dropped on the DDL default
  instead, which cannot be undone. The applier therefore retries with capped
  backoff until the statements succeed rather than giving up.
  """

  require Logger

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.MySQL

  @tables [
    flows: "ocsf_network_activity",
    metrics: "timeseries_metrics",
    logs: "logs",
    events: "events"
  ]

  @initial_delay_ms 5_000
  @max_delay_ms 300_000

  @spec tables() :: keyword(String.t())
  def tables, do: @tables

  @spec statements(keyword()) :: [String.t()]
  def statements(config) when is_list(config) do
    retention = Keyword.get(config, :retention_days, [])

    Enum.map(@tables, fn {dataset, table} ->
      days =
        Keyword.get(
          retention,
          dataset,
          Keyword.fetch!(Env.default_retention_days(), dataset)
        )

      "ALTER TABLE `#{table}` SET (\"partition_live_number\" = \"#{days}\")"
    end)
  end

  @spec apply_retention(keyword()) :: :ok | {:error, term()}
  def apply_retention(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &Env.config/0)
    query = Keyword.get(opts, :query, &MySQL.query/1)

    config
    |> statements()
    |> Enum.reduce_while(:ok, fn sql, :ok ->
      case query.(sql) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec child_spec(term()) :: Supervisor.child_spec() | nil
  def child_spec(_opts) do
    if Env.config()[:enabled] do
      %{
        id: __MODULE__,
        start: {Task, :start_link, [__MODULE__, :run, [[]]]},
        restart: :temporary,
        type: :worker
      }
    end
  end

  @doc false
  @spec run(keyword()) :: :ok
  def run(opts) when is_list(opts) do
    attempts = Keyword.get(opts, :attempts, :infinity)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    run_attempt(opts, attempts, @initial_delay_ms, sleep)
  end

  defp run_attempt(opts, attempts_left, delay, sleep) do
    case apply_retention(opts) do
      :ok ->
        :ok

      {:error, reason} when attempts_left == :infinity or attempts_left > 1 ->
        Logger.warning(
          "StarRocks retention not applied, retrying in #{delay}ms: #{inspect(reason)}"
        )

        sleep.(delay)
        run_attempt(opts, remaining(attempts_left), min(delay * 2, @max_delay_ms), sleep)

      {:error, reason} ->
        Logger.warning(
          "StarRocks retention could not be applied; tables keep their DDL default: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(attempts_left), do: attempts_left - 1
end
