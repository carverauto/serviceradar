defmodule ServiceRadarWebNG.FieldSurveyReview do
  @moduledoc """
  Builds backend FieldSurvey review data from raw RF, pose, and spectrum rows.
  """

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Spatial.SurveyCoverageRaster
  alias ServiceRadar.Spatial.SurveyPoseSample
  alias ServiceRadar.Spatial.SurveyRfObservation
  alias ServiceRadar.Spatial.SurveyRfPoseMatch
  alias ServiceRadar.Spatial.SurveyRoomArtifact
  alias ServiceRadar.Spatial.SurveySpectrumObservation
  alias ServiceRadarWebNG.FieldSurveyRoomArtifacts

  require Ash.Query
  require Logger

  @default_recent_limit 100_000
  @default_session_limit 25_000
  @default_spectrum_limit 2_000
  @default_spatial_limit 10_000
  @default_artifact_limit 200
  @default_cell_size_m 0.75
  @default_raster_cell_size_m 0.42
  @default_waterfall_rows 80
  @default_waterfall_bins 96
  @max_raster_cells 1_400

  @type session_summary :: %{
          id: String.t(),
          first_seen: DateTime.t() | nil,
          last_seen: DateTime.t() | nil,
          rf_count: non_neg_integer(),
          spectrum_count: non_neg_integer(),
          ap_count: non_neg_integer()
        }

  @type review :: %{
          session_id: String.t(),
          metrics: map(),
          bounds: map(),
          wifi_points: [map()],
          wifi_raster: [map()],
          interference_points: [map()],
          interference_raster: [map()],
          spectrum_waterfall: map(),
          path_points: [map()],
          floorplan_segments: [map()],
          ap_summaries: [map()],
          channel_scores: [map()]
        }

  @spec list_sessions(any(), keyword()) :: {:ok, [session_summary()]} | {:error, any()}
  def list_sessions(scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_recent_limit)

    with {:ok, rf_rows} <- read_rf_rows(scope, limit),
         {:ok, spectrum_rows} <- read_spectrum_rows(scope, limit) do
      {:ok, build_session_summaries(rf_rows, spectrum_rows)}
    end
  end

  @spec get_review(any(), String.t(), keyword()) :: {:ok, review()} | {:error, any()}
  def get_review(scope, session_id, opts \\ []) when is_binary(session_id) do
    rf_limit = Keyword.get(opts, :rf_limit, @default_session_limit)
    pose_limit = Keyword.get(opts, :pose_limit, @default_session_limit)
    spectrum_limit = Keyword.get(opts, :spectrum_limit, @default_spectrum_limit)
    cell_size_m = Keyword.get(opts, :cell_size_m, @default_cell_size_m)

    with {:ok, rf_matches} <- read_rf_pose_matches(scope, session_id, rf_limit),
         {:ok, pose_samples} <- read_pose_samples(scope, session_id, pose_limit),
         {:ok, spectrum_rows} <- read_spectrum_rows(scope, session_id, spectrum_limit),
         {:ok, room_artifacts} <- read_room_artifacts(scope, session_id) do
      floorplan_segments = load_floorplan_segments(scope, session_id)
      user_id = scope_user_id(scope)
      wifi_points = build_wifi_points(rf_matches, cell_size_m)
      interference_points = build_interference_points(spectrum_rows, pose_samples, rf_matches, cell_size_m)

      {wifi_raster, wifi_raster_source} =
        reusable_coverage_raster(scope, session_id, user_id, "wifi_rssi", "wifi_point_count", length(wifi_points))

      {interference_raster, interference_raster_source} =
        reusable_coverage_raster(
          scope,
          session_id,
          user_id,
          "rf_interference",
          "interference_point_count",
          length(interference_points)
        )

      review =
        build_review(session_id, rf_matches, pose_samples, spectrum_rows,
          cell_size_m: cell_size_m,
          floorplan_segments: floorplan_segments,
          room_artifacts: room_artifacts,
          wifi_points: wifi_points,
          wifi_raster: wifi_raster,
          interference_points: interference_points,
          interference_raster: interference_raster
        )

      if wifi_raster_source == :persisted and interference_raster_source == :persisted do
        {:ok, review}
      else
        {:ok, maybe_persist_coverage_rasters(scope, review)}
      end
    end
  end

  @spec spatial_samples(any(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def spatial_samples(scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_spatial_limit)

    with {:ok, rows} <- read_spatial_rf_pose_matches(scope, limit) do
      {:ok, Enum.map(rows, &spatial_sample/1)}
    end
  end

  @spec spatial_scene(any(), keyword()) :: {:ok, map()} | {:error, any()}
  def spatial_scene(scope, opts \\ []) do
    sample_limit = Keyword.get(opts, :sample_limit, @default_spatial_limit)
    artifact_limit = Keyword.get(opts, :artifact_limit, @default_artifact_limit)

    with {:ok, samples} <- spatial_samples(scope, limit: sample_limit),
         {:ok, artifacts} <- room_artifacts(scope, limit: artifact_limit) do
      selected_session_id = latest_artifact_session_id(artifacts) || latest_sample_session_id(samples)
      floorplan_segments = if selected_session_id, do: load_floorplan_segments(scope, selected_session_id), else: []

      {:ok,
       %{
         selected_session_id: selected_session_id,
         samples: samples,
         artifacts: artifacts,
         floorplan_segments: floorplan_segments,
         point_cloud_artifact: Enum.find(artifacts, &(&1.artifact_type == "point_cloud_ply")),
         roomplan_artifact: Enum.find(artifacts, &(&1.artifact_type == "roomplan_usdz"))
       }}
    end
  end

  @spec room_artifacts(any(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def room_artifacts(scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_artifact_limit)

    SurveyRoomArtifact
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(uploaded_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &room_artifact_summary/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec room_artifact(any(), String.t()) :: {:ok, map()} | {:error, :not_found | any()}
  def room_artifact(scope, artifact_id) when is_binary(artifact_id) do
    SurveyRoomArtifact
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^artifact_id)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
    |> case do
      {:ok, [artifact | _]} -> {:ok, room_artifact_summary(artifact)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_review(String.t(), list(), list(), list(), keyword()) :: review()
  def build_review(session_id, rf_matches, pose_samples, spectrum_rows, opts \\ []) do
    cell_size_m = Keyword.get(opts, :cell_size_m, @default_cell_size_m)
    floorplan_segments = Keyword.get(opts, :floorplan_segments, [])
    room_artifacts = Keyword.get(opts, :room_artifacts, [])
    wifi_points = Keyword.get_lazy(opts, :wifi_points, fn -> build_wifi_points(rf_matches, cell_size_m) end)
    wifi_raster = Keyword.get(opts, :wifi_raster) || build_wifi_raster(rf_matches, floorplan_segments)
    path_points = build_path_points(pose_samples, rf_matches)
    channel_scores = build_channel_scores(spectrum_rows, rf_matches)

    interference_points =
      Keyword.get_lazy(opts, :interference_points, fn ->
        build_interference_points(spectrum_rows, pose_samples, rf_matches, cell_size_m)
      end)

    interference_raster =
      Keyword.get(opts, :interference_raster) || build_interference_raster(interference_points, floorplan_segments)

    spectrum_waterfall = build_spectrum_waterfall(spectrum_rows)

    bounds =
      bounds_for(wifi_points, wifi_raster, interference_points, interference_raster, path_points, floorplan_segments)

    ap_summaries = build_ap_summaries(rf_matches)

    %{
      session_id: session_id,
      metrics: %{
        rf_count: length(rf_matches),
        pose_count: length(pose_samples),
        spectrum_count: length(spectrum_rows),
        room_artifact_count: length(room_artifacts),
        wifi_point_count: length(wifi_points),
        wifi_raster_cell_count: length(wifi_raster),
        interference_point_count: length(interference_points),
        interference_raster_cell_count: length(interference_raster),
        waterfall_row_count: length(Map.get(spectrum_waterfall, :rows, [])),
        waterfall_bin_count: Map.get(spectrum_waterfall, :bin_count, 0),
        floorplan_segment_count: length(floorplan_segments),
        ap_count: length(ap_summaries),
        channel_count: length(channel_scores)
      },
      bounds: bounds,
      wifi_points: project_points(wifi_points, bounds),
      wifi_raster: project_raster_cells(wifi_raster, bounds),
      interference_points: project_points(interference_points, bounds),
      interference_raster: project_raster_cells(interference_raster, bounds),
      spectrum_waterfall: spectrum_waterfall,
      path_points: project_points(path_points, bounds),
      floorplan_segments: project_floorplan_segments(floorplan_segments, bounds),
      room_artifacts: Enum.map(room_artifacts, &room_artifact_summary/1),
      ap_summaries: ap_summaries,
      channel_scores: channel_scores
    }
  end

  @spec normalize_power(number() | nil) :: non_neg_integer()
  def normalize_power(nil), do: 0

  def normalize_power(power_dbm) when is_number(power_dbm) do
    power_dbm
    |> then(&((&1 + 95.0) / 45.0 * 100.0))
    |> min(100.0)
    |> max(0.0)
    |> round()
  end

  defp read_rf_rows(scope, limit) do
    SurveyRfObservation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(captured_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
  end

  defp read_spectrum_rows(scope, limit) when is_integer(limit) do
    SurveySpectrumObservation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(captured_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
  end

  defp read_spectrum_rows(scope, session_id, limit) do
    SurveySpectrumObservation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.Query.sort(captured_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
  end

  defp read_pose_samples(scope, session_id, limit) do
    SurveyPoseSample
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.Query.sort(captured_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
  end

  defp read_rf_pose_matches(scope, session_id, limit) do
    SurveyRfPoseMatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(session_id == ^session_id and not is_nil(x) and not is_nil(z) and not is_nil(rssi_dbm))
    |> Ash.Query.sort(rf_captured_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
  end

  defp read_spatial_rf_pose_matches(scope, limit) do
    SurveyRfPoseMatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(not is_nil(x) and not is_nil(z) and not is_nil(rssi_dbm))
    |> Ash.Query.sort(rf_captured_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
  end

  defp read_latest_floorplan_artifact(scope, session_id) do
    SurveyRoomArtifact
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(session_id == ^session_id and artifact_type == "floorplan_geojson")
    |> Ash.Query.sort(uploaded_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
    |> case do
      {:ok, [artifact | _]} -> {:ok, artifact}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_room_artifacts(scope, session_id) do
    SurveyRoomArtifact
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.Query.sort(uploaded_at: :desc)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
  end

  defp read_latest_coverage_raster(scope, session_id, user_id, overlay_type) do
    SurveyCoverageRaster
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      session_id == ^session_id and user_id == ^user_id and overlay_type == ^overlay_type and selector_type == "all" and
        selector_value == "*"
    )
    |> Ash.Query.sort(generated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
    |> case do
      {:ok, [raster | _]} -> {:ok, raster}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp spatial_sample(row) do
    %{
      id: field(row, :rf_observation_id),
      session_id: field(row, :session_id),
      bssid: field(row, :bssid),
      ssid: field(row, :ssid) || "Hidden",
      rssi: field(row, :rssi_dbm),
      frequency: field(row, :frequency_mhz),
      x: field(row, :x),
      y: field(row, :y) || 0.0,
      z: field(row, :z),
      latitude: field(row, :latitude),
      longitude: field(row, :longitude),
      timestamp: field(row, :rf_captured_at)
    }
  end

  defp room_artifact_summary(row) do
    %{
      id: field(row, :id),
      session_id: field(row, :session_id),
      artifact_type: field(row, :artifact_type),
      content_type: field(row, :content_type),
      object_key: field(row, :object_key),
      byte_size: field(row, :byte_size),
      sha256: field(row, :sha256),
      captured_at: field(row, :captured_at),
      uploaded_at: field(row, :uploaded_at),
      metadata: field(row, :metadata) || %{},
      download_url: "/api/spatial/room-artifacts/#{field(row, :id)}/download"
    }
  end

  defp reusable_coverage_raster(scope, session_id, user_id, overlay_type, count_key, source_count) do
    case read_latest_coverage_raster(scope, session_id, user_id, overlay_type) do
      {:ok, raster} ->
        reusable_raster_cells(raster, count_key, source_count)

      {:error, reason} ->
        Logger.debug("FieldSurvey persisted #{overlay_type} raster read skipped: #{inspect(reason)}")
        {nil, :missing}
    end
  end

  defp reusable_raster_cells(nil, _count_key, _source_count), do: {nil, :missing}

  defp reusable_raster_cells(raster, count_key, source_count) do
    metadata = field(raster, :metadata) || %{}
    stored_point_count = map_value(metadata, count_key)
    cells = map_value(field(raster, :cells) || %{}, "cells") || []

    if stored_point_count == source_count and is_list(cells) and cells != [] do
      reusable_cells = cells |> Enum.map(&persisted_raster_cell/1) |> Enum.reject(&is_nil/1)

      case reusable_cells do
        [] -> {nil, :stale}
        [_ | _] -> {reusable_cells, :persisted}
      end
    else
      {nil, :stale}
    end
  end

  defp persisted_raster_cell(cell) when is_map(cell) do
    with x when is_number(x) <- map_value(cell, "x"),
         z when is_number(z) <- map_value(cell, "z") do
      value =
        cond do
          is_number(map_value(cell, "rssi")) -> %{rssi: map_value(cell, "rssi") * 1.0}
          is_number(map_value(cell, "score")) -> %{score: map_value(cell, "score") * 1.0}
          true -> %{}
        end

      Map.merge(
        %{
          x: x * 1.0,
          y: 0.0,
          z: z * 1.0,
          confidence: number_or_default(map_value(cell, "confidence"), 0.5),
          nearest_distance_m: number_or_default(map_value(cell, "nearest_distance_m"), 0.0),
          count: number_or_default(map_value(cell, "count"), 1),
          radius_m: number_or_default(map_value(cell, "radius_m"), @default_raster_cell_size_m * 0.72)
        },
        value
      )
    else
      _ -> nil
    end
  end

  defp persisted_raster_cell(_cell), do: nil

  defp maybe_persist_coverage_rasters(scope, review) do
    user_id = scope_user_id(scope)

    [
      coverage_raster_attrs(
        review,
        user_id,
        "wifi_rssi",
        review.wifi_raster,
        "wifi_point_count",
        review.metrics.wifi_point_count
      ),
      coverage_raster_attrs(
        review,
        user_id,
        "rf_interference",
        review.interference_raster,
        "interference_point_count",
        review.metrics.interference_point_count
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&persist_coverage_raster(scope, &1))

    review
  end

  defp persist_coverage_raster(scope, attrs) do
    SurveyCoverageRaster
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create(scope: scope, domain: ServiceRadar.Spatial)
    |> case do
      {:ok, _raster} ->
        :ok

      {:error, reason} ->
        Logger.warning("FieldSurvey coverage raster persistence failed: #{inspect(reason)}")
        :error
    end
  end

  defp coverage_raster_attrs(_review, _user_id, _overlay_type, [], _count_key, _source_count), do: nil

  defp coverage_raster_attrs(review, user_id, overlay_type, raster_cells, count_key, source_count) do
    bounds = review.bounds
    cells = Enum.map(raster_cells, &coverage_raster_cell/1)
    cell_size_m = inferred_cell_size_m(raster_cells)
    columns = max(round((bounds.max_x - bounds.min_x) / max(cell_size_m, 0.01)), 1)
    rows = max(round((bounds.max_z - bounds.min_z) / max(cell_size_m, 0.01)), 1)

    %{
      session_id: review.session_id,
      user_id: user_id,
      overlay_type: overlay_type,
      selector_type: "all",
      selector_value: "*",
      cell_size_m: cell_size_m,
      min_x: bounds.min_x,
      max_x: bounds.max_x,
      min_z: bounds.min_z,
      max_z: bounds.max_z,
      columns: columns,
      rows: rows,
      cells: %{"cells" => cells},
      metadata: %{
        "algorithm" => "rbf_kernel_raster_v1",
        "masked_by" => "floorplan_convex_hull",
        "cell_count" => length(cells),
        count_key => source_count
      },
      generated_at: DateTime.utc_now()
    }
  end

  defp coverage_raster_cell(cell) do
    %{
      "x" => cell.x,
      "z" => cell.z,
      "rssi" => Map.get(cell, :rssi),
      "score" => Map.get(cell, :score),
      "confidence" => cell.confidence,
      "nearest_distance_m" => cell.nearest_distance_m,
      "radius_m" => cell.radius_m,
      "x_pct" => cell.x_pct,
      "z_pct" => cell.z_pct,
      "radius_pct" => cell.radius_pct,
      "count" => cell.count
    }
  end

  defp inferred_cell_size_m([cell | _]), do: max((cell.radius_m || @default_raster_cell_size_m * 0.72) / 0.72, 0.01)
  defp inferred_cell_size_m([]), do: @default_raster_cell_size_m

  defp scope_user_id(%{user: %{id: id}}) when not is_nil(id), do: to_string(id)
  defp scope_user_id(_scope), do: "system"

  defp latest_artifact_session_id([artifact | _]), do: artifact.session_id
  defp latest_artifact_session_id([]), do: nil

  defp latest_sample_session_id([sample | _]), do: sample.session_id
  defp latest_sample_session_id([]), do: nil

  defp build_session_summaries(rf_rows, spectrum_rows) do
    rf_sessions =
      Enum.reduce(rf_rows, %{}, fn row, acc ->
        session_id = field(row, :session_id)

        Map.update(acc, session_id, base_session(session_id), fn session ->
          session
          |> bump(:rf_count)
          |> update_seen(field(row, :captured_at))
          |> put_ap(field(row, :bssid))
        end)
      end)

    spectrum_sessions =
      Enum.reduce(spectrum_rows, rf_sessions, fn row, acc ->
        session_id = field(row, :session_id)

        Map.update(acc, session_id, base_session(session_id), fn session ->
          session
          |> bump(:spectrum_count)
          |> update_seen(field(row, :captured_at))
        end)
      end)

    spectrum_sessions
    |> Map.values()
    |> Enum.map(fn session ->
      session
      |> Map.put(:ap_count, MapSet.size(session.ap_set))
      |> Map.delete(:ap_set)
    end)
    |> Enum.sort_by(&(&1.last_seen || &1.first_seen || DateTime.from_unix!(0)), {:desc, DateTime})
  end

  defp base_session(session_id) do
    %{id: session_id, first_seen: nil, last_seen: nil, rf_count: 0, spectrum_count: 0, ap_set: MapSet.new()}
  end

  defp bump(session, key), do: Map.update!(session, key, &(&1 + 1))

  defp put_ap(session, bssid) when is_binary(bssid) and bssid != "" do
    Map.update!(session, :ap_set, &MapSet.put(&1, bssid))
  end

  defp put_ap(session, _bssid), do: session

  defp update_seen(session, nil), do: session

  defp update_seen(session, timestamp) do
    first_seen =
      case session.first_seen do
        nil -> timestamp
        existing -> min_datetime(existing, timestamp)
      end

    last_seen =
      case session.last_seen do
        nil -> timestamp
        existing -> max_datetime(existing, timestamp)
      end

    %{session | first_seen: first_seen, last_seen: last_seen}
  end

  defp build_wifi_points(rf_matches, cell_size_m) do
    rf_matches
    |> Enum.filter(&(number?(field(&1, :x)) and number?(field(&1, :z)) and number?(field(&1, :rssi_dbm))))
    |> Enum.group_by(fn row -> bucket_key(field(row, :x), field(row, :z), cell_size_m) end)
    |> Enum.map(fn {_bucket, rows} -> summarize_wifi_bucket(rows) end)
    |> Enum.sort_by(& &1.rssi, :desc)
  end

  defp summarize_wifi_bucket(rows) do
    count = length(rows)
    strongest = Enum.max_by(rows, &field(&1, :rssi_dbm))

    %{
      x: average(rows, :x),
      y: average(rows, :y),
      z: average(rows, :z),
      rssi: average(rows, :rssi_dbm),
      strongest_rssi: field(strongest, :rssi_dbm),
      bssid: field(strongest, :bssid),
      ssid: field(strongest, :ssid) || "Hidden",
      count: count
    }
  end

  defp build_wifi_raster(rf_matches, floorplan_segments) do
    observations =
      rf_matches
      |> Enum.filter(&(number?(field(&1, :x)) and number?(field(&1, :z)) and number?(field(&1, :rssi_dbm))))
      |> Enum.group_by(fn row -> bucket_key(field(row, :x), field(row, :z), @default_raster_cell_size_m) end)
      |> Enum.map(fn {_bucket, rows} ->
        %{
          x: average(rows, :x),
          y: average(rows, :y) || 0.0,
          z: average(rows, :z),
          rssi: average(rows, :rssi_dbm),
          count: length(rows)
        }
      end)

    with [_ | _] <- observations,
         %{min_x: min_x, max_x: max_x, min_z: min_z, max_z: max_z} <- raster_bounds(observations, floorplan_segments) do
      hull = floorplan_hull(floorplan_segments)
      span = max(max_x - min_x, max_z - min_z)
      cell_size = raster_cell_size(span)
      length_scale = max(span / 4.8, 1.25)
      max_distance = max(span * 0.42, 2.2)

      min_x
      |> grid_values(max_x, cell_size)
      |> Enum.flat_map(fn x ->
        min_z
        |> grid_values(max_z, cell_size)
        |> Enum.map(fn z -> {x, z} end)
      end)
      |> Enum.filter(fn {x, z} -> hull == [] or point_in_polygon?({x, z}, hull) end)
      |> Enum.map(fn {x, z} -> interpolate_rssi_cell(x, z, observations, length_scale, max_distance, cell_size) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@max_raster_cells)
    else
      _ -> []
    end
  end

  defp raster_bounds(_observations, [_ | _] = floorplan_segments) do
    points = floorplan_segment_points(floorplan_segments)
    xs = Enum.map(points, & &1.x)
    zs = Enum.map(points, & &1.z)
    pad = 0.35

    %{
      min_x: Enum.min(xs) - pad,
      max_x: Enum.max(xs) + pad,
      min_z: Enum.min(zs) - pad,
      max_z: Enum.max(zs) + pad
    }
  end

  defp raster_bounds(observations, _floorplan_segments) do
    xs = Enum.map(observations, & &1.x)
    zs = Enum.map(observations, & &1.z)
    pad = 1.5

    %{
      min_x: Enum.min(xs) - pad,
      max_x: Enum.max(xs) + pad,
      min_z: Enum.min(zs) - pad,
      max_z: Enum.max(zs) + pad
    }
  end

  defp raster_cell_size(span) do
    estimated_cells = :math.pow(max(span, 1.0) / @default_raster_cell_size_m, 2)

    if estimated_cells > @max_raster_cells do
      max(span / :math.sqrt(@max_raster_cells), @default_raster_cell_size_m)
    else
      @default_raster_cell_size_m
    end
  end

  defp grid_values(min, max, step) do
    Stream.unfold(min, fn value ->
      if value <= max do
        {value, value + step}
      end
    end)
  end

  defp interpolate_rssi_cell(x, z, observations, length_scale, max_distance, cell_size) do
    {weighted_sum, weight_sum, nearest_distance, count_sum} =
      Enum.reduce(observations, {0.0, 0.0, :infinity, 0}, fn observation,
                                                             {weighted_acc, weight_acc, nearest, count_acc} ->
        distance = distance_2d(x, z, observation.x, observation.z)

        weight =
          :math.exp(-:math.pow(distance, 2) / (2.0 * :math.pow(length_scale, 2))) * :math.log2(observation.count + 1)

        {
          weighted_acc + observation.rssi * weight,
          weight_acc + weight,
          min(nearest, distance),
          count_acc + observation.count
        }
      end)

    cond do
      weight_sum <= 0.0001 ->
        nil

      nearest_distance > max_distance ->
        nil

      true ->
        confidence = weight_sum / (weight_sum + 8.0 + max(nearest_distance - cell_size, 0.0) * 2.0)

        %{
          x: x,
          y: 0.0,
          z: z,
          rssi: weighted_sum / weight_sum,
          confidence: min(max(confidence, 0.08), 0.92),
          nearest_distance_m: nearest_distance,
          count: count_sum,
          radius_m: cell_size * 0.72
        }
    end
  end

  defp build_path_points(pose_samples, rf_matches) do
    source =
      case pose_samples do
        [] -> rf_matches
        [_ | _] -> pose_samples
      end

    source
    |> Enum.filter(&(number?(field(&1, :x)) and number?(field(&1, :z))))
    |> Enum.sort_by(&(field(&1, :captured_at_unix_nanos) || field(&1, :pose_captured_at_unix_nanos) || 0), :asc)
    |> Enum.take_every(max(div(length(source), 250), 1))
    |> Enum.map(fn row ->
      %{
        x: field(row, :x),
        y: field(row, :y) || 0.0,
        z: field(row, :z),
        count: 1
      }
    end)
  end

  defp build_interference_points(spectrum_rows, pose_samples, rf_matches, cell_size_m) do
    poses = Enum.filter(pose_samples ++ rf_matches, &(number?(field(&1, :x)) and number?(field(&1, :z))))

    spectrum_rows
    |> Enum.map(fn row -> {row, nearest_pose(row, poses)} end)
    |> Enum.reject(fn {_row, pose} -> is_nil(pose) end)
    |> Enum.map(fn {row, pose} ->
      summary = summarize_spectrum(row)

      %{
        x: field(pose, :x),
        y: field(pose, :y) || 0.0,
        z: field(pose, :z),
        score: summary.score,
        average_power_dbm: summary.average_power_dbm,
        peak_power_dbm: summary.peak_power_dbm,
        peak_frequency_mhz: summary.peak_frequency_mhz,
        count: 1
      }
    end)
    |> Enum.group_by(fn point -> bucket_key(point.x, point.z, cell_size_m) end)
    |> Enum.map(fn {_bucket, points} -> summarize_interference_bucket(points) end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp build_interference_raster([], _floorplan_segments), do: []

  defp build_interference_raster(interference_points, floorplan_segments) do
    case raster_bounds(interference_points, floorplan_segments) do
      %{min_x: min_x, max_x: max_x, min_z: min_z, max_z: max_z} ->
        hull = floorplan_hull(floorplan_segments)
        span = max(max_x - min_x, max_z - min_z)
        cell_size = raster_cell_size(span)
        length_scale = max(span / 4.0, 1.1)
        max_distance = max(span * 0.38, 1.8)

        min_x
        |> grid_values(max_x, cell_size)
        |> Enum.flat_map(fn x ->
          min_z
          |> grid_values(max_z, cell_size)
          |> Enum.map(fn z -> {x, z} end)
        end)
        |> Enum.filter(fn {x, z} -> hull == [] or point_in_polygon?({x, z}, hull) end)
        |> Enum.map(fn {x, z} ->
          interpolate_interference_cell(x, z, interference_points, length_scale, max_distance, cell_size)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(@max_raster_cells)

      _ ->
        []
    end
  end

  defp interpolate_interference_cell(x, z, observations, length_scale, max_distance, cell_size) do
    {weighted_sum, weight_sum, nearest_distance, count_sum} =
      Enum.reduce(observations, {0.0, 0.0, :infinity, 0}, fn observation,
                                                             {weighted_acc, weight_acc, nearest, count_acc} ->
        distance = distance_2d(x, z, observation.x, observation.z)

        weight =
          :math.exp(-:math.pow(distance, 2) / (2.0 * :math.pow(length_scale, 2))) * :math.log2(observation.count + 1)

        {
          weighted_acc + observation.score * weight,
          weight_acc + weight,
          min(nearest, distance),
          count_acc + observation.count
        }
      end)

    cond do
      weight_sum <= 0.0001 ->
        nil

      nearest_distance > max_distance ->
        nil

      true ->
        confidence = weight_sum / (weight_sum + 10.0 + max(nearest_distance - cell_size, 0.0) * 2.5)

        %{
          x: x,
          y: 0.0,
          z: z,
          score: weighted_sum / weight_sum,
          confidence: min(max(confidence, 0.06), 0.88),
          nearest_distance_m: nearest_distance,
          count: count_sum,
          radius_m: cell_size * 0.72
        }
    end
  end

  defp summarize_interference_bucket(points) do
    peak = Enum.max_by(points, & &1.peak_power_dbm)

    %{
      x: average_maps(points, :x),
      y: average_maps(points, :y),
      z: average_maps(points, :z),
      score: average_maps(points, :score),
      average_power_dbm: average_maps(points, :average_power_dbm),
      peak_power_dbm: peak.peak_power_dbm,
      peak_frequency_mhz: peak.peak_frequency_mhz,
      count: length(points)
    }
  end

  defp build_channel_scores(spectrum_rows, rf_matches) do
    ap_channels = ap_channel_summary(rf_matches)

    spectrum_rows
    |> Enum.flat_map(&channel_scores_for_spectrum/1)
    |> Enum.group_by(&{&1.band, &1.channel})
    |> Enum.map(fn {{band, channel}, scores} ->
      peak = Enum.max_by(scores, & &1.peak_power_dbm)
      ap_summary = Map.get(ap_channels, channel_key(band, channel), %{ap_count: 0, strongest_rssi: nil})
      score = Enum.max(Enum.map(scores, & &1.score))

      %{
        band: band,
        channel: channel,
        center_frequency_mhz: peak.center_frequency_mhz,
        score: score,
        average_power_dbm: average_maps(scores, :average_power_dbm),
        peak_power_dbm: peak.peak_power_dbm,
        baseline_power_dbm: average_maps(scores, :baseline_power_dbm),
        sample_count: Enum.reduce(scores, 0, &(&1.sample_count + &2)),
        ap_count: ap_summary.ap_count,
        strongest_rssi: ap_summary.strongest_rssi,
        conflict: ap_summary.ap_count > 0 and score >= 55
      }
    end)
    |> Enum.sort_by(&{&1.band, &1.channel})
  end

  defp ap_channel_summary(rf_matches) do
    rf_matches
    |> Enum.filter(&(number?(field(&1, :channel)) and number?(field(&1, :frequency_mhz))))
    |> Enum.group_by(fn row -> channel_key(band_for_frequency(field(row, :frequency_mhz)), field(row, :channel)) end)
    |> Map.new(fn {key, rows} ->
      strongest =
        rows
        |> Enum.map(&field(&1, :rssi_dbm))
        |> Enum.filter(&number?/1)
        |> Enum.max(fn -> nil end)

      {key,
       %{
         ap_count: rows |> Enum.map(&field(&1, :bssid)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
         strongest_rssi: strongest
       }}
    end)
  end

  defp channel_key(band, channel), do: {band, channel}

  defp band_for_frequency(frequency_mhz) when frequency_mhz < 3_000, do: "2.4GHz"
  defp band_for_frequency(_frequency_mhz), do: "5GHz"

  defp build_spectrum_waterfall(spectrum_rows) do
    rows =
      spectrum_rows
      |> Enum.sort_by(&(field(&1, :captured_at_unix_nanos) || 0), :asc)
      |> Enum.take(-@default_waterfall_rows)
      |> Enum.map(&waterfall_row/1)
      |> Enum.reject(&is_nil/1)

    %{
      rows: rows,
      row_count: length(rows),
      bin_count: rows |> List.first(%{}) |> Map.get(:bin_count, 0),
      min_power_dbm: rows |> Enum.flat_map(& &1.bins) |> Enum.map(& &1.power_dbm) |> Enum.min(fn -> nil end),
      max_power_dbm: rows |> Enum.flat_map(& &1.bins) |> Enum.map(& &1.power_dbm) |> Enum.max(fn -> nil end)
    }
  end

  defp waterfall_row(row) do
    powers = field(row, :power_bins_dbm) || []

    case downsample_powers(powers, @default_waterfall_bins) do
      [] ->
        nil

      bins ->
        start_hz = field(row, :start_frequency_hz) || 0
        stop_hz = field(row, :stop_frequency_hz) || start_hz
        bin_count = length(bins)
        frequency_span_mhz = max((stop_hz - start_hz) / 1_000_000.0, 0.0)

        %{
          captured_at_unix_nanos: field(row, :captured_at_unix_nanos),
          start_frequency_mhz: start_hz / 1_000_000.0,
          stop_frequency_mhz: stop_hz / 1_000_000.0,
          bin_count: bin_count,
          average_power_dbm: average_numbers(powers) || -100.0,
          baseline_power_dbm: percentile(powers, 0.5) || -100.0,
          peak_power_dbm: Enum.max(powers, fn -> -100.0 end),
          bins:
            bins
            |> Enum.with_index()
            |> Enum.map(fn {power, index} ->
              %{
                index: index,
                frequency_mhz: start_hz / 1_000_000.0 + frequency_span_mhz * ((index + 0.5) / max(bin_count, 1)),
                power_dbm: power,
                intensity: normalize_power(power)
              }
            end)
        }
    end
  end

  defp downsample_powers([], _target_count), do: []

  defp downsample_powers(powers, target_count) when length(powers) <= target_count do
    Enum.map(powers, &(&1 * 1.0))
  end

  defp downsample_powers(powers, target_count) do
    chunk_size = (length(powers) / target_count) |> Float.ceil() |> trunc()

    powers
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(fn chunk -> average_numbers(chunk) || -100.0 end)
    |> Enum.take(target_count)
  end

  defp build_ap_summaries(rf_matches) do
    rf_matches
    |> Enum.filter(&(is_binary(field(&1, :bssid)) and number?(field(&1, :rssi_dbm))))
    |> Enum.group_by(&field(&1, :bssid))
    |> Enum.map(fn {bssid, rows} ->
      strongest = Enum.max_by(rows, &field(&1, :rssi_dbm))

      %{
        bssid: bssid,
        ssid: field(strongest, :ssid) || "Hidden",
        count: length(rows),
        strongest_rssi: field(strongest, :rssi_dbm),
        channel: field(strongest, :channel),
        frequency_mhz: field(strongest, :frequency_mhz)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp load_floorplan_segments(scope, session_id) do
    with {:ok, artifact} when not is_nil(artifact) <- read_latest_floorplan_artifact(scope, session_id),
         {:ok, payload} <- FieldSurveyRoomArtifacts.fetch(field(artifact, :object_key)),
         {:ok, geojson} <- Jason.decode(payload) do
      decode_floorplan_geojson(geojson)
    else
      {:ok, nil} -> []
      _error -> []
    end
  end

  defp decode_floorplan_geojson(%{"type" => "FeatureCollection", "features" => features}) when is_list(features) do
    features
    |> Enum.flat_map(&decode_floorplan_feature/1)
    |> Enum.reject(&zero_length_segment?/1)
  end

  defp decode_floorplan_geojson(_geojson), do: []

  defp decode_floorplan_feature(%{
         "geometry" => %{"type" => "LineString", "coordinates" => [start_coord, end_coord | _]},
         "properties" => properties
       }) do
    with {:ok, start_x, start_z} <- decode_coordinate(start_coord),
         {:ok, end_x, end_z} <- decode_coordinate(end_coord) do
      [
        %{
          kind: normalize_floorplan_kind(Map.get(properties || %{}, "kind")),
          start_x: start_x,
          start_z: start_z,
          end_x: end_x,
          end_z: end_z,
          height: number_or_nil(Map.get(properties || %{}, "height_m"))
        }
      ]
    else
      _error -> []
    end
  end

  defp decode_floorplan_feature(_feature), do: []

  defp decode_coordinate([x, z | _]) when is_number(x) and is_number(z), do: {:ok, x * 1.0, z * 1.0}
  defp decode_coordinate(_coord), do: :error

  defp normalize_floorplan_kind(kind) when kind in ["wall", "door", "window"], do: kind
  defp normalize_floorplan_kind(_kind), do: "wall"

  defp zero_length_segment?(segment) do
    segment.start_x == segment.end_x and segment.start_z == segment.end_z
  end

  defp summarize_spectrum(row) do
    powers = field(row, :power_bins_dbm) || []
    peak_power_dbm = Enum.max(powers, fn -> nil end)
    average_power_dbm = average_numbers(powers)
    baseline_power_dbm = percentile(powers, 0.5)
    broad_noise_score = normalize_power(average_power_dbm)
    excess_score = excess_power_score(average_power_dbm, peak_power_dbm, baseline_power_dbm)
    score = max(broad_noise_score, excess_score)
    peak_index = Enum.find_index(powers, &(&1 == peak_power_dbm)) || 0
    peak_frequency_mhz = peak_frequency_mhz(row, peak_index)

    %{
      average_power_dbm: average_power_dbm || -100.0,
      peak_power_dbm: peak_power_dbm || -100.0,
      baseline_power_dbm: baseline_power_dbm || -100.0,
      peak_frequency_mhz: peak_frequency_mhz,
      score: score
    }
  end

  defp channel_scores_for_spectrum(row) do
    Enum.flat_map(two_ghz_channels() ++ five_ghz_channels(), fn channel ->
      summarize_channel(row, channel)
    end)
  end

  defp summarize_channel(row, %{band: band, channel: channel, center_frequency_mhz: center}) do
    powers = field(row, :power_bins_dbm) || []
    start_hz = field(row, :start_frequency_hz) || 0
    stop_hz = field(row, :stop_frequency_hz) || 0
    bin_width_hz = field(row, :bin_width_hz) || 1.0
    center_hz = center * 1_000_000
    low_hz = center_hz - 10_000_000
    high_hz = center_hz + 10_000_000

    if high_hz < start_hz or low_hz > stop_hz do
      []
    else
      channel_powers =
        powers
        |> Enum.with_index()
        |> Enum.filter(fn {_power, index} ->
          frequency = start_hz + round((index + 0.5) * bin_width_hz)
          frequency >= low_hz and frequency <= high_hz
        end)
        |> Enum.map(fn {power, _index} -> power end)

      case channel_powers do
        [] ->
          []

        [_ | _] ->
          average_power = average_numbers(channel_powers)
          peak_power = Enum.max(channel_powers)
          baseline_power = percentile(powers, 0.5)

          [
            %{
              band: band,
              channel: channel,
              center_frequency_mhz: center,
              average_power_dbm: average_power,
              peak_power_dbm: peak_power,
              baseline_power_dbm: baseline_power,
              score: max(normalize_power(average_power), excess_power_score(average_power, peak_power, baseline_power)),
              sample_count: length(channel_powers)
            }
          ]
      end
    end
  end

  defp nearest_pose(row, poses) do
    target = field(row, :captured_at_unix_nanos)

    if is_nil(target) do
      nil
    else
      Enum.min_by(
        poses,
        fn pose ->
          pose_time = field(pose, :captured_at_unix_nanos) || field(pose, :pose_captured_at_unix_nanos) || 0
          abs(pose_time - target)
        end,
        fn -> nil end
      )
    end
  end

  defp floorplan_hull([]), do: []

  defp floorplan_hull(floorplan_segments) do
    floorplan_segments
    |> floorplan_segment_points()
    |> Enum.map(&{&1.x, &1.z})
    |> Enum.filter(&valid_polygon_point?/1)
    |> Enum.uniq()
    |> convex_hull()
  end

  defp convex_hull(points) when length(points) < 3, do: points

  defp convex_hull(points) do
    sorted = Enum.sort(points)
    lower = Enum.reduce(sorted, [], &append_hull_point/2)
    upper = Enum.reduce(Enum.reverse(sorted), [], &append_hull_point/2)

    Enum.uniq(tl(Enum.reverse(lower)) ++ tl(Enum.reverse(upper)))
  end

  defp append_hull_point(point, hull) do
    hull = trim_hull(hull, point)
    [point | hull]
  end

  defp trim_hull([second, first | rest] = hull, point) do
    if cross(first, second, point) <= 0 do
      trim_hull([first | rest], point)
    else
      hull
    end
  end

  defp trim_hull(hull, _point), do: hull

  defp cross({ax, ay}, {bx, by}, {cx, cy}) do
    (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
  end

  defp point_in_polygon?(_point, polygon) when length(polygon) < 3, do: true

  defp point_in_polygon?({x, z}, polygon) do
    polygon = Enum.filter(polygon, &valid_polygon_point?/1)

    if length(polygon) < 3 do
      true
    else
      polygon
      |> Enum.zip(tl(polygon) ++ [hd(polygon)])
      |> Enum.reduce(false, fn {{x1, z1}, {x2, z2}}, inside ->
        same_side = z1 > z == z2 > z

        if same_side do
          inside
        else
          boundary_x = (x2 - x1) * (z - z1) / (z2 - z1) + x1

          if x < boundary_x, do: not inside, else: inside
        end
      end)
    end
  end

  defp point_in_polygon?(_point, _polygon), do: true

  defp valid_polygon_point?({x, z}), do: number?(x) and number?(z)
  defp valid_polygon_point?(_point), do: false

  defp distance_2d(x1, z1, x2, z2), do: :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(z1 - z2, 2))

  defp bounds_for(wifi_points, wifi_raster, interference_points, interference_raster, path_points, floorplan_segments) do
    points =
      wifi_points ++
        wifi_raster ++
        interference_points ++ interference_raster ++ path_points ++ floorplan_segment_points(floorplan_segments)

    xs = Enum.map(points, & &1.x)
    zs = Enum.map(points, & &1.z)

    case {Enum.min(xs, fn -> nil end), Enum.max(xs, fn -> nil end), Enum.min(zs, fn -> nil end),
          Enum.max(zs, fn -> nil end)} do
      {nil, _, _, _} ->
        %{min_x: -1.0, max_x: 1.0, min_z: -1.0, max_z: 1.0}

      {min_x, max_x, min_z, max_z} ->
        x_pad = max((max_x - min_x) * 0.12, 1.0)
        z_pad = max((max_z - min_z) * 0.12, 1.0)
        %{min_x: min_x - x_pad, max_x: max_x + x_pad, min_z: min_z - z_pad, max_z: max_z + z_pad}
    end
  end

  defp project_points(points, bounds) do
    width = max(bounds.max_x - bounds.min_x, 0.01)
    height = max(bounds.max_z - bounds.min_z, 0.01)

    Enum.map(points, fn point ->
      point
      |> Map.put(:x_pct, (point.x - bounds.min_x) / width * 100.0)
      |> Map.put(:z_pct, 100.0 - (point.z - bounds.min_z) / height * 100.0)
    end)
  end

  defp project_raster_cells(cells, bounds) do
    width = max(bounds.max_x - bounds.min_x, 0.01)
    height = max(bounds.max_z - bounds.min_z, 0.01)
    meters_per_pct = max(width, height) / 100.0

    Enum.map(cells, fn cell ->
      cell
      |> Map.put(:x_pct, (cell.x - bounds.min_x) / width * 100.0)
      |> Map.put(:z_pct, 100.0 - (cell.z - bounds.min_z) / height * 100.0)
      |> Map.put(:radius_pct, cell.radius_m / max(meters_per_pct, 0.01))
    end)
  end

  defp floorplan_segment_points(floorplan_segments) do
    Enum.flat_map(floorplan_segments, fn segment ->
      [
        %{x: segment.start_x, z: segment.start_z},
        %{x: segment.end_x, z: segment.end_z}
      ]
    end)
  end

  defp project_floorplan_segments(floorplan_segments, bounds) do
    width = max(bounds.max_x - bounds.min_x, 0.01)
    height = max(bounds.max_z - bounds.min_z, 0.01)

    Enum.map(floorplan_segments, fn segment ->
      segment
      |> Map.put(:start_x_pct, (segment.start_x - bounds.min_x) / width * 100.0)
      |> Map.put(:start_z_pct, 100.0 - (segment.start_z - bounds.min_z) / height * 100.0)
      |> Map.put(:end_x_pct, (segment.end_x - bounds.min_x) / width * 100.0)
      |> Map.put(:end_z_pct, 100.0 - (segment.end_z - bounds.min_z) / height * 100.0)
    end)
  end

  defp bucket_key(x, z, cell_size_m), do: {floor(x / cell_size_m), floor(z / cell_size_m)}

  defp peak_frequency_mhz(row, peak_index) do
    start_hz = field(row, :start_frequency_hz) || 0
    bin_width_hz = field(row, :bin_width_hz) || 1.0
    (start_hz + round((peak_index + 0.5) * bin_width_hz)) / 1_000_000.0
  end

  defp two_ghz_channels do
    for channel <- 1..11 do
      %{band: "2.4GHz", channel: channel, center_frequency_mhz: 2_407 + channel * 5}
    end
  end

  defp five_ghz_channels do
    Enum.map(
      [
        {36, 5_180},
        {40, 5_200},
        {44, 5_220},
        {48, 5_240},
        {52, 5_260},
        {56, 5_280},
        {60, 5_300},
        {64, 5_320},
        {100, 5_500},
        {104, 5_520},
        {108, 5_540},
        {112, 5_560},
        {116, 5_580},
        {120, 5_600},
        {124, 5_620},
        {128, 5_640},
        {132, 5_660},
        {136, 5_680},
        {140, 5_700},
        {144, 5_720},
        {149, 5_745},
        {153, 5_765},
        {157, 5_785},
        {161, 5_805},
        {165, 5_825}
      ],
      fn {channel, center} -> %{band: "5GHz", channel: channel, center_frequency_mhz: center} end
    )
  end

  defp average(rows, field_name), do: rows |> Enum.map(&field(&1, field_name)) |> average_numbers()
  defp average_maps(rows, field_name), do: rows |> Enum.map(&Map.get(&1, field_name)) |> average_numbers()

  defp number_or_nil(value) when is_number(value), do: value * 1.0
  defp number_or_nil(_value), do: nil

  defp average_numbers(values) do
    numbers = Enum.filter(values, &number?/1)

    case numbers do
      [] -> nil
      [_ | _] -> Enum.sum(numbers) / length(numbers)
    end
  end

  defp percentile(values, fraction) do
    numbers = values |> Enum.filter(&number?/1) |> Enum.sort()

    case numbers do
      [] ->
        nil

      [_ | _] ->
        index =
          ((length(numbers) - 1) * min(max(fraction, 0.0), 1.0))
          |> Float.round()
          |> trunc()

        Enum.at(numbers, index)
    end
  end

  defp excess_power_score(average_power_dbm, peak_power_dbm, baseline_power_dbm) do
    if number?(baseline_power_dbm) do
      average_excess = max((average_power_dbm || baseline_power_dbm) - baseline_power_dbm, 0.0)
      peak_excess = max((peak_power_dbm || baseline_power_dbm) - baseline_power_dbm, 0.0)

      ((average_excess * 3.0 + peak_excess * 4.0) / 55.0 * 100.0)
      |> min(100.0)
      |> max(0.0)
      |> round()
    else
      0
    end
  end

  defp number_or_default(value, _default) when is_number(value), do: value
  defp number_or_default(_value, default), do: default

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_atom_key(key))
  end

  defp map_value(_map, _key), do: nil

  defp known_atom_key("cells"), do: :cells
  defp known_atom_key("confidence"), do: :confidence
  defp known_atom_key("count"), do: :count
  defp known_atom_key("interference_point_count"), do: :interference_point_count
  defp known_atom_key("nearest_distance_m"), do: :nearest_distance_m
  defp known_atom_key("radius_m"), do: :radius_m
  defp known_atom_key("rssi"), do: :rssi
  defp known_atom_key("score"), do: :score
  defp known_atom_key("wifi_point_count"), do: :wifi_point_count
  defp known_atom_key("x"), do: :x
  defp known_atom_key("z"), do: :z
  defp known_atom_key(_key), do: nil

  defp field(row, name), do: Map.get(row, name)
  defp number?(value), do: is_integer(value) or is_float(value)

  defp min_datetime(a, b), do: if(DateTime.after?(a, b), do: b, else: a)
  defp max_datetime(a, b), do: if(DateTime.before?(a, b), do: b, else: a)
end
