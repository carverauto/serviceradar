defmodule ServiceRadarWebNGWeb.Api.RemoteAccessTargetIntentControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.RemoteAccessSessionManagerStub

  setup %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :remote_access_session_manager)

    previous_open_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_open_result)

    previous_test_pid =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_test_pid)

    previous_app_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_app_enabled)
    previous_tcp_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_tcp_enabled)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_manager,
      RemoteAccessSessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_manager_test_pid,
      self()
    )

    Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, true)
    Application.put_env(:serviceradar_web_ng, :remote_access_tcp_enabled, true)

    on_exit(fn ->
      restore_env(:remote_access_session_manager, previous_manager)
      restore_env(:remote_access_session_manager_open_result, previous_open_result)
      restore_env(:remote_access_session_manager_test_pid, previous_test_pid)
      restore_env(:remote_access_app_enabled, previous_app_enabled)
      restore_env(:remote_access_tcp_enabled, previous_tcp_enabled)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "POST /api/remote-access/app-sessions" do
    test "returns not found when application access is disabled", %{conn: conn} do
      Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, false)

      conn = post(conn, ~p"/api/remote-access/app-sessions", %{"target_id" => Ecto.UUID.generate()})

      body = json_response(conn, 404)
      assert body["error"] == "not_found"
      assert body["message"] =~ "Application remote access"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "creates a registered application target intent", %{conn: conn} do
      target_id = Ecto.UUID.generate()
      approval_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        open_result(:app, target_id)
      )

      conn =
        post(conn, ~p"/api/remote-access/app-sessions", %{
          "target_id" => target_id,
          "approval_id" => approval_id
        })

      body = json_response(conn, 201)
      assert body["data"]["protocol"] == "app"
      assert body["data"]["ticket"] == "srra_app_tcp_test_ticket"

      assert_receive {:open_remote_access_session, ^target_id, request, opts}
      assert request.target_id == target_id
      assert request.device_uid == target_id
      assert request.protocol == "app"
      assert request.adapter == "application"
      assert request.target_kind == "registered_application_target"
      assert request.target_host == nil
      assert request.target_port == nil
      assert request.agent_id == nil
      assert request.gateway_id == nil
      assert request.credential_rule_id == nil
      assert request.approval_required == nil
      assert request.approval_id == approval_id
      assert request.metadata == %{}
      assert request.recording_policy == %{}
      assert request.enhanced_recording_policy == %{}
      assert match?(%Scope{}, opts[:scope])
    end
  end

  describe "POST /api/remote-access/tcp-sessions" do
    test "returns not found when TCP access is disabled", %{conn: conn} do
      Application.put_env(:serviceradar_web_ng, :remote_access_tcp_enabled, false)

      conn = post(conn, ~p"/api/remote-access/tcp-sessions", %{"target_id" => Ecto.UUID.generate()})

      body = json_response(conn, 404)
      assert body["error"] == "not_found"
      assert body["message"] =~ "TCP remote access"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "creates a registered TCP target intent", %{conn: conn} do
      target_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        open_result(:tcp, target_id)
      )

      conn = post(conn, ~p"/api/remote-access/tcp-sessions", %{"target_id" => target_id})

      body = json_response(conn, 201)
      assert body["data"]["protocol"] == "tcp"
      assert body["data"]["ticket"] == "srra_app_tcp_test_ticket"

      assert_receive {:open_remote_access_session, ^target_id, request, opts}
      assert request.target_id == target_id
      assert request.device_uid == target_id
      assert request.protocol == "tcp"
      assert request.adapter == "tcp"
      assert request.target_kind == "registered_tcp_target"
      assert request.target_host == nil
      assert request.target_port == nil
      assert request.agent_id == nil
      assert request.gateway_id == nil
      assert request.credential_rule_id == nil
      assert request.approval_required == nil
      assert request.approval_id == nil
      assert request.metadata == %{}
      assert match?(%Scope{}, opts[:scope])
    end
  end

  test "denies users without the app or tcp permission" do
    viewer = viewer_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(viewer)

    for path <- [~p"/api/remote-access/app-sessions", ~p"/api/remote-access/tcp-sessions"] do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> post(path, %{"target_id" => Ecto.UUID.generate()})

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end

    refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
  end

  test "rejects browser-selected upstream and policy overrides", %{conn: conn} do
    override_cases = [
      {"agent_id", "agent-from-browser"},
      {"gateway_id", "gateway-from-browser"},
      {"target_host", "10.0.0.10"},
      {"target_port", 8443},
      {"upstream_host", "169.254.169.254"},
      {"upstream_port", 80},
      {"upstream_url", "http://169.254.169.254/latest/meta-data"},
      {"host_header", "metadata.google.internal"},
      {"sni", "metadata.google.internal"},
      {"tls_server_name", "metadata.google.internal"},
      {"ca_bundle_ref", "browser-ca"},
      {"credential_rule_id", Ecto.UUID.generate()},
      {"credential_custody_mode", "agent_local"},
      {"recording_policy", %{"enabled" => false}},
      {"enhanced_recording_policy", %{"enabled" => false}},
      {"approval_required", false},
      {"quota", %{"bytes" => 1_000_000_000}},
      {"metadata", %{"upstream_host" => "169.254.169.254"}}
    ]

    for path <- [~p"/api/remote-access/app-sessions", ~p"/api/remote-access/tcp-sessions"],
        {field, value} <- override_cases do
      conn =
        post(conn, path, %{
          "target_id" => Ecto.UUID.generate(),
          field => value
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ field
    end

    refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
  end

  test "rejects invalid target and approval IDs", %{conn: conn} do
    conn = post(conn, ~p"/api/remote-access/app-sessions", %{"target_id" => "not-a-uuid"})
    body = json_response(conn, 400)
    assert body["message"] =~ "target_id"

    conn =
      post(conn, ~p"/api/remote-access/tcp-sessions", %{
        "target_id" => Ecto.UUID.generate(),
        "approval_id" => "not-a-uuid"
      })

    body = json_response(conn, 400)
    assert body["message"] =~ "approval_id"

    refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
  end

  defp open_result(:app, target_id) do
    {:ok,
     %{
       session: %RemoteAccessSession{
         id: Ecto.UUID.generate(),
         device_uid: target_id,
         target_kind: :registered_application_target,
         protocol: :app,
         adapter: :application,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         status: :requested,
         rbac_decision: :allowed,
         attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         idle_timeout_seconds: 900,
         absolute_timeout_seconds: 3600,
         inserted_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now()
       },
       ticket: "srra_app_tcp_test_ticket"
     }}
  end

  defp open_result(:tcp, target_id) do
    {:ok,
     %{
       session: %RemoteAccessSession{
         id: Ecto.UUID.generate(),
         device_uid: target_id,
         target_kind: :registered_tcp_target,
         protocol: :tcp,
         adapter: :tcp,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         status: :requested,
         rbac_decision: :allowed,
         attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         idle_timeout_seconds: 900,
         absolute_timeout_seconds: 3600,
         inserted_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now()
       },
       ticket: "srra_app_tcp_test_ticket"
     }}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
