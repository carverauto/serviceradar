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
  alias ServiceRadarWebNG.FieldSurveyFloorplan
  alias ServiceRadarWebNG.FieldSurveyReviewPreferences
  alias ServiceRadarWebNG.FieldSurveySessionMetadata

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
  @wifi_temporal_bucket_nanos 1_000_000_000
  @spectrum_temporal_bucket_nanos 2_000_000_000
  @wifi_outlier_floor_db 12.0
  @interference_outlier_floor_score 28.0
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
          channel_scores: [map()],
          interferer_classifications: [map()]
        }

  @spec list_sessions(any(), keyword()) :: {:ok, [session_summary()]} | {:error, any()}
  def list_sessions(scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_recent_limit)

    with {:ok, rf_rows} <- read_rf_rows(scope, limit),
         {:ok, spectrum_rows} <- read_spectrum_rows(scope, limit) do
      sessions =
        rf_rows
        |> build_session_summaries(spectrum_rows)
        |> merge_session_metadata(scope)
        |> merge_session_renderability(scope)

      {:ok, sessions}
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

      interference_points =
        build_interference_points(spectrum_rows, pose_samples, rf_matches, cell_size_m)

      {wifi_raster, wifi_raster_source} =
        reusable_coverage_raster(
          scope,
          session_id,
          user_id,
          "wifi_rssi",
          "wifi_point_count",
          length(wifi_points)
        )

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

      display_base_review =
        if wifi_raster_source == :persisted and interference_raster_source == :persisted do
          review
        else
          maybe_persist_coverage_rasters(scope, review)
        end

      display_review = orient_review_projection(display_base_review)

      {:ok, display_review}
    end
  end

  @spec regenerate_coverage_rasters(any(), String.t(), keyword()) ::
          {:ok, review()} | {:error, any()}
  def regenerate_coverage_rasters(scope, session_id, opts \\ []) when is_binary(session_id) do
    rf_limit = Keyword.get(opts, :rf_limit, @default_session_limit)
    pose_limit = Keyword.get(opts, :pose_limit, @default_session_limit)
    spectrum_limit = Keyword.get(opts, :spectrum_limit, @default_spectrum_limit)
    cell_size_m = Keyword.get(opts, :cell_size_m, @default_cell_size_m)

    with {:ok, rf_matches} <- read_rf_pose_matches(scope, session_id, rf_limit),
         {:ok, pose_samples} <- read_pose_samples(scope, session_id, pose_limit),
         {:ok, spectrum_rows} <- read_spectrum_rows(scope, session_id, spectrum_limit),
         {:ok, room_artifacts} <- read_room_artifacts(scope, session_id) do
      floorplan_segments = load_floorplan_segments(scope, session_id)
      wifi_points = build_wifi_points(rf_matches, cell_size_m)

      interference_points =
        build_interference_points(spectrum_rows, pose_samples, rf_matches, cell_size_m)

      review =
        build_review(session_id, rf_matches, pose_samples, spectrum_rows,
          cell_size_m: cell_size_m,
          floorplan_segments: floorplan_segments,
          room_artifacts: room_artifacts,
          wifi_points: wifi_points,
          wifi_raster: build_wifi_raster(rf_matches, floorplan_segments),
          interference_points: interference_points,
          interference_raster: build_interference_raster(interference_points, floorplan_segments)
        )

      case persist_coverage_rasters(scope, review) do
        {:ok, _count} -> {:ok, orient_review_projection(review)}
        {:error, reason} -> {:error, reason}
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
      selected_session_id =
        selected_scene_session_id(scope, opts, artifacts, samples)

      floorplan_segments =
        if selected_session_id, do: load_floorplan_segments(scope, selected_session_id), else: []

      {:ok,
       %{
         selected_session_id: selected_session_id,
         samples: samples,
         artifacts: artifacts,
         floorplan_segments: floorplan_segments,
         point_cloud_artifact: artifact_for_session(artifacts, selected_session_id, "point_cloud_ply"),
         roomplan_artifact: artifact_for_session(artifacts, selected_session_id, "roomplan_usdz")
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

    floorplan_segments =
      opts |> Keyword.get(:floorplan_segments, []) |> FieldSurveyFloorplan.rectify_segments()

    room_artifacts = Keyword.get(opts, :room_artifacts, [])

    wifi_points =
      Keyword.get_lazy(opts, :wifi_points, fn -> build_wifi_points(rf_matches, cell_size_m) end)

    wifi_raster =
      Keyword.get(opts, :wifi_raster) || build_wifi_raster(rf_matches, floorplan_segments)

    path_points = build_path_points(pose_samples, rf_matches)
    channel_scores = build_channel_scores(spectrum_rows, rf_matches)

    interference_points =
      Keyword.get_lazy(opts, :interference_points, fn ->
        build_interference_points(spectrum_rows, pose_samples, rf_matches, cell_size_m)
      end)

    interference_raster =
      Keyword.get(opts, :interference_raster) ||
        build_interference_raster(interference_points, floorplan_segments)

    spectrum_waterfall = build_spectrum_waterfall(spectrum_rows)
    interferer_classifications = build_interferer_classifications(spectrum_rows)

    ap_summaries = build_ap_summaries(rf_matches)

    bounds =
      bounds_for(
        wifi_points,
        wifi_raster,
        interference_points,
        interference_raster,
        path_points,
        floorplan_segments,
        ap_summaries
      )

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
        channel_count: length(channel_scores),
        interferer_count: length(interferer_classifications)
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
      ap_summaries: project_ap_summaries(ap_summaries, bounds),
      channel_scores: channel_scores,
      interferer_classifications: interferer_classifications
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
    |> Ash.Query.limit(12)
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
    |> case do
      {:ok, artifacts} -> {:ok, Enum.find(artifacts, &cached_floorplan_artifact?/1)}
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
      session_id == ^session_id and user_id == ^user_id and overlay_type == ^overlay_type and
        selector_type == "all" and
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
    _result = persist_coverage_rasters(scope, review)
    review
  end

  defp persist_coverage_rasters(scope, review) do
    user_id = scope_user_id(scope)

    attrs =
      Enum.reject(
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
        ],
        &is_nil/1
      )

    if attrs == [] do
      {:error, :no_raster_cells}
    else
      results = Enum.map(attrs, &persist_coverage_raster(scope, &1))
      failures = Enum.count(results, &(&1 == :error))

      if failures == 0 do
        {:ok, length(results)}
      else
        {:error, {:raster_persistence_failed, failures}}
      end
    end
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
      cells: %{"cells" => cells, "surface_svg" => coverage_surface_svg(cells, overlay_type)},
      metadata: %{
        "algorithm" => "rbf_kernel_raster_v1",
        "surface_algorithm" => "svg_kernel_surface_v1",
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

  defp coverage_surface_svg(cells, overlay_type) do
    cells =
      cells
      |> Enum.filter(&(is_number(Map.get(&1, "x_pct")) and is_number(Map.get(&1, "z_pct"))))
      |> Enum.sort_by(&(Map.get(&1, "confidence") || 0.0), :desc)
      |> Enum.take(900)

    circles =
      Enum.map_join(cells, "\n", fn cell ->
        value = Map.get(cell, if(overlay_type == "rf_interference", do: "score", else: "rssi"))
        radius = surface_radius_pct(cell)
        color = surface_color(value, overlay_type)
        opacity = surface_opacity(cell, value, overlay_type)

        ~s(<circle cx="#{surface_number(cell["x_pct"])}" cy="#{surface_number(cell["z_pct"])}" r="#{surface_number(radius)}" fill="#{color}" opacity="#{surface_number(opacity)}"/>)
      end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" preserveAspectRatio="none">
      <defs>
        <filter id="heat-soften" x="-12" y="-12" width="124" height="124" filterUnits="userSpaceOnUse">
          <feGaussianBlur stdDeviation="2.8"/>
          <feComponentTransfer>
            <feFuncA type="gamma" amplitude="1.22" exponent="0.8" offset="0"/>
          </feComponentTransfer>
        </filter>
      </defs>
      <g filter="url(#heat-soften)">
    #{circles}
      </g>
    </svg>
    """
  end

  defp surface_radius_pct(cell) do
    cell
    |> Map.get("radius_pct", 3.0)
    |> number_or_default(3.0)
    |> max(2.6)
    |> min(8.5)
    |> Kernel.*(1.55)
  end

  defp surface_opacity(cell, value, "rf_interference") do
    confidence =
      cell |> Map.get("confidence", 0.5) |> number_or_default(0.5) |> min(1.0) |> max(0.15)

    intensity = (number_or_default(value, 0.0) / 100.0) |> min(1.0) |> max(0.0)
    0.12 + intensity * 0.26 + confidence * 0.14
  end

  defp surface_opacity(cell, value, _overlay_type) do
    confidence =
      cell |> Map.get("confidence", 0.5) |> number_or_default(0.5) |> min(1.0) |> max(0.15)

    signal = ((number_or_default(value, -90.0) + 90.0) / 60.0) |> min(1.0) |> max(0.0)
    0.16 + signal * 0.18 + confidence * 0.16
  end

  defp surface_color(score, "rf_interference") when is_number(score) and score >= 75, do: "#ef4444"

  defp surface_color(score, "rf_interference") when is_number(score) and score >= 55, do: "#f97316"

  defp surface_color(score, "rf_interference") when is_number(score) and score >= 35, do: "#facc15"

  defp surface_color(_score, "rf_interference"), do: "#22c55e"
  defp surface_color(rssi, _overlay_type) when is_number(rssi) and rssi >= -55, do: "#5fd38a"
  defp surface_color(rssi, _overlay_type) when is_number(rssi) and rssi >= -65, do: "#8bd94f"
  defp surface_color(rssi, _overlay_type) when is_number(rssi) and rssi >= -75, do: "#ffd25a"
  defp surface_color(rssi, _overlay_type) when is_number(rssi) and rssi >= -82, do: "#ff7d3f"
  defp surface_color(_rssi, _overlay_type), do: "#ef4444"

  defp surface_number(value) when is_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  defp surface_number(_value), do: "0.000"

  defp inferred_cell_size_m([cell | _]), do: max((cell.radius_m || @default_raster_cell_size_m * 0.72) / 0.72, 0.01)

  defp inferred_cell_size_m([]), do: @default_raster_cell_size_m

  defp scope_user_id(%{user: %{id: id}}) when not is_nil(id), do: to_string(id)
  defp scope_user_id(_scope), do: "system"

  defp latest_floorplan_session_id(artifacts) do
    artifacts
    |> Enum.find(&cached_floorplan_artifact_summary?/1)
    |> case do
      %{session_id: session_id} -> session_id
      _artifact -> nil
    end
  end

  defp latest_artifact_session_id([artifact | _]), do: artifact.session_id
  defp latest_artifact_session_id([]), do: nil

  defp latest_sample_session_id([sample | _]), do: sample.session_id
  defp latest_sample_session_id([]), do: nil

  defp selected_scene_session_id(scope, opts, artifacts, samples) do
    requested_id = Keyword.get(opts, :session_id)
    default_id = default_scene_session_id(scope)

    Enum.find(
      [
        requested_id,
        default_id,
        latest_floorplan_session_id(artifacts),
        latest_artifact_session_id(artifacts),
        latest_sample_session_id(samples)
      ],
      &scene_session_available?(&1, artifacts, samples)
    )
  end

  defp default_scene_session_id(scope) do
    case FieldSurveyReviewPreferences.default_session_id(scope) do
      {:ok, session_id} when is_binary(session_id) -> session_id
      _ -> nil
    end
  end

  defp scene_session_available?(session_id, artifacts, samples) when is_binary(session_id) do
    Enum.any?(artifacts, &(&1.session_id == session_id)) or
      Enum.any?(samples, &(&1.session_id == session_id))
  end

  defp scene_session_available?(_session_id, _artifacts, _samples), do: false

  defp artifact_for_session(artifacts, session_id, artifact_type) when is_binary(session_id) do
    Enum.find(artifacts, &(&1.session_id == session_id and &1.artifact_type == artifact_type))
  end

  defp artifact_for_session(_artifacts, _session_id, _artifact_type), do: nil

  defp cached_floorplan_artifact_summary?(%{artifact_type: "floorplan_geojson", metadata: metadata}) do
    metadata
    |> FieldSurveyFloorplan.segments_from_metadata()
    |> Enum.reject(&zero_length_segment?/1)
    |> Enum.any?()
  end

  defp cached_floorplan_artifact_summary?(_artifact), do: false

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
    %{
      id: session_id,
      first_seen: nil,
      last_seen: nil,
      rf_count: 0,
      spectrum_count: 0,
      ap_set: MapSet.new()
    }
  end

  defp merge_session_metadata(sessions, scope) do
    session_ids = Enum.map(sessions, & &1.id)

    case FieldSurveySessionMetadata.for_sessions(scope, session_ids) do
      {:ok, metadata_by_session} ->
        Enum.map(sessions, fn session ->
          Map.put(session, :metadata, Map.get(metadata_by_session, session.id))
        end)

      {:error, reason} ->
        Logger.warning("FieldSurvey session metadata lookup failed: #{inspect(reason)}")
        sessions
    end
  end

  defp merge_session_renderability([], _scope), do: []

  defp merge_session_renderability(sessions, scope) do
    session_ids = Enum.map(sessions, & &1.id)
    user_id = scope_user_id(scope)
    artifact_stats = artifact_stats_by_session(scope, session_ids)
    raster_stats = raster_stats_by_session(scope, session_ids, user_id)

    Enum.map(sessions, fn session ->
      artifacts =
        Map.get(artifact_stats, session.id, %{room_artifact_count: 0, has_floorplan: false})

      rasters =
        Map.get(raster_stats, session.id, %{wifi_raster_count: 0, interference_raster_count: 0})

      renderable =
        session.rf_count > 0 and session.ap_count > 0 and
          (artifacts.has_floorplan or rasters.wifi_raster_count > 0)

      session
      |> Map.merge(artifacts)
      |> Map.merge(rasters)
      |> Map.put(:renderable, renderable)
    end)
  end

  defp artifact_stats_by_session(scope, session_ids) do
    SurveyRoomArtifact
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(session_id in ^session_ids)
    |> Ash.Query.limit(max(length(session_ids) * 12, 100))
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
    |> case do
      {:ok, artifacts} ->
        artifacts
        |> Enum.group_by(&field(&1, :session_id))
        |> Map.new(fn {session_id, rows} ->
          {session_id,
           %{
             room_artifact_count: length(rows),
             has_floorplan: Enum.any?(rows, &cached_floorplan_artifact?/1)
           }}
        end)

      {:error, reason} ->
        Logger.warning("FieldSurvey artifact stats lookup failed: #{inspect(reason)}")
        %{}
    end
  end

  defp raster_stats_by_session(_scope, _session_ids, nil), do: %{}

  defp raster_stats_by_session(scope, session_ids, user_id) do
    SurveyCoverageRaster
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(session_id in ^session_ids and user_id == ^user_id)
    |> Ash.Query.limit(max(length(session_ids) * 8, 100))
    |> Ash.read(scope: scope, domain: ServiceRadar.Spatial)
    |> Page.unwrap()
    |> case do
      {:ok, rasters} ->
        rasters
        |> Enum.group_by(&field(&1, :session_id))
        |> Map.new(fn {session_id, rows} ->
          {session_id,
           %{
             wifi_raster_count: Enum.count(rows, &(field(&1, :overlay_type) == "wifi_rssi")),
             interference_raster_count: Enum.count(rows, &(field(&1, :overlay_type) == "rf_interference"))
           }}
        end)

      {:error, reason} ->
        Logger.warning("FieldSurvey raster stats lookup failed: #{inspect(reason)}")
        %{}
    end
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
    |> wifi_observations(cell_size_m)
    |> Enum.sort_by(& &1.rssi, :desc)
  end

  defp wifi_observations(rf_matches, cell_size_m) do
    rf_matches
    |> Enum.filter(&(number?(field(&1, :x)) and number?(field(&1, :z)) and number?(field(&1, :rssi_dbm))))
    |> Enum.group_by(fn row -> bucket_key(field(row, :x), field(row, :z), cell_size_m) end)
    |> Enum.map(fn {_bucket, rows} -> summarize_wifi_bucket(rows) end)
    |> Enum.reject(&is_nil/1)
  end

  defp summarize_wifi_bucket(rows) do
    candidates =
      rows
      |> Enum.group_by(&(field(&1, :bssid) || "unknown"))
      |> Enum.map(fn {_bssid, bssid_rows} -> summarize_wifi_bssid_bucket(bssid_rows) end)
      |> Enum.reject(&is_nil/1)

    case candidates do
      [] ->
        nil

      [_ | _] ->
        strongest = Enum.max_by(candidates, & &1.rssi)

        %{
          x: strongest.x,
          y: strongest.y,
          z: strongest.z,
          rssi: strongest.rssi,
          strongest_rssi: strongest.strongest_rssi,
          bssid: strongest.bssid,
          ssid: strongest.ssid,
          count: Enum.sum(Enum.map(candidates, & &1.count))
        }
    end
  end

  defp summarize_wifi_bssid_bucket(rows) do
    rows =
      rows
      |> temporal_average_wifi_rows()
      |> reject_numeric_outliers(:rssi_dbm, @wifi_outlier_floor_db)

    case rows do
      [] ->
        nil

      [_ | _] ->
        strongest = Enum.max_by(rows, &field(&1, :rssi_dbm))
        count = Enum.sum(Enum.map(rows, &(field(&1, :count) || 1)))

        %{
          x: weighted_average(rows, :x, :count),
          y: weighted_average(rows, :y, :count),
          z: weighted_average(rows, :z, :count),
          rssi: weighted_average(rows, :rssi_dbm, :count),
          strongest_rssi: field(strongest, :strongest_rssi) || field(strongest, :rssi_dbm),
          bssid: field(strongest, :bssid),
          ssid: field(strongest, :ssid) || "Hidden",
          count: count
        }
    end
  end

  defp temporal_average_wifi_rows(rows) do
    rows
    |> Enum.with_index()
    |> Enum.group_by(fn {row, index} ->
      temporal_bucket_key(row, :captured_at_unix_nanos, index, @wifi_temporal_bucket_nanos)
    end)
    |> Enum.map(fn {_bucket, indexed_rows} ->
      bucket_rows = Enum.map(indexed_rows, &elem(&1, 0))
      strongest = Enum.max_by(bucket_rows, &field(&1, :rssi_dbm))

      %{
        x: average(bucket_rows, :x),
        y: average(bucket_rows, :y),
        z: average(bucket_rows, :z),
        rssi_dbm: average(bucket_rows, :rssi_dbm),
        strongest_rssi: field(strongest, :rssi_dbm),
        bssid: field(strongest, :bssid),
        ssid: field(strongest, :ssid),
        count: length(bucket_rows)
      }
    end)
  end

  defp build_wifi_raster(rf_matches, floorplan_segments) do
    observations = wifi_observations(rf_matches, @default_raster_cell_size_m)

    with [_ | _] <- observations,
         %{min_x: min_x, max_x: max_x, min_z: min_z, max_z: max_z} <-
           raster_bounds(observations, floorplan_segments) do
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
      |> Enum.map(fn {x, z} ->
        interpolate_rssi_cell(x, z, observations, length_scale, max_distance, cell_size)
      end)
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
          :math.exp(-:math.pow(distance, 2) / (2.0 * :math.pow(length_scale, 2))) *
            :math.log2(observation.count + 1)

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
        confidence =
          weight_sum / (weight_sum + 8.0 + max(nearest_distance - cell_size, 0.0) * 2.0)

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
    |> Enum.sort_by(
      &(field(&1, :captured_at_unix_nanos) || field(&1, :pose_captured_at_unix_nanos) || 0),
      :asc
    )
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
    poses =
      Enum.filter(
        pose_samples ++ rf_matches,
        &(number?(field(&1, :x)) and number?(field(&1, :z)))
      )

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
        captured_at_unix_nanos: field(row, :captured_at_unix_nanos),
        count: 1
      }
    end)
    |> Enum.group_by(fn point -> bucket_key(point.x, point.z, cell_size_m) end)
    |> Enum.map(fn {_bucket, points} ->
      points
      |> temporal_average_interference_points()
      |> reject_numeric_outliers(:score, @interference_outlier_floor_score)
      |> summarize_interference_bucket()
    end)
    |> Enum.reject(&is_nil/1)
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
          interpolate_interference_cell(
            x,
            z,
            interference_points,
            length_scale,
            max_distance,
            cell_size
          )
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
          :math.exp(-:math.pow(distance, 2) / (2.0 * :math.pow(length_scale, 2))) *
            :math.log2(observation.count + 1)

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
        confidence =
          weight_sum / (weight_sum + 10.0 + max(nearest_distance - cell_size, 0.0) * 2.5)

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
    case points do
      [] ->
        nil

      [_ | _] ->
        peak = Enum.max_by(points, & &1.peak_power_dbm)

        %{
          x: weighted_average_maps(points, :x, :count),
          y: weighted_average_maps(points, :y, :count),
          z: weighted_average_maps(points, :z, :count),
          score: weighted_average_maps(points, :score, :count),
          average_power_dbm: weighted_average_maps(points, :average_power_dbm, :count),
          peak_power_dbm: peak.peak_power_dbm,
          peak_frequency_mhz: peak.peak_frequency_mhz,
          count: Enum.sum(Enum.map(points, &(Map.get(&1, :count) || 1)))
        }
    end
  end

  defp temporal_average_interference_points(points) do
    points
    |> Enum.with_index()
    |> Enum.group_by(fn {point, index} ->
      temporal_bucket_key(point, :captured_at_unix_nanos, index, @spectrum_temporal_bucket_nanos)
    end)
    |> Enum.map(fn {_bucket, indexed_points} ->
      bucket_points = Enum.map(indexed_points, &elem(&1, 0))
      peak = Enum.max_by(bucket_points, & &1.peak_power_dbm)

      %{
        x: average_maps(bucket_points, :x),
        y: average_maps(bucket_points, :y),
        z: average_maps(bucket_points, :z),
        score: average_maps(bucket_points, :score),
        average_power_dbm: average_maps(bucket_points, :average_power_dbm),
        peak_power_dbm: peak.peak_power_dbm,
        peak_frequency_mhz: peak.peak_frequency_mhz,
        captured_at_unix_nanos: Map.get(peak, :captured_at_unix_nanos),
        count: length(bucket_points)
      }
    end)
  end

  defp build_channel_scores(spectrum_rows, rf_matches) do
    ap_channels = ap_channel_summary(rf_matches)

    spectrum_rows
    |> Enum.flat_map(&channel_scores_for_spectrum/1)
    |> Enum.group_by(&{&1.band, &1.channel})
    |> Enum.map(fn {{band, channel}, scores} ->
      peak = Enum.max_by(scores, & &1.peak_power_dbm)

      ap_summary =
        Map.get(ap_channels, channel_key(band, channel), %{ap_count: 0, strongest_rssi: nil})

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
    |> Enum.group_by(fn row ->
      channel_key(band_for_frequency(field(row, :frequency_mhz)), field(row, :channel))
    end)
    |> Map.new(fn {key, rows} ->
      strongest =
        rows
        |> Enum.map(&field(&1, :rssi_dbm))
        |> Enum.filter(&number?/1)
        |> Enum.max(fn -> nil end)

      {key,
       %{
         ap_count:
           rows
           |> Enum.map(&field(&1, :bssid))
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> length(),
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

  defp build_interferer_classifications(spectrum_rows) do
    spectrum_rows
    |> Enum.map(&classify_spectrum_row/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, events} ->
      peak = Enum.max_by(events, & &1.peak_power_dbm)

      %{
        kind: kind,
        label: interferer_label(kind),
        description: interferer_description(kind),
        severity: events |> Enum.map(& &1.severity) |> Enum.max(fn -> 0 end),
        event_count: length(events),
        peak_power_dbm: peak.peak_power_dbm,
        peak_frequency_mhz: peak.peak_frequency_mhz,
        average_active_fraction: average_maps(events, :active_fraction),
        average_excess_db: average_maps(events, :average_excess_db),
        last_seen_unix_nanos: events |> Enum.map(& &1.captured_at_unix_nanos) |> Enum.max(fn -> nil end)
      }
    end)
    |> Enum.sort_by(& &1.severity, :desc)
  end

  defp classify_spectrum_row(row) do
    powers = field(row, :power_bins_dbm) || []

    with [_ | _] <- powers,
         baseline when is_number(baseline) <- percentile(powers, 0.5),
         average_power when is_number(average_power) <- average_numbers(powers) do
      peak_power = Enum.max(powers)
      peak_index = Enum.find_index(powers, &(&1 == peak_power)) || 0
      active_threshold = max(baseline + 8.0, -82.0)
      active_bins = Enum.count(powers, &(&1 >= active_threshold))
      active_fraction = active_bins / max(length(powers), 1)
      peak_excess = peak_power - baseline
      average_excess = average_power - baseline

      kind =
        cond do
          active_fraction >= 0.35 and average_excess >= 5.0 ->
            :broad_continuous_noise

          active_fraction <= 0.10 and peak_excess >= 16.0 ->
            :narrow_spike

          active_fraction < 0.35 and peak_excess >= 10.0 ->
            :bursty_activity

          true ->
            nil
        end

      if is_nil(kind) do
        nil
      else
        %{
          kind: kind,
          severity: interferer_severity(kind, active_fraction, peak_excess, average_excess),
          active_fraction: active_fraction,
          average_excess_db: average_excess,
          peak_power_dbm: peak_power,
          baseline_power_dbm: baseline,
          peak_frequency_mhz: peak_frequency_mhz(row, peak_index),
          captured_at_unix_nanos: field(row, :captured_at_unix_nanos)
        }
      end
    else
      _ -> nil
    end
  end

  defp interferer_severity(:broad_continuous_noise, active_fraction, peak_excess, average_excess) do
    normalize_interferer_severity(active_fraction * 70.0 + average_excess * 3.0 + peak_excess)
  end

  defp interferer_severity(:narrow_spike, active_fraction, peak_excess, _average_excess) do
    normalize_interferer_severity(peak_excess * 3.8 + (1.0 - active_fraction) * 18.0)
  end

  defp interferer_severity(:bursty_activity, active_fraction, peak_excess, average_excess) do
    normalize_interferer_severity(peak_excess * 2.7 + average_excess * 2.0 + active_fraction * 45.0)
  end

  defp normalize_interferer_severity(value), do: value |> min(100.0) |> max(0.0) |> round()

  defp interferer_label(:broad_continuous_noise), do: "Broad continuous noise"
  defp interferer_label(:narrow_spike), do: "Narrow spike"
  defp interferer_label(:bursty_activity), do: "Bursty activity"

  defp interferer_description(:broad_continuous_noise),
    do: "Wide RF energy across many bins, consistent with a high noise floor or broadband interferer."

  defp interferer_description(:narrow_spike),
    do: "Strong energy concentrated into a small frequency slice, consistent with a narrowband interferer."

  defp interferer_description(:bursty_activity),
    do: "Intermittent elevated RF energy, consistent with bursty emitters such as Bluetooth or Zigbee-like traffic."

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
                frequency_mhz:
                  start_hz / 1_000_000.0 +
                    frequency_span_mhz * ((index + 0.5) / max(bin_count, 1)),
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
    |> Enum.map(fn {bssid, rows} -> summarize_ap_candidate(bssid, rows) end)
    |> Enum.sort_by(fn ap -> {ap.confidence, ap.count, ap.strongest_rssi || -120} end, :desc)
  end

  defp summarize_ap_candidate(bssid, rows) do
    strongest = Enum.max_by(rows, &field(&1, :rssi_dbm))
    positioned_rows = Enum.filter(rows, &(number?(field(&1, :x)) and number?(field(&1, :z))))
    strongest_rssi = field(strongest, :rssi_dbm)
    support_rows = candidate_support_rows(positioned_rows, strongest_rssi)
    candidate = weighted_position(support_rows) || strongest_position(strongest)
    path_spread_m = positioned_spread(positioned_rows)
    residual_error_m = average_candidate_error(support_rows, candidate)

    base = %{
      bssid: bssid,
      ssid: field(strongest, :ssid) || "Hidden",
      count: length(rows),
      positioned_count: length(positioned_rows),
      support_count: length(support_rows),
      strongest_rssi: strongest_rssi,
      channel: field(strongest, :channel),
      frequency_mhz: field(strongest, :frequency_mhz),
      confidence:
        ap_candidate_confidence(
          rows,
          positioned_rows,
          strongest_rssi,
          path_spread_m,
          residual_error_m
        ),
      path_spread_m: path_spread_m,
      residual_error_m: residual_error_m,
      strongest_observation: strongest_position(strongest),
      supporting_observations: supporting_observations(support_rows)
    }

    if is_map(candidate) do
      Map.merge(base, %{x: candidate.x, y: candidate.y, z: candidate.z})
    else
      base
    end
  end

  defp candidate_support_rows([], _strongest_rssi), do: []

  defp candidate_support_rows(positioned_rows, strongest_rssi) do
    threshold = strongest_rssi - 8.0

    positioned_rows
    |> Enum.filter(&(field(&1, :rssi_dbm) >= threshold))
    |> Enum.sort_by(&field(&1, :rssi_dbm), :desc)
    |> Enum.take(40)
  end

  defp weighted_position([]), do: nil

  defp weighted_position(rows) do
    {x_sum, y_sum, z_sum, weight_sum} =
      Enum.reduce(rows, {0.0, 0.0, 0.0, 0.0}, fn row, {x_acc, y_acc, z_acc, weight_acc} ->
        weight = :math.pow(10.0, (field(row, :rssi_dbm) + 100.0) / 20.0)

        {
          x_acc + field(row, :x) * weight,
          y_acc + number_or_default(field(row, :y), 0.0) * weight,
          z_acc + field(row, :z) * weight,
          weight_acc + weight
        }
      end)

    if weight_sum > 0.0 do
      %{x: x_sum / weight_sum, y: y_sum / weight_sum, z: z_sum / weight_sum}
    end
  end

  defp strongest_position(row) do
    if number?(field(row, :x)) and number?(field(row, :z)) do
      %{
        x: field(row, :x),
        y: number_or_default(field(row, :y), 0.0),
        z: field(row, :z),
        rssi: field(row, :rssi_dbm)
      }
    end
  end

  defp positioned_spread([]), do: 0.0

  defp positioned_spread(rows) do
    min_x = rows |> Enum.map(&field(&1, :x)) |> Enum.min()
    max_x = rows |> Enum.map(&field(&1, :x)) |> Enum.max()
    min_z = rows |> Enum.map(&field(&1, :z)) |> Enum.min()
    max_z = rows |> Enum.map(&field(&1, :z)) |> Enum.max()

    distance_2d(min_x, min_z, max_x, max_z)
  end

  defp average_candidate_error([], _candidate), do: nil
  defp average_candidate_error(_rows, nil), do: nil

  defp average_candidate_error(rows, candidate) do
    rows
    |> Enum.map(&distance_2d(field(&1, :x), field(&1, :z), candidate.x, candidate.z))
    |> average_numbers()
  end

  defp ap_candidate_confidence(rows, positioned_rows, strongest_rssi, path_spread_m, residual_error_m) do
    count_score = min(length(rows) / 36.0, 1.0)
    positioned_score = min(length(positioned_rows) / 24.0, 1.0)
    diversity_score = min(path_spread_m / 5.0, 1.0)
    strength_score = min(max((strongest_rssi + 90.0) / 45.0, 0.0), 1.0)
    residual_penalty = min(max((residual_error_m || 0.0) / 4.0, 0.0), 0.22)

    (0.18 + count_score * 0.22 + positioned_score * 0.24 + diversity_score * 0.18 +
       strength_score * 0.18 -
       residual_penalty)
    |> min(0.96)
    |> max(0.05)
  end

  defp supporting_observations(rows) do
    rows
    |> Enum.take(5)
    |> Enum.map(fn row ->
      %{
        x: field(row, :x),
        y: number_or_default(field(row, :y), 0.0),
        z: field(row, :z),
        rssi: field(row, :rssi_dbm),
        channel: field(row, :channel),
        captured_at_unix_nanos: field(row, :captured_at_unix_nanos)
      }
    end)
  end

  defp load_floorplan_segments(scope, session_id) do
    case read_latest_floorplan_artifact(scope, session_id) do
      {:ok, artifact} when not is_nil(artifact) ->
        artifact
        |> field(:metadata)
        |> FieldSurveyFloorplan.segments_from_metadata()
        |> Enum.reject(&zero_length_segment?/1)

      {:ok, nil} ->
        []

      _error ->
        []
    end
  end

  defp cached_floorplan_artifact?(artifact) do
    artifact
    |> field(:metadata)
    |> FieldSurveyFloorplan.segments_from_metadata()
    |> Enum.any?()
  end

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
              score:
                max(
                  normalize_power(average_power),
                  excess_power_score(average_power, peak_power, baseline_power)
                ),
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
          pose_time =
            field(pose, :captured_at_unix_nanos) || field(pose, :pose_captured_at_unix_nanos) || 0

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

  defp orient_review_projection(review) do
    angle = review_orientation_angle(review)

    {oriented, bounds} =
      review
      |> rotated_review_projection(angle)
      |> maybe_landscape_review_projection(review, angle)

    project_oriented_review(oriented, bounds)
  end

  defp maybe_landscape_review_projection(
         {oriented, %{min_x: min_x, max_x: max_x, min_z: min_z, max_z: max_z} = bounds},
         review,
         angle
       ) do
    if max_x - min_x < max_z - min_z do
      rotated_review_projection(review, angle + :math.pi() / 2.0)
    else
      {oriented, bounds}
    end
  end

  defp rotated_review_projection(review, angle) do
    oriented = rotate_review(review, angle)

    bounds =
      bounds_for(
        oriented.wifi_points,
        oriented.wifi_raster,
        oriented.interference_points,
        oriented.interference_raster,
        oriented.path_points,
        oriented.floorplan_segments,
        oriented.ap_summaries
      )

    {oriented, bounds}
  end

  defp project_oriented_review(review, bounds) do
    %{
      review
      | bounds: bounds,
        wifi_points: project_points(review.wifi_points, bounds),
        wifi_raster: project_raster_cells(review.wifi_raster, bounds),
        interference_points: project_points(review.interference_points, bounds),
        interference_raster: project_raster_cells(review.interference_raster, bounds),
        path_points: project_points(review.path_points, bounds),
        floorplan_segments: project_floorplan_segments(review.floorplan_segments, bounds),
        ap_summaries: project_ap_summaries(review.ap_summaries, bounds)
    }
  end

  defp rotate_review(review, angle) do
    %{
      review
      | wifi_points: Enum.map(review.wifi_points, &rotate_review_point(&1, angle)),
        wifi_raster: Enum.map(review.wifi_raster, &rotate_review_point(&1, angle)),
        interference_points: Enum.map(review.interference_points, &rotate_review_point(&1, angle)),
        interference_raster: Enum.map(review.interference_raster, &rotate_review_point(&1, angle)),
        path_points: Enum.map(review.path_points, &rotate_review_point(&1, angle)),
        floorplan_segments: Enum.map(review.floorplan_segments, &rotate_review_segment(&1, angle)),
        ap_summaries: Enum.map(review.ap_summaries, &rotate_review_ap(&1, angle))
    }
  end

  defp review_orientation_angle(%{floorplan_segments: [_ | _] = segments}) do
    primary_segments =
      case Enum.filter(segments, &(&1.kind == "wall")) do
        [] -> segments
        walls -> walls
      end

    primary_segments
    |> Enum.max_by(&review_segment_length/1, fn -> nil end)
    |> case do
      %{start_x: start_x, start_z: start_z, end_x: end_x, end_z: end_z} ->
        :math.atan2(end_z - start_z, end_x - start_x)

      _ ->
        0.0
    end
    |> normalize_review_angle()
  end

  defp review_orientation_angle(review) do
    points =
      (review.wifi_raster || []) ++
        (review.wifi_points || []) ++
        (review.path_points || [])

    case Enum.filter(points, &(number?(Map.get(&1, :x)) and number?(Map.get(&1, :z)))) do
      [_ | _] = positioned -> positioned_review_axis(positioned)
      [] -> 0.0
    end
  end

  defp positioned_review_axis(points) do
    count = length(points)
    mean_x = points |> Enum.map(& &1.x) |> Enum.sum() |> Kernel./(count)
    mean_z = points |> Enum.map(& &1.z) |> Enum.sum() |> Kernel./(count)

    {cov_xx, cov_zz, cov_xz} =
      Enum.reduce(points, {0.0, 0.0, 0.0}, fn point, {xx, zz, xz} ->
        dx = point.x - mean_x
        dz = point.z - mean_z
        {xx + dx * dx, zz + dz * dz, xz + dx * dz}
      end)

    normalize_review_angle(0.5 * :math.atan2(2.0 * cov_xz, cov_xx - cov_zz))
  end

  defp normalize_review_angle(angle) do
    cond do
      angle > :math.pi() / 2.0 -> angle - :math.pi()
      angle < -:math.pi() / 2.0 -> angle + :math.pi()
      true -> angle
    end
  end

  defp rotate_review_point(%{x: x, z: z} = point, angle) when is_number(x) and is_number(z) do
    cos = :math.cos(-angle)
    sin = :math.sin(-angle)

    point
    |> Map.put(:x, x * cos - z * sin)
    |> Map.put(:z, x * sin + z * cos)
  end

  defp rotate_review_point(point, _angle), do: point

  defp rotate_review_ap(ap, angle) do
    rotated = rotate_review_point(ap, angle)

    rotated
    |> rotate_nested_review_point(:strongest_observation, angle)
    |> Map.update(:supporting_observations, [], fn observations ->
      Enum.map(observations || [], &rotate_review_point(&1, angle))
    end)
  end

  defp rotate_nested_review_point(ap, key, angle) do
    Map.update(ap, key, nil, fn
      value when is_map(value) -> rotate_review_point(value, angle)
      value -> value
    end)
  end

  defp rotate_review_segment(segment, angle) do
    start = rotate_review_point(%{x: segment.start_x, z: segment.start_z}, angle)
    finish = rotate_review_point(%{x: segment.end_x, z: segment.end_z}, angle)

    segment
    |> Map.put(:start_x, start.x)
    |> Map.put(:start_z, start.z)
    |> Map.put(:end_x, finish.x)
    |> Map.put(:end_z, finish.z)
  end

  defp review_segment_length(%{start_x: start_x, start_z: start_z, end_x: end_x, end_z: end_z}) do
    distance_2d(start_x, start_z, end_x, end_z)
  end

  defp bounds_for(
         wifi_points,
         wifi_raster,
         interference_points,
         interference_raster,
         path_points,
         floorplan_segments,
         ap_summaries
       ) do
    points =
      wifi_points ++
        wifi_raster ++
        interference_points ++
        interference_raster ++
        path_points ++
        floorplan_segment_points(floorplan_segments) ++ ap_position_points(ap_summaries)

    xs = Enum.map(points, & &1.x)
    zs = Enum.map(points, & &1.z)

    case {Enum.min(xs, fn -> nil end), Enum.max(xs, fn -> nil end), Enum.min(zs, fn -> nil end),
          Enum.max(zs, fn -> nil end)} do
      {nil, _, _, _} ->
        %{min_x: -1.0, max_x: 1.0, min_z: -1.0, max_z: 1.0, aspect_ratio: 1.0}

      {min_x, max_x, min_z, max_z} ->
        x_pad = max((max_x - min_x) * 0.12, 1.0)
        z_pad = max((max_z - min_z) * 0.12, 1.0)
        min_x = min_x - x_pad
        max_x = max_x + x_pad
        min_z = min_z - z_pad
        max_z = max_z + z_pad
        width = max(max_x - min_x, 0.01)
        height = max(max_z - min_z, 0.01)

        %{
          min_x: min_x,
          max_x: max_x,
          min_z: min_z,
          max_z: max_z,
          aspect_ratio: width / height
        }
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

  defp project_ap_summaries(ap_summaries, bounds) do
    width = max(bounds.max_x - bounds.min_x, 0.01)
    height = max(bounds.max_z - bounds.min_z, 0.01)

    Enum.map(ap_summaries, fn ap ->
      if number?(Map.get(ap, :x)) and number?(Map.get(ap, :z)) do
        ap
        |> Map.put(:x_pct, (ap.x - bounds.min_x) / width * 100.0)
        |> Map.put(:z_pct, 100.0 - (ap.z - bounds.min_z) / height * 100.0)
      else
        ap
      end
    end)
  end

  defp ap_position_points(ap_summaries) do
    ap_summaries
    |> Enum.filter(&(number?(Map.get(&1, :x)) and number?(Map.get(&1, :z))))
    |> Enum.map(&%{x: &1.x, z: &1.z})
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

  defp weighted_average(rows, field_name, weight_field) do
    rows
    |> Enum.reduce({0.0, 0.0}, fn row, {value_acc, weight_acc} ->
      value = field(row, field_name)
      weight = max(number_or_default(field(row, weight_field), 1.0), 1.0)

      if number?(value) do
        {value_acc + value * weight, weight_acc + weight}
      else
        {value_acc, weight_acc}
      end
    end)
    |> weighted_average_result()
  end

  defp weighted_average_maps(rows, field_name, weight_field) do
    rows
    |> Enum.reduce({0.0, 0.0}, fn row, {value_acc, weight_acc} ->
      value = Map.get(row, field_name)
      weight = max(number_or_default(Map.get(row, weight_field), 1.0), 1.0)

      if number?(value) do
        {value_acc + value * weight, weight_acc + weight}
      else
        {value_acc, weight_acc}
      end
    end)
    |> weighted_average_result()
  end

  defp weighted_average_result({_value_acc, weight_acc}) when weight_acc <= 0.0, do: nil
  defp weighted_average_result({value_acc, weight_acc}), do: value_acc / weight_acc

  defp reject_numeric_outliers(rows, _field_name, _floor_threshold) when length(rows) < 4, do: rows

  defp reject_numeric_outliers(rows, field_name, floor_threshold) do
    values = Enum.map(rows, &field_or_map_value(&1, field_name))
    median = percentile(values, 0.5)

    if is_nil(median) do
      rows
    else
      deviations =
        values
        |> Enum.filter(&number?/1)
        |> Enum.map(&abs(&1 - median))

      mad = percentile(deviations, 0.5) || 0.0
      threshold = max(floor_threshold, mad * 4.0)

      Enum.filter(rows, fn row ->
        value = field_or_map_value(row, field_name)
        not number?(value) or abs(value - median) <= threshold
      end)
    end
  end

  defp temporal_bucket_key(row, field_name, fallback_index, bucket_nanos) do
    case field_or_map_value(row, field_name) do
      timestamp when is_integer(timestamp) -> div(timestamp, bucket_nanos)
      timestamp when is_float(timestamp) -> trunc(timestamp / bucket_nanos)
      _ -> {:row, fallback_index}
    end
  end

  defp field_or_map_value(row, field_name), do: field(row, field_name)

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
