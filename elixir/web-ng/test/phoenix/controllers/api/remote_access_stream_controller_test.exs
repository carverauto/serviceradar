defmodule ServiceRadarWebNGWeb.Api.RemoteAccessStreamControllerTest do
  use ExUnit.Case, async: false
  use ServiceRadarWebNGWeb, :verified_routes

  import Phoenix.ConnTest

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.RemoteAccessStreamController
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler

  @endpoint ServiceRadarWebNGWeb.Endpoint
  @moduletag :db_free

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _apps} = Application.ensure_all_started(:plug)
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    previous_loader = Application.get_env(:serviceradar_web_ng, :auth_settings_loader)
    Application.put_env(:serviceradar_web_ng, :auth_settings_loader, fn -> {:error, :not_configured} end)

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

    on_exit(fn -> restore_env(:auth_settings_loader, previous_loader) end)
    :ok
  end

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

  defmodule AuthorizationStub do
    @moduledoc false

    def authorize_current(%Scope{user: %{id: id}} = scope, required_permissions) do
      permissions = Process.get({__MODULE__, id}, scope.permissions || MapSet.new())

      if Enum.all?(required_permissions, &MapSet.member?(permissions, &1)) do
        {:ok, %{scope | permissions: permissions}}
      else
        {:error, :permission_revoked}
      end
    end

    def authorize_current(_scope, _permissions), do: {:error, :permission_revoked}

    def authorize_current_any(scope, permissions) do
      Enum.reduce_while(permissions, {:error, :permission_revoked}, fn permission, _acc ->
        case authorize_current(scope, [permission]) do
          {:ok, refreshed_scope} -> {:halt, {:ok, refreshed_scope}}
          _ -> {:cont, {:error, :permission_revoked}}
        end
      end)
    end

    def set_permissions(user_id, permissions) do
      Process.put({__MODULE__, user_id}, MapSet.new(permissions))
    end
  end

  setup do
    previous_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)

    previous_rdp_enabled =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)

    previous_fetcher = Application.get_env(:serviceradar_web_ng, :remote_access_session_fetcher)
    previous_adapter = Application.get_env(:serviceradar_web_ng, :remote_access_websock_adapter)
    previous_timeout = Application.get_env(:serviceradar_web_ng, :remote_access_browser_stream_timeout_ms)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :remote_access_stream_test_pid)

    previous_authorization_module =
      Application.get_env(:serviceradar_web_ng, :current_user_authorization_module)

    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, true)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)
    Application.put_env(:serviceradar_web_ng, :remote_access_websock_adapter, WebSockAdapterStub)
    Application.put_env(:serviceradar_web_ng, :remote_access_stream_test_pid, self())
    Application.put_env(:serviceradar_web_ng, :current_user_authorization_module, AuthorizationStub)

    on_exit(fn ->
      restore_env(:remote_access_ssh_enabled, previous_enabled)
      restore_env(:remote_access_desktop_rdp_enabled, previous_rdp_enabled)
      restore_env(:remote_access_session_fetcher, previous_fetcher)
      restore_env(:remote_access_websock_adapter, previous_adapter)
      restore_env(:remote_access_browser_stream_timeout_ms, previous_timeout)
      restore_env(:remote_access_stream_test_pid, previous_test_pid)
      restore_env(:current_user_authorization_module, previous_authorization_module)
    end)

    scope =
      Scope.for_user(
        %{id: "user-1", email: "user@example.com", role: :viewer, role_profile_id: nil},
        permissions: MapSet.new(["devices.remote_access.ssh.open"])
      )

    conn =
      build_conn()
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

  test "allows an RDP stream with only RDP permission while SSH is disabled", %{conn: conn} do
    session_id = Ecto.UUID.generate()
    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)

    rdp_scope =
      Scope.for_user(%{id: "user-1", email: "user@example.com"},
        permissions: MapSet.new(["devices.remote_access.rdp.open"])
      )

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts ->
        {:ok, remote_access_session(requested_id, protocol: :rdp, adapter: :rdp)}
      end
    )

    conn =
      conn
      |> Plug.Conn.assign(:current_scope, rdp_scope)
      |> RemoteAccessStreamController.connect(%{"id" => session_id})

    assert conn.halted
    assert_receive {:websock_upgrade, RemoteAccessStreamHandler, handler_opts, _adapter_opts}
    assert handler_opts[:scope] == rdp_scope
  end

  test "rejects an SSH stream when SSH is disabled", %{conn: conn} do
    session_id = Ecto.UUID.generate()
    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts -> {:ok, remote_access_session(requested_id, [])} end
    )

    conn = RemoteAccessStreamController.connect(conn, %{"id" => session_id})
    body = json_response(conn, 404)

    assert body["error"] == "not_found"
    assert body["message"] =~ "SSH"
    refute_receive {:websock_upgrade, _handler, _handler_opts, _adapter_opts}
  end

  test "fails closed for a session protocol that has no browser stream transport", %{conn: conn} do
    session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts ->
        {:ok, remote_access_session(requested_id, protocol: :app, adapter: :app)}
      end
    )

    conn = RemoteAccessStreamController.connect(conn, %{"id" => session_id})
    body = json_response(conn, 404)

    assert body["error"] == "remote_access_session_not_found"
    refute_receive {:websock_upgrade, _handler, _handler_opts, _adapter_opts}
  end

  test "does not attach a stream for another user's session", %{conn: conn} do
    session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts ->
        {:ok, remote_access_session(requested_id, requested_by: "other-user")}
      end
    )

    conn = RemoteAccessStreamController.connect(conn, %{"id" => session_id})
    body = json_response(conn, 404)

    assert body["error"] == "remote_access_session_not_found"
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

  test "rejects a stale scope when current permissions were revoked before upgrade", %{conn: conn} do
    session_id = Ecto.UUID.generate()
    AuthorizationStub.set_permissions("user-1", [])

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts ->
        send(self(), {:unexpected_session_fetch, requested_id})
        {:ok, remote_access_session(requested_id, [])}
      end
    )

    conn = RemoteAccessStreamController.connect(conn, %{"id" => session_id})

    assert json_response(conn, 403)["error"] == "forbidden"
    refute_receive {:unexpected_session_fetch, _requested_id}
    refute_receive {:websock_upgrade, _handler, _handler_opts, _adapter_opts}
  end

  test "router rejects cross-origin browser websocket upgrades" do
    session_id = Ecto.UUID.generate()

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("connection", "Upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("origin", "http://evil.example")
      |> get("/v1/remote-access/sessions/#{session_id}/stream")

    assert conn.status == 403
    refute_receive {:websock_upgrade, _handler, _handler_opts, _adapter_opts}
  end

  test "router allows same-origin browser websocket upgrades through to auth" do
    session_id = Ecto.UUID.generate()

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("connection", "Upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("origin", "http://www.example.com")
      |> get("/v1/remote-access/sessions/#{session_id}/stream")

    assert redirected_to(conn) == "/users/log-in"
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
      requested_by: "user-1",
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
