defmodule ServiceRadarWebNGWeb.DeviceLive.CameraData do
  @moduledoc false

  alias ServiceRadar.Camera.Source, as: CameraSource
  alias ServiceRadarWebNGWeb.DeviceLive.CameraComponents

  require Ash.Query

  @profile_load [stream_profiles: [:source_scheme]]

  @doc """
  The device's camera sources in display form
  (`CameraComponents.normalize_camera_sources_for_display/1`): what the page
  assigns holds no stream address and no profile structs.
  """
  def load_sources(scope, device_uid, device_row, format_error) when is_function(format_error, 1) do
    case CameraSource.list_for_device(device_uid, load: @profile_load, scope: scope) do
      {:ok, []} ->
        load_sources_by_fallback(scope, device_row, format_error)

      {:ok, sources} ->
        {CameraComponents.normalize_camera_sources_for_display(sources), nil}

      {:error, error} ->
        {[], "Failed to load camera inventory: #{format_error.(error)}"}
    end
  end

  defp load_sources_by_fallback(scope, device_row, format_error) do
    fallback_ids = camera_source_fallback_ids(device_row)

    if fallback_ids == [] do
      {[], nil}
    else
      query =
        CameraSource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(device_uid in ^fallback_ids)
        |> Ash.Query.load(@profile_load)
        |> Ash.Query.sort(inserted_at: :asc)

      case read_camera_sources(query, scope) do
        {:ok, sources} -> {CameraComponents.normalize_camera_sources_for_display(sources), nil}
        {:error, error} -> {[], "Failed to load camera inventory: #{format_error.(error)}"}
      end
    end
  end

  defp read_camera_sources(query, nil), do: Ash.read(query)
  defp read_camera_sources(query, scope), do: Ash.read(query, scope: scope)

  defp camera_source_fallback_ids(device_row) do
    mac =
      case device_row do
        %{} = row -> Map.get(row, :mac) || Map.get(row, "mac")
        _ -> nil
      end

    mac
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      trimmed = value |> to_string() |> String.trim()
      normalized = trimmed |> String.replace(":", "") |> String.upcase()

      [
        trimmed,
        String.upcase(trimmed),
        String.downcase(trimmed),
        normalized,
        String.downcase(normalized)
      ]
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
