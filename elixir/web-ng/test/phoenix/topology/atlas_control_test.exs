defmodule ServiceRadarWebNGWeb.Topology.AtlasControlTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Plug.Conn

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Endpoint
  alias ServiceRadarWebNGWeb.Router
  alias ServiceRadarWebNGWeb.TopologySnapshotController

  @moduletag :db_free

  test "rendered Inferred control defaults off and dispatches its layer toggle" do
    alias ServiceRadarWebNGWeb.TopologyLive.GodView
    alias ServiceRadarWebNGWeb.TopologyLive.GodViewTemplateComponents

    assigns = %{
      snapshot_url: "/topology/snapshot/latest",
      stream_state: :ok,
      last_node_count: 0,
      last_edge_count: 0,
      pipeline_stats: %{},
      controls_collapsed: false,
      visual_layers: %{mantle: true, atmosphere: true},
      zoom_mode: "auto",
      causal_filters: %{healthy: true, unavailable: true, unknown: true},
      topology_layers: %{backbone: true, inferred: false, endpoints: true, mtr_paths: false},
      timezone: "Etc/UTC"
    }

    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, assigns)

    Enum.reduce([false, true, false], socket, fn enabled, socket ->
      html = render_component(&GodViewTemplateComponents.surface/1, socket.assigns)

      control =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("button[phx-value-layer='inferred']")

      assert control |> LazyHTML.text() |> String.trim() == "Inferred"
      assert LazyHTML.attribute(control, "aria-pressed") == [to_string(enabled)]
      [event] = LazyHTML.attribute(control, "phx-click")
      [layer] = LazyHTML.attribute(control, "phx-value-layer")
      {:noreply, next} = GodView.handle_event(event, %{"layer" => layer}, socket)
      assert next.assigns.topology_layers.inferred == !enabled
      assert next.assigns.topology_layers.backbone
      next
    end)
  end

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

    conn = route("/topology/snapshot/latest")
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    assert get_resp_header(conn, "location") == []
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert route("/topology").status == 302

    send(
      ConfigCache,
      {:auth_settings_updated, %{is_enabled: true, mode: :passive_proxy, jwt_header_name: "authorization"}}
    )

    :sys.get_state(ConfigCache)
    rejected = route("/topology/snapshot/latest", [{"authorization", "Bearer invalid"}])
    assert rejected.status == 401
    assert Jason.decode!(rejected.resp_body)["error"] == "unauthorized"
    assert get_resp_header(rejected, "location") == []
    assert get_resp_header(rejected, "cache-control") == ["no-store"]
  end

  test "detail HTTP authenticates before validating requests" do
    conn = TopologySnapshotController.show(Plug.Test.conn(:get, "/"), %{})
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
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
