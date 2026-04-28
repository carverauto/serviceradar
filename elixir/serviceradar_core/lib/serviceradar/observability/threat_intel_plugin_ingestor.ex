defmodule ServiceRadar.Observability.ThreatIntelPluginIngestor do
  @moduledoc """
  Ingests normalized threat-intel pages emitted by edge Wasm plugins.

  The first supported shape is a `threat_intel` object embedded either at the
  plugin result top level or inside JSON-encoded `details`. Core remains the
  source of truth for persistence and matching; plugins only fetch and normalize
  provider pages from edge-reachable networks.
  """

  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.ThreatIntel.Page
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelRawPayloadStore
  alias ServiceRadar.Observability.ThreatIntelSourceObject
  alias ServiceRadar.Observability.ThreatIntelSyncStatus

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
        do_ingest(page, payload, status, actor, observed_at)

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

  @spec ingest_page(Page.t(), map(), map(), keyword()) :: :ok
  def ingest_page(%Page{} = page, payload, status, opts \\ [])
      when is_map(payload) and is_map(status) do
    started_at = System.monotonic_time()

    try do
      actor = Keyword.fetch!(opts, :actor)
      observed_at = Keyword.get(opts, :observed_at) || DateTime.utc_now()

      do_ingest_page(page, payload, status, actor, observed_at, started_at)
    rescue
      e ->
        emit_ingest_event(:exception, started_at, %{
          provider: page.provider,
          source: page.source,
          collection_id: page.collection_id || "",
          error: exception_kind(e)
        })

        Logger.warning("Threat-intel page ingest failed: #{Exception.message(e)}")
        :ok
    end
  end

  defp do_ingest(page, payload, status, actor, observed_at) do
    page
    |> Page.from_map(status)
    |> do_ingest_page(payload, status, actor, observed_at, System.monotonic_time())
  end

  defp do_ingest_page(%Page{} = page, payload, status, actor, observed_at, started_at) do
    raw_object_key = maybe_archive_raw_payload(page, payload, actor, observed_at)

    sync_status_attrs =
      page
      |> Page.sync_status_attrs(status, payload, observed_at)
      |> maybe_put_raw_payload_metadata(raw_object_key)

    source_object_attrs =
      page
      |> Page.source_object_attrs(observed_at, max_objects: @max_indicators_per_page)
      |> Enum.map(&maybe_put_raw_object_key(&1, raw_object_key))

    indicator_attrs =
      Page.indicator_attrs(page, observed_at, max_indicators: @max_indicators_per_page)

    upsert_sync_status(sync_status_attrs, actor)
    Enum.each(source_object_attrs, &upsert_source_object(&1, actor))
    Enum.each(indicator_attrs, &upsert_indicator(&1, actor))

    emit_ingest_event(:stop, started_at, %{
      provider: page.provider,
      source: page.source,
      collection_id: page.collection_id || "",
      objects_count: length(page.objects),
      source_objects_count: length(source_object_attrs),
      indicators_count: length(indicator_attrs),
      skipped_count: Map.get(page.counts || %{}, "skipped", 0)
    })

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

  defp upsert_sync_status(attrs, actor) when is_map(attrs) and map_size(attrs) > 0 do
    case Ash.create(ThreatIntelSyncStatus, attrs,
           action: :upsert,
           actor: actor,
           domain: ServiceRadar.Observability
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Plugin threat-intel sync status upsert failed",
          source: attrs.source,
          collection_id: attrs.collection_id,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp upsert_sync_status(_attrs, _actor), do: :ok

  defp maybe_archive_raw_payload(%Page{} = page, payload, actor, observed_at)
       when is_map(payload) do
    if raw_payload_archive_enabled?(page, actor) do
      encoded = Jason.encode!(payload)

      case ThreatIntelRawPayloadStore.put_page(
             %{
               source: page.source,
               collection_id: page.collection_id || "",
               observed_at: observed_at
             },
             encoded
           ) do
        {:ok, object_key} ->
          object_key

        {:error, reason} ->
          Logger.warning("Threat-intel raw payload archive failed",
            source: page.source,
            collection_id: page.collection_id,
            reason: inspect(reason)
          )

          nil
      end
    end
  rescue
    error ->
      Logger.warning("Threat-intel raw payload archive failed",
        source: page.source,
        collection_id: page.collection_id,
        reason: inspect(error)
      )

      nil
  end

  defp maybe_archive_raw_payload(_page, _payload, _actor, _observed_at), do: nil

  defp raw_payload_archive_enabled?(%Page{} = page, actor) do
    otx_page?(page) and
      case NetflowSettings.get_settings(actor: actor) do
        {:ok, %NetflowSettings{otx_raw_payload_archive_enabled: true}} -> true
        _ -> false
      end
  rescue
    _ -> false
  end

  defp otx_page?(%Page{} = page) do
    page.source == "alienvault_otx" or page.provider == "alienvault_otx"
  end

  defp maybe_put_raw_payload_metadata(attrs, nil), do: attrs

  defp maybe_put_raw_payload_metadata(%{metadata: %{} = metadata} = attrs, object_key)
       when is_binary(object_key) do
    Map.put(attrs, :metadata, Map.put(metadata, "raw_payload_key", object_key))
  end

  defp maybe_put_raw_payload_metadata(%{} = attrs, object_key) when is_binary(object_key) do
    Map.put(attrs, :metadata, %{"raw_payload_key" => object_key})
  end

  defp maybe_put_raw_object_key(attrs, nil), do: attrs

  defp maybe_put_raw_object_key(%{raw_object_key: value} = attrs, _object_key)
       when is_binary(value) and value != "" do
    attrs
  end

  defp maybe_put_raw_object_key(%{metadata: %{} = metadata} = attrs, object_key)
       when is_binary(object_key) do
    attrs
    |> Map.put(:raw_object_key, object_key)
    |> Map.put(:metadata, Map.put(metadata, "raw_payload_key", object_key))
  end

  defp maybe_put_raw_object_key(%{} = attrs, object_key) when is_binary(object_key) do
    Map.put(attrs, :raw_object_key, object_key)
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp exception_kind(%module{}), do: inspect(module)

  defp emit_ingest_event(kind, started_at, metadata) do
    :telemetry.execute(
      [:serviceradar, :threat_intel, :ingest, kind],
      %{duration: System.monotonic_time() - started_at},
      metadata
    )
  end
end
