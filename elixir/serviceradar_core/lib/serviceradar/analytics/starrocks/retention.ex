defmodule ServiceRadar.Analytics.StarRocks.Retention do
  @moduledoc """
  Applies the operator-configured telemetry retention to the StarRocks
  warehouse tables.

  The telemetry tables are partitioned by day, so retention is enforced by
  StarRocks itself: keeping the most recent N daily partitions drops anything
  older without a delete job. The DDL ships a 90-day default;
  `SERVICERADAR_STARROCKS_RETENTION_DAYS` (Helm `analytics.starrocks.retentionDays`,
  Compose `STARROCKS_RETENTION_DAYS`) is re-applied on every boot so a changed
  value takes effect on rollout.
  """

  require Logger

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.MySQL

  @tables ~w(ocsf_network_activity timeseries_metrics logs events)

  @attempts 5
  @retry_delay_ms 5_000

  @spec tables() :: [String.t()]
  def tables, do: @tables

  @spec statements(keyword()) :: [String.t()]
  def statements(config) when is_list(config) do
    days = Keyword.get(config, :retention_days, Env.default_retention_days())

    Enum.map(@tables, fn table ->
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
    attempts = Keyword.get(opts, :attempts, @attempts)
    delay = Keyword.get(opts, :retry_delay_ms, @retry_delay_ms)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    run_attempt(opts, attempts, delay, sleep)
  end

  defp run_attempt(opts, attempts_left, delay, sleep) do
    case apply_retention(opts) do
      :ok ->
        :ok

      {:error, reason} when attempts_left > 1 ->
        Logger.debug("StarRocks retention not applied yet: #{inspect(reason)}")
        sleep.(delay)
        run_attempt(opts, attempts_left - 1, delay, sleep)

      {:error, reason} ->
        Logger.warning(
          "StarRocks retention could not be applied; tables keep their DDL default: #{inspect(reason)}"
        )

        :ok
    end
  end
end
