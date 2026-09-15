defmodule ServiceRadar.AnalyticsStore.Query do
  @moduledoc """
  Resolve Parquet files on the primary before a query checks out the analytics head.

  A scoped CTE shadows the head's maintenance view. Concrete, published manifest
  keys avoid S3 glob listing during CreatePlan and exclude unverified objects.
  The original predicates and bind parameters still filter rows within each file.
  """

  alias ServiceRadar.AnalyticsStore.Bindings
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.AnalyticsStore.Views
  alias ServiceRadar.ColdTier.Registry

  @spec prepare(String.t(), String.t(), {Date.t() | nil, Date.t() | nil}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def prepare(table, sql, {start_date, end_date}, opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    list = Keyword.get(opts, :manifest_list_fn, &FileManifest.published_keys/3)

    with {:ok, entry} <- Registry.fetch(table),
         {:ok, keys} <- list.(table, start_date, end_date),
         {:ok, urls} <- urls(cfg, table, keys) do
      source = Views.manifest_select_sql(entry, urls)
      with_source(sql, table, source)
    end
  end

  @doc "UTC window already resolved by the SRQL planner, including pinned cursor windows."
  def translation_window(nil), do: {:ok, {nil, nil}}

  def translation_window(%{"start" => start_time, "end" => end_time}) do
    with {:ok, start_time, _} <- DateTime.from_iso8601(start_time),
         {:ok, end_time, _} <- DateTime.from_iso8601(end_time) do
      {:ok, {DateTime.to_date(start_time), DateTime.to_date(end_time)}}
    end
  end

  def translation_window(_), do: {:error, :invalid_analytics_time_range}

  @doc "Only callers that own a query's time predicates may bound direct SQL's manifest scan."
  def query_window(opts) do
    case Keyword.get(opts, :time_range, {nil, nil}) do
      {start_time, end_time} ->
        with {:ok, start_date} <- partition_date(start_time),
             {:ok, end_date} <- partition_date(end_time) do
          {:ok, {start_date, end_date}}
        end

      _ ->
        {:error, :invalid_analytics_time_range}
    end
  end

  defp partition_date(nil), do: {:ok, nil}
  defp partition_date(%Date{} = date), do: {:ok, date}

  defp partition_date(%DateTime{} = time) do
    {:ok, time |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()}
  end

  defp partition_date(_), do: {:error, :invalid_analytics_time_range}

  defp urls(cfg, table, keys) do
    key_pattern =
      Regex.compile!(
        "\\Aanalytics/v1/#{Regex.escape(table)}/date=\\d{4}-\\d{2}-\\d{2}/[A-Za-z0-9_-]+\\.parquet\\z"
      )

    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, urls} ->
      # The manifest is internal, but its contents must never reintroduce a glob,
      # staging scan, or a path outside the configured table's published prefix.
      if Regex.match?(key_pattern, key) do
        case Storage.copy_target(cfg, key) do
          {:ok, url} -> {:cont, {:ok, [url | urls]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:halt, {:error, :invalid_analytics_manifest_key}}
      end
    end)
    |> case do
      {:ok, urls} -> {:ok, Enum.reverse(urls)}
      error -> error
    end
  end

  defp with_source(sql, table, source) do
    qualified =
      Regex.compile!(
        ~s/\\b((?:FROM|JOIN)\\s+)(?:"platform"|platform)\\s*\\.\\s*(?:"#{table}"|#{table})(?![\\w"])/,
        "i"
      )

    rewrite = fn part ->
      {:ok, Regex.replace(qualified, part, fn _, prefix -> prefix <> table end)}
    end

    with {:ok, sql} <- Bindings.map_sql(sql, rewrite, quoted_identifiers: :code) do
      cte = ~s/"#{table}" AS NOT MATERIALIZED (#{source})/

      scoped =
        if Regex.match?(~r/^\s*WITH\s+/i, sql) do
          Regex.replace(~r/^\s*WITH\s+/i, sql, "WITH #{cte}, ", global: false)
        else
          "WITH #{cte}\n#{sql}"
        end

      {:ok, scoped}
    end
  end
end
