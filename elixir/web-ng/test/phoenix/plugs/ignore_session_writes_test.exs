defmodule ServiceRadarWebNGWeb.Plugs.IgnoreSessionWritesTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNGWeb.Plugs.IgnoreSessionWrites

  @moduletag :db_free

  # The cookie session store derives its signing key through plug_crypto's ETS
  # key cache (`Plug.Keys`), which is created by the `:plug` application. In this
  # db-free test the app graph isn't started, so start `:plug` to make the real
  # `Plug.Session` cookie write reachable.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:plug)
    :ok
  end

  @session_opts Plug.Session.init(
                  store: :cookie,
                  key: "_ignore_session_writes_test",
                  signing_salt: "kM7sQ2xR"
                )

  # A conn carrying a *dirty* session backed by the real Plug.Session store —
  # exactly like an authenticated browser request whose sliding-session refresh
  # (`UserAuth.fetch_current_scope_for_user/2`) rewrote the session token. This
  # is what makes a subsequent websocket upgrade attempt a `set-cookie` write.
  defp dirty_session_conn do
    :get
    |> build_conn("/v1/camera-relay-sessions/#{Ecto.UUID.generate()}/stream")
    |> Map.put(:secret_key_base, String.duplicate("abcdefgh", 8))
    |> Plug.Session.call(@session_opts)
    |> fetch_session()
    |> put_session("user_token", "rotated-token")
  end

  # Mirrors what `WebSockAdapter.upgrade/4` does: `Plug.Conn.upgrade_adapter/3`
  # runs `run_before_send(conn, :upgraded)` before handing off the socket.
  defp attempt_upgrade(conn) do
    Plug.Conn.upgrade_adapter(conn, :websocket, {:noop_handler, [], []})
  end

  describe "call/2" do
    test "Plug tolerates a dirty session during the websocket upgrade" do
      conn = attempt_upgrade(dirty_session_conn())

      assert conn.state == :upgraded
    end

    test "lets the websocket upgrade succeed by ignoring session writes" do
      conn =
        dirty_session_conn()
        |> IgnoreSessionWrites.call(IgnoreSessionWrites.init([]))
        |> attempt_upgrade()

      assert conn.state == :upgraded
      refute Enum.any?(conn.resp_headers, fn {name, _value} -> name == "set-cookie" end)
    end

    test "marks the session to be ignored" do
      conn = IgnoreSessionWrites.call(dirty_session_conn(), IgnoreSessionWrites.init([]))

      assert conn.private[:plug_session_info] == :ignore
    end

    test "is inert when no session was fetched" do
      conn = build_conn(:get, "/anything")
      assert IgnoreSessionWrites.call(conn, IgnoreSessionWrites.init([])) == conn
    end
  end
end
