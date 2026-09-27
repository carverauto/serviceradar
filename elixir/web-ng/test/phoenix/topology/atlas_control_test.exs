defmodule ServiceRadarWebNGWeb.Topology.AtlasControlTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Endpoint
  alias ServiceRadarWebNGWeb.Router
  alias ServiceRadarWebNGWeb.TopologyChannel
  alias ServiceRadarWebNGWeb.TopologySnapshotController

  @moduletag :db_free
  @topic "topology:god_view"

  setup do
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    on_exit(fn ->
      if is_nil(previous_flag),
        do: Application.delete_env(:serviceradar_web_ng, :god_view_enabled),
        else: Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)
    end)

    :ok
  end

  test "topology routes return JSON auth failures while the browser route keeps its redirect" do
    prepare_auth_cache()

    for path <- ["/topology/snapshot/latest", "/topology/snapshot/revisions"] do
      conn = route(path)
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
      assert get_resp_header(conn, "location") == []
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    assert route("/topology").status == 302

    send(
      ConfigCache,
      {:auth_settings_updated, %{is_enabled: true, mode: :passive_proxy, jwt_header_name: "authorization"}}
    )

    :sys.get_state(ConfigCache)
    rejected = route("/topology/snapshot/revisions", [{"authorization", "Bearer invalid"}])
    assert rejected.status == 401
    assert Jason.decode!(rejected.resp_body)["error"] == "unauthorized"
    assert get_resp_header(rejected, "location") == []
    assert get_resp_header(rejected, "cache-control") == ["no-store"]
  end

  test "metadata HTTP authenticates before validating requests or reading an atlas" do
    conn = TopologySnapshotController.revisions(Plug.Test.conn(:get, "/"), %{"level_ids" => "invalid"})
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  test "disabled metadata is unavailable without accessing authority or inventory" do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)
    disabled = TopologySnapshotController.revisions(Plug.Test.conn(:get, "/"), %{})
    assert disabled.status == 404
    assert Jason.decode!(disabled.resp_body) == %{"error" => "god_view_disabled"}
  end

  test "channel rejects missing authentication before handling control requests" do
    socket = %Phoenix.Socket{assigns: %{current_user: %{id: "user01"}}}
    assert {:error, %{reason: "unauthorized"}} = TopologyChannel.join(@topic, %{}, socket)

    for event <- ["levels:watch", "cluster:set_expanded", "cluster:collapse_all"] do
      assert {:reply, {:error, %{reason: "unauthorized"}}, ^socket} =
               TopologyChannel.handle_in(event, %{}, socket)
    end
  end

  defp prepare_auth_cache do
    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if is_nil(Process.whereis(ConfigCache)), do: start_supervised!(ConfigCache)
    original = :ets.lookup(ConfigCache, :auth_settings)
    send(ConfigCache, {:auth_settings_updated, %{is_enabled: false, mode: :local}})
    :sys.get_state(ConfigCache)

    on_exit(fn ->
      if :ets.whereis(ConfigCache) != :undefined do
        :ets.delete(ConfigCache, :auth_settings)
        :ets.insert(ConfigCache, original)
      end
    end)
  end

  defp route(path, headers \\ []) do
    :get
    |> Plug.Test.conn(path)
    |> merge_req_headers(headers)
    |> Plug.Test.init_test_session(%{})
    |> put_private(:phoenix_endpoint, Endpoint)
    |> Router.call(Router.init([]))
  end
end
