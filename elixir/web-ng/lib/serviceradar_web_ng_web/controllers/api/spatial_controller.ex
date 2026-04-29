defmodule ServiceRadarWebNGWeb.Api.SpatialController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.FieldSurveyReview
  alias ServiceRadarWebNG.FieldSurveyRoomArtifacts
  alias ServiceRadarWebNG.RBAC

  def index(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, samples} <- FieldSurveyReview.spatial_samples(conn.assigns.current_scope) do
      json(conn, %{data: samples})
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "spatial_samples_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  def scene(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, scene} <- FieldSurveyReview.spatial_scene(conn.assigns.current_scope) do
      json(conn, %{data: scene})
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "spatial_scene_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  def room_artifacts(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, artifacts} <- FieldSurveyReview.room_artifacts(conn.assigns.current_scope) do
      json(conn, %{data: artifacts})
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "room_artifacts_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  def download_room_artifact(conn, %{"id" => artifact_id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, artifact} <- FieldSurveyReview.room_artifact(conn.assigns.current_scope, artifact_id),
         {:ok, payload} <- FieldSurveyRoomArtifacts.fetch(artifact.object_key) do
      conn
      |> put_resp_content_type(artifact.content_type)
      |> put_resp_header("content-disposition", "attachment; filename=\"#{artifact_filename(artifact)}\"")
      |> send_resp(200, payload)
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "room_artifact_not_found"})

      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "room_artifact_download_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  def field_survey_export(conn, %{"session_id" => session_id} = params) do
    format = params |> Map.get("format", "json") |> String.downcase()

    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, review} <- FieldSurveyReview.get_review(conn.assigns.current_scope, session_id) do
      send_field_survey_export(conn, review, format)
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "field_survey_export_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  defp artifact_filename(%{session_id: session_id, artifact_type: artifact_type, content_type: content_type}) do
    extension =
      case {artifact_type, content_type} do
        {"roomplan_usdz", _} -> "usdz"
        {"floorplan_geojson", _} -> "geojson"
        {"point_cloud_ply", _} -> "ply"
        {_, "model/vnd.usdz+zip"} -> "usdz"
        {_, "application/geo+json"} -> "geojson"
        {_, "application/json"} -> "json"
        {_, "application/octet-stream"} -> "bin"
        _ -> "bin"
      end

    "#{safe_filename(session_id)}-#{safe_filename(artifact_type)}.#{extension}"
  end

  defp send_field_survey_export(conn, review, "svg") do
    payload = field_survey_svg(review)

    conn
    |> put_resp_content_type("image/svg+xml")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{safe_filename(review.session_id)}-heatmap.svg\"")
    |> send_resp(200, payload)
  end

  defp send_field_survey_export(conn, review, _format) do
    payload =
      Jason.encode!(%{
        format: "serviceradar.fieldsurvey.review.v1",
        exported_at: DateTime.utc_now(),
        review: review
      })

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{safe_filename(review.session_id)}-review.json\"")
    |> send_resp(200, payload)
  end

  defp field_survey_svg(review) do
    floorplan =
      Enum.map_join(review.floorplan_segments, "\n", fn segment ->
        ~s(<line x1="#{svg_number(segment.start_x_pct)}" y1="#{svg_number(segment.start_z_pct)}" x2="#{svg_number(segment.end_x_pct)}" y2="#{svg_number(segment.end_z_pct)}" class="wall"/>)
      end)

    heat =
      review.wifi_raster
      |> Enum.take(1_000)
      |> Enum.map_join("\n", fn cell ->
        radius = max((cell.radius_pct || 1.2) * 2.8, 2.6)
        opacity = 0.14 + min(max(cell.confidence || 0.0, 0.0), 1.0) * 0.38

        ~s(<circle cx="#{svg_number(cell.x_pct)}" cy="#{svg_number(cell.z_pct)}" r="#{svg_number(radius)}" fill="#{rssi_color(cell.rssi || -95)}" opacity="#{svg_number(opacity)}"/>)
      end)

    aps =
      review.ap_summaries
      |> Enum.filter(&(Map.get(&1, :confidence, 0.0) >= 0.45))
      |> Enum.map_join("\n", fn ap ->
        label = ap |> Map.get(:ssid, "AP") |> xml_escape()

        """
        <g class="ap" transform="translate(#{svg_number(ap.x_pct)} #{svg_number(ap.z_pct)})">
          <circle r="1.9"/>
          <text x="2.6" y="0.4">#{label}</text>
        </g>
        """
      end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" preserveAspectRatio="xMidYMid meet">
      <title>ServiceRadar FieldSurvey #{xml_escape(review.session_id)}</title>
      <defs>
        <filter id="heat-soften" x="-15" y="-15" width="130" height="130" filterUnits="userSpaceOnUse">
          <feGaussianBlur stdDeviation="1.5"/>
        </filter>
        <style>
          .background { fill: #06111f; }
          .grid { stroke: rgba(59, 130, 246, 0.12); stroke-width: 0.12; }
          .heat { filter: url(#heat-soften); }
          .wall { stroke: rgba(205, 250, 255, 0.96); stroke-width: 0.46; stroke-linecap: round; vector-effect: non-scaling-stroke; }
          .ap circle { fill: #020617; stroke: #7dd3fc; stroke-width: 0.6; vector-effect: non-scaling-stroke; }
          .ap text { fill: #e0f2fe; font: 2.2px sans-serif; paint-order: stroke; stroke: #020617; stroke-width: 0.45; }
        </style>
      </defs>
      <rect class="background" width="100" height="100"/>
      #{svg_grid()}
      <g class="heat">#{heat}</g>
      <g>#{floorplan}</g>
      <g>#{aps}</g>
    </svg>
    """
  end

  defp svg_grid do
    Enum.map_join(0..10, "\n", fn index ->
      offset = index * 10

      ~s(<line class="grid" x1="#{offset}" y1="0" x2="#{offset}" y2="100"/><line class="grid" x1="0" y1="#{offset}" x2="100" y2="#{offset}"/>)
    end)
  end

  defp rssi_color(rssi) when rssi >= -50, do: "#16a34a"
  defp rssi_color(rssi) when rssi >= -60, do: "#84cc16"
  defp rssi_color(rssi) when rssi >= -70, do: "#facc15"
  defp rssi_color(rssi) when rssi >= -80, do: "#f97316"
  defp rssi_color(_rssi), do: "#ef4444"

  defp svg_number(value) when is_number(value), do: value |> Float.round(3) |> to_string()
  defp svg_number(_value), do: "0"

  defp xml_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp xml_escape(value), do: value |> to_string() |> xml_escape()

  defp safe_filename(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.slice(0, 120)
  end

  defp safe_filename(_), do: "artifact"

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        :ok

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]

    if RBAC.can?(scope, permission) do
      :ok
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden"})
      |> halt()
    end
  end
end
