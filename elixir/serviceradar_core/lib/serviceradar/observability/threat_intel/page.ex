defmodule ServiceRadar.Observability.ThreatIntel.Page do
  @moduledoc """
  Provider-neutral threat-intel page model.

  The shape mirrors TAXII/STIX concepts: provider/source identity, collection
  identity, cursor/high-water state, object pages, and already-normalized
  indicator rows. Edge plugins and future core-hosted providers should adapt
  their provider-specific payloads into this shape before persistence.
  """

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Observability.ThreatIntel.StixIndicator
  alias ServiceRadar.Types.Cidr

  @default_source "plugin_threat_intel"
  @default_max_indicators 5_000

  @type t :: %__MODULE__{
          schema_version: integer() | nil,
          provider: String.t(),
          source: String.t(),
          collection_id: String.t() | nil,
          cursor: map(),
          counts: map(),
          objects: [map()],
          indicators: [map()],
          raw: map()
        }

  defstruct schema_version: nil,
            provider: @default_source,
            source: @default_source,
            collection_id: nil,
            cursor: %{},
            counts: %{},
            objects: [],
            indicators: [],
            raw: %{}

  @doc """
  Builds a provider-neutral page from a decoded CTI page map.
  """
  @spec from_map(map(), map()) :: t()
  def from_map(page, status \\ %{}) when is_map(page) and is_map(status) do
    source = source_for(page, status)

    %__MODULE__{
      schema_version: int_value(page, ["schema_version", "schemaVersion"]),
      provider: string_value(page, ["provider", "provider_id", "providerId"]) || source,
      source: source,
      collection_id: string_value(page, ["collection_id", "collectionId", "collection"]),
      cursor: map_value(page, ["cursor", "pagination", "page"]),
      counts: map_value(page, ["counts", "stats"]),
      indicators: list_value(page, ["indicators"]),
      objects: list_value(page, ["objects"]),
      raw: page
    }
  end

  @doc """
  Converts page indicators and STIX objects into `ThreatIntelIndicator` attrs.
  """
  @spec indicator_attrs(t(), DateTime.t(), keyword()) :: [map()]
  def indicator_attrs(page, observed_at, opts \\ [])

  def indicator_attrs(%__MODULE__{} = page, observed_at, opts)
      when is_struct(observed_at, DateTime) do
    max_indicators = Keyword.get(opts, :max_indicators, @default_max_indicators)

    normalized_indicators =
      page.indicators
      |> Enum.take(max_indicators)
      |> Enum.map(&normalize_indicator(&1, page, observed_at))
      |> Enum.reject(&is_nil/1)

    normalized_stix_objects =
      page.objects
      |> Enum.flat_map(&StixIndicator.attrs_from_object(&1, page.source, observed_at))
      |> Enum.take(max_indicators)

    (normalized_indicators ++ normalized_stix_objects)
    |> Enum.take(max_indicators)
    |> Enum.uniq_by(&{&1.source, &1.indicator})
  end

  def indicator_attrs(_page, _observed_at, _opts), do: []

  @doc """
  Converts provider page objects into source-object metadata attrs.
  """
  @spec source_object_attrs(t(), DateTime.t(), keyword()) :: [map()]
  def source_object_attrs(page, observed_at, opts \\ [])

  def source_object_attrs(%__MODULE__{} = page, observed_at, opts)
      when is_struct(observed_at, DateTime) do
    max_objects = Keyword.get(opts, :max_objects, @default_max_indicators)

    stix_objects =
      page.objects
      |> Enum.map(&object_attrs_from_stix(&1, page, observed_at))
      |> Enum.reject(&is_nil/1)

    inline_objects =
      page.indicators
      |> Enum.map(&object_attrs_from_indicator(&1, page, observed_at))
      |> Enum.reject(&is_nil/1)

    (stix_objects ++ inline_objects)
    |> Enum.take(max_objects)
    |> Enum.uniq_by(&{&1.source, &1.collection_id, &1.object_id, &1.object_version})
  end

  def source_object_attrs(_page, _observed_at, _opts), do: []

  @doc """
  Builds latest sync-status attrs for a provider page and plugin/core run.
  """
  @spec sync_status_attrs(t(), map(), map(), DateTime.t()) :: map()
  def sync_status_attrs(%__MODULE__{} = page, status, payload, observed_at)
      when is_map(status) and is_map(payload) and is_struct(observed_at, DateTime) do
    last_status =
      normalize_status(
        string_value(payload, ["status"]) || string_value(status, [:status, "status"])
      )

    success? = last_status in ["ok", "success"]

    %{
      provider: page.provider,
      source: page.source,
      collection_id: page.collection_id || "default",
      agent_id: string_value(status, [:agent_id, "agent_id"]) || "none",
      gateway_id: string_value(status, [:gateway_id, "gateway_id"]) || "none",
      plugin_id: string_value(status, [:plugin_id, "plugin_id"]) || "none",
      execution_mode:
        string_value(page.raw, ["execution_mode", "executionMode"]) || "edge_plugin",
      last_status: last_status,
      last_message: string_value(payload, ["summary", "message"]),
      last_error:
        if(success?, do: nil, else: string_value(payload, ["summary", "message", "error"])),
      last_attempt_at: observed_at,
      last_success_at: if(success?, do: observed_at),
      last_failure_at: if(success?, do: nil, else: observed_at),
      objects_count: count_value(page, ["objects"]),
      indicators_count: count_value(page, ["indicators"]),
      skipped_count: count_value(page, ["skipped", "skipped_indicators", "skippedIndicators"]),
      total_count: count_value(page, ["total"]),
      cursor: page.cursor,
      metadata: sync_metadata(page, status, payload)
    }
  end

  def sync_status_attrs(_page, _status, _payload, _observed_at), do: %{}

  defp normalize_indicator(entry, page, observed_at) when is_map(entry) do
    with indicator when is_binary(indicator) and indicator != "" <-
           string_value(entry, ["indicator", "value"]),
         {:ok, cidr} <- Cidr.cast_input(indicator, []) do
      %{
        indicator: cidr,
        indicator_type: "cidr",
        source: string_value(entry, ["source"]) || page.source,
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

  defp normalize_indicator(_entry, _page, _observed_at), do: nil

  defp object_attrs_from_stix(object, page, observed_at) when is_map(object) do
    object_id = string_value(object, ["id"])

    if is_binary(object_id) and object_id != "" do
      object_type = string_value(object, ["type"]) || "stix-object"
      modified_at = datetime_value(object, ["modified"]) || observed_at

      %{
        provider: page.provider,
        source: page.source,
        collection_id: page.collection_id,
        object_id: object_id,
        object_type: object_type,
        object_version: object_version(object, modified_at),
        spec_version: string_value(object, ["spec_version", "specVersion"]),
        date_added: datetime_value(object, ["date_added", "dateAdded", "created"]),
        modified_at: modified_at,
        raw_object_key: string_value(object, ["raw_object_key", "rawObjectKey"]),
        metadata: object_metadata(object)
      }
    end
  end

  defp object_attrs_from_stix(_object, _page, _observed_at), do: nil

  defp object_attrs_from_indicator(indicator, page, observed_at) when is_map(indicator) do
    object_id = string_value(indicator, ["source_object_id", "sourceObjectId"])

    if is_binary(object_id) and object_id != "" do
      modified_at =
        datetime_value(indicator, ["last_seen_at", "lastSeenAt", "modified"]) || observed_at

      %{
        provider: page.provider,
        source: string_value(indicator, ["source"]) || page.source,
        collection_id: page.collection_id,
        object_id: object_id,
        object_type:
          string_value(indicator, ["source_object_type", "sourceObjectType"]) || "provider-object",
        object_version: object_version(indicator, modified_at),
        spec_version: nil,
        date_added: datetime_value(indicator, ["first_seen_at", "firstSeenAt", "created"]),
        modified_at: modified_at,
        raw_object_key: string_value(indicator, ["raw_object_key", "rawObjectKey"]),
        metadata: indicator_object_metadata(indicator)
      }
    end
  end

  defp object_attrs_from_indicator(_indicator, _page, _observed_at), do: nil

  defp object_version(map, modified_at) do
    string_value(map, ["object_version", "objectVersion", "version", "modified"]) ||
      DateTime.to_iso8601(modified_at)
  end

  defp object_metadata(object) do
    object
    |> Map.take([
      "name",
      "description",
      "created_by_ref",
      "labels",
      "pattern",
      "pattern_type",
      "pattern_version",
      "valid_from",
      "valid_until",
      "revoked",
      "confidence",
      "lang"
    ])
    |> drop_nil_values()
  end

  defp indicator_object_metadata(indicator) do
    drop_nil_values(%{
      "label" => string_value(indicator, ["label", "title", "pulse_name", "pulseName"]),
      "source_context" => string_value(indicator, ["source_context", "sourceContext"]),
      "indicator" => string_value(indicator, ["indicator", "value"])
    })
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp source_for(page, status) do
    string_value(page, ["source", "provider", "provider_id", "providerId"]) ||
      string_value(status, [:plugin_id, "plugin_id"]) ||
      @default_source
  end

  defp label_for(entry, page) do
    string_value(entry, ["label", "title", "pulse_name", "pulseName"]) ||
      page.collection_id
  end

  defp count_value(%__MODULE__{} = page, keys) do
    case int_value(page.counts, keys) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp normalize_status(nil), do: "unknown"

  defp normalize_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "unknown"
      "healthy" -> "ok"
      "up" -> "ok"
      "warning" -> "warn"
      other -> other
    end
  end

  defp sync_metadata(page, status, payload) do
    drop_nil_values(%{
      "schema_version" => page.schema_version,
      "service_name" => string_value(status, [:service_name, "service_name"]),
      "service_type" => string_value(status, [:service_type, "service_type"]),
      "partition" => string_value(status, [:partition, "partition"]),
      "skipped_by_type" => non_empty_map_value(page.counts, ["skipped_by_type", "skippedByType"]),
      "labels" => map_value(payload, ["labels", "label"])
    })
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

  defp map_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp non_empty_map_value(map, keys) do
    case map_value(map, keys) do
      value when map_size(value) > 0 -> value
      _ -> nil
    end
  end

  defp string_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) and not is_nil(value) ->
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
