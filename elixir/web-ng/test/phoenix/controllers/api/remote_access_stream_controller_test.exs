defmodule ServiceRadarWebNGWeb.Api.RemoteAccessStreamControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.RemoteAccessStreamController
  alias ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler

  defmodule WebSockAdapterStub do
    @moduledoc false

    def upgrade(conn, handler, handler_opts, adapter_opts) do
      send(Application.fetch_env!(:serviceradar_web_ng, :remote_access_stream_test_pid), {
        :websock_upgrade,
        handler,
        handler_opts,
        adapter_opts
      })

      Plug.Conn.assign(conn, :websock_upgraded, true)
    end
  end

  setup %{conn: conn} do
    previous_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)
    previous_fetcher = Application.get_env(:serviceradar_web_ng, :remote_access_session_fetcher)
    previous_adapter = Application.get_env(:serviceradar_web_ng, :remote_access_websock_adapter)
    previous_timeout = Application.get_env(:serviceradar_web_ng, :remote_access_browser_stream_timeout_ms)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :remote_access_stream_test_pid)

    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, true)
    Application.put_env(:serviceradar_web_ng, :remote_access_websock_adapter, WebSockAdapterStub)
    Application.put_env(:serviceradar_web_ng, :remote_access_stream_test_pid, self())

    on_exit(fn ->
      restore_env(:remote_access_ssh_enabled, previous_enabled)
      restore_env(:remote_access_session_fetcher, previous_fetcher)
      restore_env(:remote_access_websock_adapter, previous_adapter)
      restore_env(:remote_access_browser_stream_timeout_ms, previous_timeout)
      restore_env(:remote_access_stream_test_pid, previous_test_pid)
    end)

    scope =
      Scope.for_user(%{id: "user-1", email: "user@example.com"},
        permissions: MapSet.new(["devices.remote_access.ssh.open"])
      )

    conn =
      conn
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.assign(:current_scope, scope)

    %{conn: conn, scope: scope}
  end

  test "uses the shorter session policy timeout for websocket upgrades", %{conn: conn, scope: scope} do
    session_id = Ecto.UUID.generate()

    Application.put_env(:serviceradar_web_ng, :remote_access_browser_stream_timeout_ms, to_timeout(hour: 1))

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, opts ->
        send(self(), {:session_fetch, requested_id, opts})
        {:ok, remote_access_session(requested_id, idle_timeout_seconds: 45, absolute_timeout_seconds: 300)}
      end
    )

    conn = RemoteAccessStreamController.connect(conn, %{"id" => session_id})

    assert conn.halted
    assert conn.assigns.websock_upgraded
    assert_receive {:session_fetch, ^session_id, [scope: ^scope]}

    assert_receive {:websock_upgrade, RemoteAccessStreamHandler, handler_opts, [timeout: 45_000]}
    assert handler_opts[:session_id] == session_id
    assert handler_opts[:scope] == scope
  end

  test "uses the configured timeout when it is shorter than the session policy", %{conn: conn} do
    session_id = Ecto.UUID.generate()

    Application.put_env(:serviceradar_web_ng, :remote_access_browser_stream_timeout_ms, 10_000)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts ->
        {:ok, remote_access_session(requested_id, idle_timeout_seconds: 900, absolute_timeout_seconds: 3600)}
      end
    )

    conn = RemoteAccessStreamController.connect(conn, %{"id" => session_id})

    assert conn.halted
    assert_receive {:websock_upgrade, RemoteAccessStreamHandler, _handler_opts, [timeout: 10_000]}
  end

  test "requires the permission matching the session protocol", %{conn: conn} do
    session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts ->
        {:ok, remote_access_session(requested_id, protocol: :rdp, adapter: :rdp)}
      end
    )

    conn = RemoteAccessStreamController.connect(conn, %{"id" => session_id})
    body = json_response(conn, 403)

    assert body["error"] == "forbidden"
    refute_receive {:websock_upgrade, _handler, _handler_opts, _adapter_opts}
  end

  test "rejects callers without any remote access stream permission before fetching session", %{conn: conn} do
    session_id = Ecto.UUID.generate()
    unauthorized_scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.com"}, permissions: MapSet.new())

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts ->
        send(self(), {:unexpected_session_fetch, requested_id})
        {:ok, remote_access_session(requested_id, [])}
      end
    )

    conn =
      conn
      |> Plug.Conn.assign(:current_scope, unauthorized_scope)
      |> RemoteAccessStreamController.connect(%{"id" => session_id})

    body = json_response(conn, 403)

    assert body["error"] == "forbidden"
    refute_receive {:unexpected_session_fetch, _requested_id}
    refute_receive {:websock_upgrade, _handler, _handler_opts, _adapter_opts}
  end

  defp remote_access_session(session_id, overrides) do
    defaults = %{
      id: session_id,
      device_uid: "linux-1",
      target_kind: :inventory_device,
      target_host: "linux-1.example.com",
      target_port: 22,
      protocol: :ssh,
      adapter: :ssh,
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      credential_custody_mode: :ssh_certificate,
      status: :requested,
      rbac_decision: :allowed,
      attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
      idle_timeout_seconds: 900,
      absolute_timeout_seconds: 3600,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(RemoteAccessSession, Map.merge(defaults, Map.new(overrides)))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
