defmodule ServiceRadar.Observability.ThreatIntelPluginIngestor do
  @moduledoc """
  Ingests normalized threat-intel pages emitted by edge Wasm plugins.

  The first supported shape is a `threat_intel` object embedded either at the
  plugin result top level or inside JSON-encoded `details`. Core remains the
  source of truth for persistence and matching; plugins only fetch and normalize
  provider pages from edge-reachable networks.
  """

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Observability.ThreatIntelIndicator

  require Logger

  @max_indicators_per_page 5_000
  @default_source "plugin_threat_intel"

  @spec ingest(map(), map(), keyword()) :: :ok
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_map(payload) and is_map(status) do
    actor = Keyword.fetch!(opts, :actor)
    observed_at = Keyword.get(opts, :observed_at) || DateTime.utc_now()

    case extract_page(payload) do
      nil ->
        :ok

      page when is_map(page) ->
        do_ingest(page, status, actor, observed_at)

      _ ->
        Logger.warning("Ignoring invalid plugin threat-intel payload")
        :ok
    end
  rescue
    e ->
      Logger.warning("Plugin threat-intel ingest failed: #{Exception.message(e)}")
      :ok
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp do_ingest(page, status, actor, observed_at) do
    source = source_for(page, status)
    indicators = list_value(page, ["indicators"])

    indicators
    |> Enum.take(@max_indicators_per_page)
    |> Enum.map(&normalize_indicator(&1, page, source, observed_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1.source, &1.indicator})
    |> Enum.each(&upsert_indicator(&1, actor))

    :ok
  end

  defp extract_page(payload) do
    fetch_value(payload, ["threat_intel", "threatIntel"]) ||
      payload
      |> fetch_value(["details"])
      |> decode_details()
      |> fetch_value(["threat_intel", "threatIntel"])
  end

  defp decode_details(value) when is_map(value), do: value

  defp decode_details(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_details(_), do: %{}

  defp normalize_indicator(entry, page, source, observed_at) when is_map(entry) do
    with indicator when is_binary(indicator) and indicator != "" <-
           string_value(entry, ["indicator", "value"]),
         {:ok, cidr} <- ServiceRadar.Types.Cidr.cast_input(indicator, []) do
      %{
        indicator: cidr,
        indicator_type: "cidr",
        source: string_value(entry, ["source"]) || source,
        label: label_for(entry, page),
        severity: int_value(entry, ["severity", "severity_id", "severityId"]),
        confidence: int_value(entry, ["confidence"]),
        first_seen_at:
          datetime_value(entry, ["first_seen_at", "firstSeenAt", "created"]) || observed_at,
        last_seen_at:
          datetime_value(entry, ["last_seen_at", "lastSeenAt", "modified"]) || observed_at,
        expires_at: datetime_value(entry, ["expires_at", "expiresAt", "expiration"])
      }
    else
      _ -> nil
    end
  end

  defp normalize_indicator(_entry, _page, _source, _observed_at), do: nil

  defp upsert_indicator(attrs, actor) do
    case Ash.create(ThreatIntelIndicator, attrs,
           action: :upsert,
           actor: actor,
           domain: ServiceRadar.Observability
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Plugin threat-intel indicator upsert failed",
          source: attrs.source,
          indicator: attrs.indicator,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp source_for(page, status) do
    string_value(page, ["source", "provider", "provider_id", "providerId"]) ||
      string_value(status, [:plugin_id, "plugin_id"]) ||
      @default_source
  end

  defp label_for(entry, page) do
    string_value(entry, ["label", "title", "pulse_name", "pulseName"]) ||
      string_value(page, ["label", "collection_id", "collectionId"])
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp list_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp string_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _ ->
        nil
    end
  end

  defp int_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_int(value)
      _ -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp datetime_value(map, keys) do
    case fetch_value(map, keys) do
      nil -> nil
      "" -> nil
      value -> FieldParser.parse_timestamp(value)
    end
  rescue
    _ -> nil
  end
end
