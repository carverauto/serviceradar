defmodule ServiceRadar.Observability.ThreatIntelPluginIngestor do
  @moduledoc """
  Ingests normalized threat-intel pages emitted by edge Wasm plugins.

  The first supported shape is a `threat_intel` object embedded either at the
  plugin result top level or inside JSON-encoded `details`. Core remains the
  source of truth for persistence and matching; plugins only fetch and normalize
  provider pages from edge-reachable networks.
  """

  alias ServiceRadar.Observability.ThreatIntel.Page
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelSourceObject

  require Logger

  @max_indicators_per_page 5_000
  @doc false
  @spec normalize_indicators(map(), map(), DateTime.t()) :: [map()]
  def normalize_indicators(payload, status, observed_at)
      when is_map(payload) and is_map(status) and is_struct(observed_at, DateTime) do
    case extract_page(payload) do
      page when is_map(page) ->
        page
        |> Page.from_map(status)
        |> Page.indicator_attrs(observed_at, max_indicators: @max_indicators_per_page)

      _ ->
        []
    end
  end

  def normalize_indicators(_payload, _status, _observed_at), do: []

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
    threat_intel_page = Page.from_map(page, status)

    threat_intel_page
    |> Page.source_object_attrs(observed_at, max_objects: @max_indicators_per_page)
    |> Enum.each(&upsert_source_object(&1, actor))

    threat_intel_page
    |> Page.indicator_attrs(observed_at, max_indicators: @max_indicators_per_page)
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

  defp upsert_source_object(attrs, actor) do
    case Ash.create(ThreatIntelSourceObject, attrs,
           action: :upsert,
           actor: actor,
           domain: ServiceRadar.Observability
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Plugin threat-intel source object upsert failed",
          source: attrs.source,
          object_id: attrs.object_id,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil
end
