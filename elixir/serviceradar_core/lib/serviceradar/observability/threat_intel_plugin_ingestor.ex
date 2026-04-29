defmodule ServiceRadar.Observability.ThreatIntelPluginIngestor do
  @moduledoc """
  Ingests normalized threat-intel pages emitted by edge Wasm plugins.

  The first supported shape is a `threat_intel` object embedded either at the
  plugin result top level or inside JSON-encoded `details`. Core remains the
  source of truth for persistence and matching; plugins only fetch and normalize
  provider pages from edge-reachable networks.
  """

  alias ServiceRadar.Observability.NetflowSecurityRefreshWorker
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.ThreatIntel.Page
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelRawPayloadStore
  alias ServiceRadar.Observability.ThreatIntelSourceObject
  alias ServiceRadar.Observability.ThreatIntelSyncStatus
  alias ServiceRadar.Plugins.PluginAssignment

  require Ash.Query
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
    maybe_persist_edge_cursor(page, payload, status, actor)
    maybe_enqueue_netflow_match(page, indicator_attrs, actor)

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

  defp maybe_persist_edge_cursor(%Page{} = page, payload, status, actor)
       when is_map(payload) and is_map(status) do
    with true <- otx_page?(page),
         assignment_id when is_binary(assignment_id) and assignment_id != "" <-
           fetch_assignment_id(payload, status),
         params = cursor_params(page.cursor),
         true <- map_size(params) > 0,
         {:ok, assignment} <- fetch_assignment(assignment_id, actor),
         %PluginAssignment{} <- assignment do
      updated_params =
        assignment.params
        |> normalize_assignment_params()
        |> Map.merge(params)

      assignment
      |> Ash.Changeset.for_update(:update, %{params: updated_params})
      |> Ash.update(actor: actor, domain: ServiceRadar.Plugins)
      |> case do
        {:ok, _updated} ->
          :ok

        {:error, reason} ->
          Logger.warning("Threat-intel assignment cursor update failed",
            assignment_id: assignment_id,
            reason: inspect(reason)
          )

          :error
      end
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("Threat-intel assignment cursor update failed", reason: inspect(error))
      :ok
  end

  defp maybe_persist_edge_cursor(_page, _payload, _status, _actor), do: :ok

  defp fetch_assignment_id(payload, status) do
    fetch_value(status, [:assignment_id, "assignment_id"]) ||
      payload
      |> fetch_value(["labels", "label"])
      |> fetch_value(["assignment_id", :assignment_id])
  end

  defp cursor_params(cursor) when is_map(cursor) do
    complete? = fetch_value(cursor, ["complete"]) == "true"
    next_page = fetch_value(cursor, ["next_page"])
    next = fetch_value(cursor, ["next"])

    cond do
      complete? ->
        %{"page" => 1, "cursor_complete" => true, "cursor_next" => nil}

      is_binary(next_page) and next_page != "" ->
        maybe_put_cursor_next(
          %{"page" => parse_positive_int(next_page, next_page), "cursor_complete" => false},
          next
        )

      true ->
        %{}
    end
  end

  defp cursor_params(_cursor), do: %{}

  defp maybe_put_cursor_next(params, next) when is_binary(next) and next != "" do
    Map.put(params, "cursor_next", next)
  end

  defp maybe_put_cursor_next(params, _next), do: params

  defp fetch_assignment(assignment_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^assignment_id)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Plugins)
  end

  defp normalize_assignment_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_assignment_params(_params), do: %{}

  defp parse_positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp parse_positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp parse_positive_int(_value, fallback), do: fallback

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

  defp maybe_enqueue_netflow_match(%Page{} = page, indicator_attrs, actor)
       when is_list(indicator_attrs) do
    if otx_page?(page) and indicator_attrs != [] and threat_matching_enabled?(actor) do
      case NetflowSecurityRefreshWorker.enqueue_now() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.debug("Threat-intel NetFlow match enqueue skipped", reason: inspect(reason))
          :ok
      end
    end
  rescue
    error ->
      Logger.debug("Threat-intel NetFlow match enqueue failed", reason: inspect(error))
      :ok
  end

  defp maybe_enqueue_netflow_match(_page, _indicator_attrs, _actor), do: :ok

  defp threat_matching_enabled?(actor) do
    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{threat_intel_enabled: true}} -> true
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
