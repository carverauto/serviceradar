defmodule ServiceRadarWebNG.FieldSurveyDashboardPlaylist do
  @moduledoc """
  FieldSurvey dashboard playlist management and SRQL preview validation.
  """

  alias ServiceRadar.Spatial.FieldSurveyDashboardPlaylistEntry
  alias ServiceRadarWebNG.SRQL

  @default_attrs %{
    label: "Latest FieldSurvey heatmap",
    srql_query: "in:field_survey_rasters overlay_type:wifi_rssi has_floorplan:true sort:generated_at:desc",
    enabled: true,
    sort_order: 0,
    overlay_type: "wifi_rssi",
    display_mode: "compact_heatmap",
    dwell_seconds: 30,
    max_age_seconds: 86_400,
    metadata: %{}
  }
  @fields Map.keys(@default_attrs)

  @spec defaults() :: map()
  def defaults, do: @default_attrs

  @spec list(any()) :: {:ok, list(FieldSurveyDashboardPlaylistEntry.t())} | {:error, term()}
  def list(scope) do
    FieldSurveyDashboardPlaylistEntry.list(scope: scope)
  end

  @spec get(any(), String.t()) ::
          {:ok, FieldSurveyDashboardPlaylistEntry.t()} | {:error, term()}
  def get(scope, id) when is_binary(id) do
    FieldSurveyDashboardPlaylistEntry.get_by_id(id, scope: scope)
  end

  @spec create(any(), map()) ::
          {:ok, FieldSurveyDashboardPlaylistEntry.t()} | {:error, term()}
  def create(scope, attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs),
         {:ok, _candidate} <- preview(scope, normalized.srql_query) do
      FieldSurveyDashboardPlaylistEntry.create(normalized, scope: scope)
    end
  end

  @spec update(any(), FieldSurveyDashboardPlaylistEntry.t(), map()) ::
          {:ok, FieldSurveyDashboardPlaylistEntry.t()} | {:error, term()}
  def update(scope, %FieldSurveyDashboardPlaylistEntry{} = entry, attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_attrs(Map.merge(entry_to_attrs(entry), attrs)),
         {:ok, _candidate} <- preview(scope, normalized.srql_query) do
      FieldSurveyDashboardPlaylistEntry.update(entry, normalized, scope: scope)
    end
  end

  @spec delete(any(), FieldSurveyDashboardPlaylistEntry.t()) :: :ok | {:error, term()}
  def delete(scope, %FieldSurveyDashboardPlaylistEntry{} = entry) do
    case FieldSurveyDashboardPlaylistEntry.destroy(entry, scope: scope) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec preview(any(), String.t()) :: {:ok, map()} | {:error, term()}
  def preview(_scope, query) when is_binary(query) do
    query = String.trim(query)

    with :ok <- require_raster_query(query),
         {:ok, %{"results" => results}} <- SRQL.query(query, %{limit: 1}) do
      case Enum.find(results, &raster_candidate?/1) do
        %{} = candidate -> {:ok, candidate}
        _ -> {:error, :no_field_survey_raster_candidate}
      end
    end
  end

  def preview(_scope, _query), do: {:error, :invalid_srql_query}

  defp require_raster_query(query) do
    if Regex.match?(
         ~r/(?:^|\s)in:(field_survey_rasters|fieldsurvey_rasters|survey_coverage_rasters|survey_rasters)(?:\s|$)/i,
         query
       ) do
      :ok
    else
      {:error, :playlist_query_must_target_field_survey_rasters}
    end
  end

  defp raster_candidate?(%{"entity" => "field_survey_raster", "raster_id" => id} = row) when is_binary(id),
    do: Map.get(row, "has_floorplan") == true

  defp raster_candidate?(%{"raster_id" => id} = row) when is_binary(id), do: Map.get(row, "has_floorplan") == true
  defp raster_candidate?(_), do: false

  defp normalize_attrs(attrs) when is_map(attrs) do
    merged = Map.merge(@default_attrs, atomize_keys(attrs))

    with {:ok, label} <- required_string(merged[:label], :label),
         {:ok, srql_query} <- required_string(merged[:srql_query], :srql_query),
         {:ok, overlay_type} <- required_string(merged[:overlay_type], :overlay_type),
         {:ok, display_mode} <- required_string(merged[:display_mode], :display_mode),
         {:ok, sort_order} <- integer_value(merged[:sort_order], :sort_order),
         {:ok, dwell_seconds} <- integer_value(merged[:dwell_seconds], :dwell_seconds),
         {:ok, max_age_seconds} <- integer_value(merged[:max_age_seconds], :max_age_seconds),
         {:ok, metadata} <- metadata_value(merged[:metadata]) do
      {:ok,
       %{
         label: label,
         srql_query: srql_query,
         enabled: boolean_value(merged[:enabled]),
         sort_order: sort_order,
         overlay_type: overlay_type,
         display_mode: display_mode,
         dwell_seconds: dwell_seconds,
         max_age_seconds: max_age_seconds,
         metadata: metadata
       }}
    end
  end

  defp atomize_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        if key in @fields, do: Map.put(acc, key, value), else: acc

      {key, value}, acc when is_binary(key) ->
        case Enum.find(@fields, &(Atom.to_string(&1) == key)) do
          nil -> acc
          field -> Map.put(acc, field, value)
        end

      _other, acc ->
        acc
    end)
  end

  defp entry_to_attrs(%FieldSurveyDashboardPlaylistEntry{} = entry) do
    %{
      label: entry.label,
      srql_query: entry.srql_query,
      enabled: entry.enabled,
      sort_order: entry.sort_order,
      overlay_type: entry.overlay_type,
      display_mode: entry.display_mode,
      dwell_seconds: entry.dwell_seconds,
      max_age_seconds: entry.max_age_seconds,
      metadata: entry.metadata || %{}
    }
  end

  defp required_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:required, field}}
      string -> {:ok, string}
    end
  end

  defp required_string(_value, field), do: {:error, {:required, field}}

  defp integer_value(value, _field) when is_integer(value), do: {:ok, value}

  defp integer_value(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, {:invalid_integer, field}}
    end
  end

  defp integer_value(_value, field), do: {:error, {:invalid_integer, field}}

  defp boolean_value(value) when value in [true, "true", "on", "1", 1], do: true
  defp boolean_value(_value), do: false

  defp metadata_value(value) when is_map(value), do: {:ok, value}

  defp metadata_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp metadata_value(_value), do: {:ok, %{}}
end
