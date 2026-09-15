defmodule ServiceRadar.AnalyticsStore.SQL do
  @moduledoc """
  Pick `Repo` or `AnalyticsRepo` from the analytics-store dialect.

  Timescale (the default) stays on the primary. A duckdb-tagged translation
  or a flipped table goes to the analytics head, or fails closed if the head
  is not running.
  """

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias ServiceRadar.AnalyticsRepo
  alias ServiceRadar.AnalyticsStore
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.Repo

  @duckdb_timeout_ms 60_000

  @doc "Ecto repo for a translation's `dialect` tag (`\"duckdb\"` or omitted)."
  @spec repo_for_translation(map(), keyword()) :: module() | {:error, :analytics_head_unavailable}
  def repo_for_translation(translation, opts \\ []) when is_map(translation) do
    case translation["dialect"] || translation[:dialect] do
      value when value in ["duckdb", :duckdb] -> analytics_repo(opts)
      _ -> Keyword.get(opts, :repo, Repo)
    end
  end

  @doc "Ecto repo for a registry table under the current (or supplied) config."
  @spec repo_for_table(String.t(), keyword()) :: module() | {:error, :analytics_head_unavailable}
  def repo_for_table(table, opts \\ []) when is_binary(table) do
    case AnalyticsStore.dialect(table, opts) do
      :duckdb -> analytics_repo(opts)
      :postgres -> Keyword.get(opts, :repo, Repo)
    end
  end

  @doc "Run SQL on the repo selected for `table`."
  @spec query(String.t(), String.t(), [term()], keyword()) :: {:ok, term()} | {:error, term()}
  def query(table, sql, params, opts \\ [])
      when is_binary(table) and is_binary(sql) and is_list(params) do
    case repo_for_table(table, opts) do
      {:error, reason} ->
        {:error, reason}

      repo ->
        EctoSQL.query(repo, sql, params, timeout: Keyword.get(opts, :timeout, timeout_for(repo)))
    end
  end

  @doc "JSON driver map for `Native.translate/6`."
  @spec drivers_json(keyword()) :: String.t()
  def drivers_json(opts \\ []) do
    Jason.encode!(AnalyticsStore.driver_map(opts))
  end

  @doc "Query timeout for a duckdb-tagged translation."
  @spec duckdb_timeout_ms() :: pos_integer()
  def duckdb_timeout_ms, do: @duckdb_timeout_ms

  defp analytics_repo(opts) do
    repo = Keyword.get(opts, :analytics_repo, AnalyticsRepo)

    cond do
      Keyword.has_key?(opts, :analytics_query_fn) ->
        repo

      is_pid(Process.whereis(repo)) ->
        repo

      true ->
        {:error, :analytics_head_unavailable}
    end
  end

  defp timeout_for(AnalyticsRepo), do: @duckdb_timeout_ms
  defp timeout_for(_), do: @duckdb_timeout_ms

  @doc "Child spec when a head is configured, otherwise `nil`."
  @spec child_spec_or_nil(Config.t() | nil) :: {module(), keyword()} | nil
  def child_spec_or_nil(cfg \\ nil) do
    cfg = cfg || Config.load()

    case Config.head_opts(cfg) do
      :disabled ->
        nil

      {:ok, opts} ->
        pool = query_pool_size(cfg)

        {AnalyticsRepo,
         Keyword.merge(opts,
           pool_size: pool,
           timeout: @duckdb_timeout_ms,
           queue_target: 5_000,
           queue_interval: 1_000,
           parameters: [statement_timeout: "60s", application_name: "sr_analytics_repo"]
         )}
    end
  end

  defp query_pool_size(%Config{pool_size: n}) when is_integer(n) and n > 0, do: n
  defp query_pool_size(_), do: 4
end
