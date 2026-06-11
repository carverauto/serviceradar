defmodule ServiceRadar.EventWriter.IngestAttribution do
  @moduledoc """
  Extracts gateway ingest-attribution headers from NATS message metadata.

  The agent gateway stamps every telemetry publish with three headers that
  identify where a signal entered the platform:

  - `Sr-Ingest-Identity` → `ingest_identity` (publisher identity)
  - `Sr-Agent-Id`        → `ingest_agent_id` (ingesting agent)
  - `Sr-Partition`       → `ingest_partition` (agent partition/site)

  The matching columns on `platform.{otel_traces, logs, otel_metrics,
  otel_metric_points}` are TEXT NOT NULL DEFAULT '', so absent or unusable
  headers always map to `""`. Header keys are matched case-insensitively;
  carriers may be maps or NATS-style tuple lists (multi-value headers take
  the first value).
  """

  @columns [
    ingest_identity: "sr-ingest-identity",
    ingest_agent_id: "sr-agent-id",
    ingest_partition: "sr-partition"
  ]

  @type t :: %{
          ingest_identity: String.t(),
          ingest_agent_id: String.t(),
          ingest_partition: String.t()
        }

  @doc """
  Attribution triple with every column defaulted to `""`.
  """
  @spec empty() :: t()
  def empty do
    Map.new(@columns, fn {column, _header} -> {column, ""} end)
  end

  @doc """
  Reads the attribution triple from Broadway message metadata (the producer
  surfaces NATS headers under the `:headers` key).
  """
  @spec from_metadata(term()) :: t()
  def from_metadata(metadata) when is_map(metadata) do
    from_headers(Map.get(metadata, :headers))
  end

  def from_metadata(_metadata), do: empty()

  @doc """
  Reads the attribution triple from NATS headers (map or tuple list).
  """
  @spec from_headers(term()) :: t()
  def from_headers(headers) do
    Map.new(@columns, fn {column, header} -> {column, header_value(headers, header)} end)
  end

  @doc """
  Merges the attribution columns into a row, a list of rows, or `nil`
  (pass-through), matching processor `parse_message/1` return shapes.
  """
  @spec attach(nil, t()) :: nil
  @spec attach([map()], t()) :: [map()]
  @spec attach(map(), t()) :: map()
  def attach(nil, _attribution), do: nil

  def attach(rows, attribution) when is_list(rows) do
    Enum.map(rows, &attach(&1, attribution))
  end

  def attach(row, attribution) when is_map(row), do: Map.merge(row, attribution)

  # Header carrier handling mirrors ServiceRadar.EventWriter.Producer:
  # keys compared case-insensitively, list values take the first entry.

  defp header_value(headers, key) when is_map(headers) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if normalize_key(k) == key, do: normalize_value(v)
    end)
    |> default_empty()
  end

  defp header_value(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {k, v} -> if normalize_key(k) == key, do: normalize_value(v)
      _other -> nil
    end)
    |> default_empty()
  end

  defp header_value(_headers, _key), do: ""

  defp default_empty(value) when is_binary(value), do: value
  defp default_empty(_value), do: ""

  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()

  defp normalize_key(key) when is_list(key) do
    key |> to_string() |> String.downcase()
  rescue
    _ -> ""
  end

  defp normalize_key(_key), do: ""

  defp normalize_value(value) when is_binary(value), do: value

  defp normalize_value([first | _rest]) when is_binary(first), do: first

  defp normalize_value(value) when is_list(value) do
    to_string(value)
  rescue
    _ -> nil
  end

  defp normalize_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)

  defp normalize_value(_value), do: nil
end
