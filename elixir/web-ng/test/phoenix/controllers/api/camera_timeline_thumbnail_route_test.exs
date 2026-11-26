defmodule ServiceRadarWebNGWeb.Api.CameraTimelineThumbnailRouteTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNGWeb.Api.CameraTimelineController
  alias ServiceRadarWebNGWeb.Auth.ConfigCache

  @endpoint ServiceRadarWebNGWeb.Endpoint
  @moduletag :db_free

  @camera_id "11111111-1111-4111-8111-111111111111"
  @record_id "22222222-2222-4222-8222-222222222222"

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _apps} = Application.ensure_all_started(:plug)
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    previous_loader = Application.get_env(:serviceradar_web_ng, :auth_settings_loader)

    Application.put_env(
      :serviceradar_web_ng,
      :auth_settings_loader,
      fn -> {:error, :not_configured} end
    )

    case Process.whereis(ServiceRadar.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      _pid -> :ok
    end

    case Process.whereis(ConfigCache) do
      nil -> start_supervised!(ConfigCache)
      _pid -> :ok
    end

    case Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      nil -> start_supervised!(ServiceRadarWebNGWeb.Endpoint)
      _pid -> :ok
    end

    on_exit(fn ->
      if is_nil(previous_loader) do
        Application.delete_env(:serviceradar_web_ng, :auth_settings_loader)
      else
        Application.put_env(:serviceradar_web_ng, :auth_settings_loader, previous_loader)
      end
    end)

    :ok
  end

  test "GET /api/cameras/:id/timeline/thumbnails/:kind/:record.jpg negotiates image/jpeg on archive_media_api and refuses unauthenticated requests with 401" do
    for kind <- ["frame", "block", "vantage"] do
      conn =
        build_conn()
        |> put_req_header("accept", "image/jpeg")
        |> get("/api/cameras/#{@camera_id}/timeline/thumbnails/#{kind}/#{@record_id}.jpg")

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "authentication_required"}
      assert get_resp_header(conn, "permissions-policy") != []
    end

    assert_raise Phoenix.NotAcceptableError, fn ->
      build_conn()
      |> put_req_header("accept", "application/xml")
      |> get("/api/cameras/#{@camera_id}/timeline/thumbnails/frame/#{@record_id}.jpg")
    end
  end

  test "CameraTimelineController.thumbnail/2 refuses unauthenticated scope with 401 and private no-store headers" do
    conn =
      :get
      |> build_conn("/api/cameras/#{@camera_id}/timeline/thumbnails/frame/#{@record_id}.jpg")
      |> assign(:current_scope, nil)
      |> CameraTimelineController.thumbnail(%{
        "camera_source_id" => @camera_id,
        "kind" => "frame",
        "id" => "#{@record_id}.jpg"
      })

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end
end
