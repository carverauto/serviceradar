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

  defp source_for(page, status) do
    string_value(page, ["source", "provider", "provider_id", "providerId"]) ||
      string_value(status, [:plugin_id, "plugin_id"]) ||
      @default_source
  end

  defp label_for(entry, page) do
    string_value(entry, ["label", "title", "pulse_name", "pulseName"]) ||
      page.collection_id
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
