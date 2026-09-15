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
  alias ServiceRadar.AnalyticsStore.Bindings
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Query
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
        with {:ok, sql, params} <- prepare_query(table, sql, params, opts) do
          timeout = Keyword.get(opts, :timeout, timeout_for(repo))

          EctoSQL.query(
            repo,
            sql,
            params,
            query_options(AnalyticsStore.dialect(table, opts), timeout)
          )
        end
    end
  end

  @doc "Resolve a duckdb translation to concrete manifest files before checking out the head."
  @spec prepare_translation(map(), [term()], keyword()) ::
          {:ok, String.t(), [term()]} | {:error, term()}
  def prepare_translation(translation, params, opts \\ [])

  def prepare_translation(
        %{"dialect" => "duckdb", "analytics_table" => table} = translation,
        params,
        opts
      )
      when is_binary(table) do
    types = Enum.map(translation["params"] || [], & &1["t"])

    with {:ok, window} <- Query.translation_window(translation["time_range"]),
         {:ok, sql} <- Query.prepare(table, translation["sql"], window, opts),
         {:ok, sql} <- Bindings.bind(sql, params, types: types) do
      {:ok, sql, []}
    end
  end

  def prepare_translation(%{"dialect" => "duckdb"}, _params, _opts),
    do: {:error, :missing_analytics_source}

  def prepare_translation(%{"sql" => sql}, params, _opts), do: {:ok, sql, params}

  @doc """
  Prepare direct SQL for a table without checking out a connection.

  `:time_range` is an optional `{start, end}` of UTC partition dates or DateTimes.
  Omit it unless the caller owns equivalent timestamp predicates. Arbitrary date
  parameters can be upper bounds, exclusions or values in OR expressions, so
  they never implicitly exclude files from the manifest.
  """
  @spec prepare_query(String.t(), String.t(), [term()], keyword()) ::
          {:ok, String.t(), [term()]} | {:error, term()}
  def prepare_query(table, sql, params, opts \\ []) do
    case AnalyticsStore.dialect(table, opts) do
      :postgres ->
        {:ok, sql, params}

      :duckdb ->
        with {:ok, window} <- Query.query_window(opts),
             {:ok, sql} <- Query.prepare(table, sql, window, opts),
             {:ok, sql} <- Bindings.bind(sql, params) do
          {:ok, sql, []}
        end
    end
  end

  @doc "Keep rendered analytics values out of Ecto's SQL logger."
  @spec query_options(term(), pos_integer()) :: keyword()
  def query_options(dialect, timeout) when dialect in [:duckdb, "duckdb"],
    do: [timeout: timeout, log: false]

  def query_options(_dialect, timeout), do: [timeout: timeout]

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
           # pg_duckdb CreatePlan on named prepared statements fails S3 hive
           # globs with `region ''` / HTTP 404 on `date=/`.
           prepare: :unnamed,
           after_connect: {ServiceRadar.AnalyticsStore.Head, :after_connect, []},
           parameters: [statement_timeout: "60s", application_name: "sr_analytics_repo"]
         )}
    end
  end

  defp query_pool_size(%Config{pool_size: n}) when is_integer(n) and n > 0, do: n
  defp query_pool_size(_), do: 4
end
