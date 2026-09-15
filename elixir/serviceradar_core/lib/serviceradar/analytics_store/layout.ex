defmodule ServiceRadar.AnalyticsStore.Layout do
  @moduledoc """
  Hive-partitioned object keys for analytics Parquet.

  Published objects live under `date=YYYY-MM-DD/` so readers can glob only
  complete partitions. Staging keys sit in `_staging/` so a truncated COPY
  cannot become query-visible.
  """

  @layout_version "v1"

  @type keys :: %{
          staging_key: String.t(),
          published_key: String.t(),
          partition_date: Date.t(),
          batch_id: String.t()
        }

  @doc "Layout version segment (`v1`)."
  @spec layout_version() :: String.t()
  def layout_version, do: @layout_version

  @doc """
  Staging and published keys for one batch.

  `writer` is a short, filesystem-safe label (for example `core-elx`).
  """
  @spec keys(String.t(), Date.t(), String.t(), String.t()) :: keys()
  def keys(table, %Date{} = date, writer, batch_id)
      when is_binary(table) and is_binary(writer) and is_binary(batch_id) do
    table = sanitize(table)
    writer = sanitize(writer)
    batch_id = sanitize(batch_id)
    date_s = Date.to_iso8601(date)

    %{
      staging_key: "analytics/#{@layout_version}/#{table}/_staging/#{batch_id}.parquet",
      published_key:
        "analytics/#{@layout_version}/#{table}/date=#{date_s}/#{writer}-#{batch_id}.parquet",
      partition_date: date,
      batch_id: batch_id
    }
  end

  @doc "Hive glob over published `date=*` objects for `table` (never `_staging/`)."
  @spec published_glob(String.t()) :: String.t()
  def published_glob(table) when is_binary(table) do
    "analytics/#{@layout_version}/#{sanitize(table)}/date=*/*.parquet"
  end

  @doc "UTC date of a row's time column (atom or string key)."
  @spec partition_date(map(), String.t()) :: {:ok, Date.t()} | {:error, term()}
  def partition_date(row, time_column) when is_map(row) and is_binary(time_column) do
    row
    |> fetch_time(time_column)
    |> to_date()
  end

  defp fetch_time(row, time_column) do
    Map.get(row, time_column) ||
      (safe_atom(time_column) && Map.get(row, safe_atom(time_column)))
  end

  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp to_date(%DateTime{} = dt), do: {:ok, DateTime.to_date(dt)}
  defp to_date(%NaiveDateTime{} = dt), do: {:ok, NaiveDateTime.to_date(dt)}
  defp to_date(%Date{} = date), do: {:ok, date}

  defp to_date(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, dt, _} -> {:ok, DateTime.to_date(dt)}
      {:error, _} -> {:error, {:unparseable_timestamp, binary}}
    end
  end

  defp to_date(other), do: {:error, {:unparseable_timestamp, other}}

  defp sanitize(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "x"
      cleaned -> cleaned
    end
  end
end
