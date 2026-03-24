defmodule ServiceRadarWebNGWeb.Api.CameraAnalysisWorkerControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.CameraAnalysisWorkersStub

  setup %{conn: conn} do
    previous_module = Application.get_env(:serviceradar_web_ng, :camera_analysis_workers)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_analysis_workers_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_analysis_workers,
      CameraAnalysisWorkersStub
    )

    Application.put_env(:serviceradar_web_ng, :camera_analysis_workers_test_pid, self())

    on_exit(fn ->
      restore_env(:camera_analysis_workers, previous_module)
      restore_env(:camera_analysis_workers_test_pid, previous_test_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "GET /api/admin/camera-analysis-workers" do
    test "lists registered workers", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/camera-analysis-workers")
      body = json_response(conn, 200)

      assert length(body["data"]) == 2
      assert Enum.at(body["data"], 0)["worker_id"] == "worker-alpha"
      assert Enum.at(body["data"], 0)["header_keys"] == ["authorization"]
      assert Enum.at(body["data"], 0)["health_endpoint_url"] == "http://alpha.local/readyz"
      assert Enum.at(body["data"], 0)["health_timeout_ms"] == 1500
      assert Enum.at(body["data"], 0)["probe_interval_ms"] == 10_000
      assert Enum.at(body["data"], 0)["flapping"] == false
      assert Enum.at(body["data"], 0)["alert_active"] == false
      assert Enum.at(body["data"], 0)["routed_alert_active"] == false
      assert Enum.at(body["data"], 0)["recent_probe_results"] != []
      assert Enum.at(body["data"], 1)["health_status"] == "unhealthy"
      assert Enum.at(body["data"], 1)["flapping"] == true
      assert Enum.at(body["data"], 1)["flapping_transition_count"] == 4
      assert Enum.at(body["data"], 1)["flapping_window_size"] == 5
      assert Enum.at(body["data"], 1)["alert_active"] == true
      assert Enum.at(body["data"], 1)["alert_state"] == "flapping"
      assert Enum.at(body["data"], 1)["routed_alert_active"] == true

      assert Enum.at(body["data"], 1)["routed_alert_key"] ==
               "camera_analysis_worker:worker-beta:flapping"

      assert_receive {:camera_analysis_workers_list, opts}
      assert opts[:scope]
    end

    test "passes enabled and limit filters through to worker listing", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/camera-analysis-workers?enabled=true&limit=1")

      assert json_response(conn, 200)

      assert_receive {:camera_analysis_workers_list, opts}
      assert opts[:enabled] == true
      assert opts[:limit] == "1"
      assert opts[:scope]
    end

    test "rejects authenticated users without settings.edge.manage", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/camera-analysis-workers")

      assert conn.status == 403
    end
  end

  describe "GET /api/admin/camera-analysis-workers/:id" do
    test "shows one worker", %{conn: conn} do
      worker_id = "00000000-0000-0000-0000-000000000101"

      conn = get(conn, ~p"/api/admin/camera-analysis-workers/#{worker_id}")
      body = json_response(conn, 200)

      assert body["data"]["id"] == worker_id
      assert body["data"]["worker_id"] == "worker-alpha"
      assert body["data"]["health_path"] == "/health"
      assert body["data"]["flapping"] == false
      assert body["data"]["alert_active"] == false
      assert body["data"]["routed_alert_active"] == false
      assert Enum.at(body["data"]["recent_probe_results"], 0)["status"] == "healthy"

      assert_receive {:camera_analysis_workers_get, ^worker_id, opts}
      assert opts[:scope]
    end

    test "returns 400 for invalid ids", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/camera-analysis-workers/not-a-uuid")
      body = json_response(conn, 400)

      assert body["error"] == "invalid_request"
      assert body["message"] =~ "valid UUID"
    end
  end

  describe "POST /api/admin/camera-analysis-workers" do
    test "creates a worker with normalized attrs", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/camera-analysis-workers", %{
          "worker_id" => "worker-gamma",
          "display_name" => "Gamma Detector",
          "adapter" => "http",
          "endpoint_url" => "http://gamma.local/analyze",
          "health_endpoint_url" => "http://gamma.local/readyz",
          "health_path" => "/healthz",
          "health_timeout_ms" => "1200",
          "probe_interval_ms" => "9000",
          "capabilities" => ["object_detection", " people_count ", ""],
          "enabled" => "false",
          "headers" => %{"authorization" => "Bearer secret"},
          "metadata" => %{"pool" => "default"}
        })

      body = json_response(conn, 201)

      assert body["data"]["worker_id"] == "worker-gamma"
      assert body["data"]["display_name"] == "Gamma Detector"
      assert body["data"]["enabled"] == false
      assert body["data"]["capabilities"] == ["object_detection", "people_count"]
      assert body["data"]["header_keys"] == ["authorization"]
      assert body["data"]["health_endpoint_url"] == "http://gamma.local/readyz"
      assert body["data"]["health_path"] == "/healthz"
      assert body["data"]["health_timeout_ms"] == 1200
      assert body["data"]["probe_interval_ms"] == 9000

      assert_receive {:camera_analysis_workers_create, attrs, opts}
      assert attrs.worker_id == "worker-gamma"
      assert attrs.display_name == "Gamma Detector"
      assert attrs.adapter == "http"
      assert attrs.endpoint_url == "http://gamma.local/analyze"
      assert attrs.health_endpoint_url == "http://gamma.local/readyz"
      assert attrs.health_path == "/healthz"
      assert attrs.health_timeout_ms == 1200
      assert attrs.probe_interval_ms == 9000
      assert attrs.capabilities == ["object_detection", "people_count"]
      assert attrs.enabled == false
      assert attrs.headers == %{"authorization" => "Bearer secret"}
      assert attrs.metadata == %{"pool" => "default"}
      assert opts[:scope]
    end
  end

  describe "PATCH /api/admin/camera-analysis-workers/:id" do
    test "updates a worker with normalized attrs", %{conn: conn} do
      worker_id = "00000000-0000-0000-0000-000000000101"

      conn =
        patch(conn, ~p"/api/admin/camera-analysis-workers/#{worker_id}", %{
          "display_name" => "Alpha Prime",
          "health_endpoint_url" => "http://alpha.local/healthz",
          "health_timeout_ms" => "2400",
          "probe_interval_ms" => "11000",
          "capabilities" => ["object_detection", " vehicle_detection "],
          "enabled" => "false",
          "metadata" => %{"pool" => "overflow"}
        })

      body = json_response(conn, 200)

      assert body["data"]["display_name"] == "Alpha Prime"
      assert body["data"]["enabled"] == false
      assert body["data"]["capabilities"] == ["object_detection", "vehicle_detection"]
      assert body["data"]["health_endpoint_url"] == "http://alpha.local/healthz"
      assert body["data"]["health_timeout_ms"] == 2400
      assert body["data"]["probe_interval_ms"] == 11_000

      assert_receive {:camera_analysis_workers_get, ^worker_id, _opts}
      assert_receive {:camera_analysis_workers_update, ^worker_id, attrs, opts}
      assert attrs.display_name == "Alpha Prime"
      assert attrs.health_endpoint_url == "http://alpha.local/healthz"
      assert attrs.health_timeout_ms == 2400
      assert attrs.probe_interval_ms == 11_000
      assert attrs.capabilities == ["object_detection", "vehicle_detection"]
      assert attrs.enabled == false
      assert attrs.metadata == %{"pool" => "overflow"}
      assert opts[:scope]
    end
  end

  describe "POST /api/admin/camera-analysis-workers/:id/enable" do
    test "enables a worker", %{conn: conn} do
      worker_id = "00000000-0000-0000-0000-000000000102"

      conn = post(conn, ~p"/api/admin/camera-analysis-workers/#{worker_id}/enable", %{})
      body = json_response(conn, 200)

      assert body["data"]["enabled"] == true

      assert_receive {:camera_analysis_workers_get, ^worker_id, _opts}
      assert_receive {:camera_analysis_workers_set_enabled, ^worker_id, true, opts}
      assert opts[:scope]
    end
  end

  describe "POST /api/admin/camera-analysis-workers/:id/disable" do
    test "disables a worker", %{conn: conn} do
      worker_id = "00000000-0000-0000-0000-000000000101"

      conn = post(conn, ~p"/api/admin/camera-analysis-workers/#{worker_id}/disable", %{})
      body = json_response(conn, 200)

      assert body["data"]["enabled"] == false

      assert_receive {:camera_analysis_workers_get, ^worker_id, _opts}
      assert_receive {:camera_analysis_workers_set_enabled, ^worker_id, false, opts}
      assert opts[:scope]
    end
  end
end
