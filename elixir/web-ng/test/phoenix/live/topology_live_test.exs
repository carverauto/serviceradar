defmodule ServiceRadarWebNGWeb.TopologyLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub

  setup :register_and_log_in_user

  setup do
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    previous_gate_env = System.get_env("SERVICERADAR_MIGRATIONS_GATE")

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    System.put_env("SERVICERADAR_MIGRATIONS_GATE", "false")

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)

      if is_nil(previous_gate_env) do
        System.delete_env("SERVICERADAR_MIGRATIONS_GATE")
      else
        System.put_env("SERVICERADAR_MIGRATIONS_GATE", previous_gate_env)
      end
    end)

    :ok
  end

  test "shows empty topology copy when the stream is healthy but has no graph data", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_stream_stats", %{
        "node_count" => 0,
        "edge_count" => 0,
        "pipeline_stats" => %{}
      })

    assert html =~ "No topology data yet"
    assert html =~ "Run discovery or mapper jobs to populate graph relations."
    refute html =~ "Topology unavailable"
  end

  test "shows loading copy when the initial snapshot stream is still retrying", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html = render_hook(view, "god_view_stream_retrying", %{"reason" => "snapshot_bootstrap_failed"})

    assert html =~ "Loading topology"
    assert html =~ "Waiting for the topology snapshot stream to hydrate."
    refute html =~ "Topology unavailable"
  end

  test "treats transient startup stream errors as retrying until the graph hydrates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html = render_hook(view, "god_view_stream_error", %{"reason" => "snapshot_bootstrap_failed"})

    assert html =~ "Loading topology"
    refute html =~ "Topology unavailable"
  end

  test "keeps topology unavailable copy for fatal startup stream errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html = render_hook(view, "god_view_stream_error", %{"reason" => "decode_error"})

    assert html =~ "Topology unavailable"
    assert html =~ "The topology stream failed."
  end

  test "does not cover an already hydrated topology after a transient stream error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    render_hook(view, "god_view_stream_stats", %{
      "revision" => 42,
      "node_count" => 7,
      "edge_count" => 9,
      "pipeline_stats" => %{"final_nodes" => 7, "final_edges" => 9}
    })

    html = render_hook(view, "god_view_stream_error", %{"reason" => "channel_close"})

    refute html =~ "Topology unavailable"
    refute html =~ "Loading topology"
    refute html =~ "No topology data yet"
  end

  test "topology layer toggle only changes the selected topology control state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/topology")

    assert html =~ "Topology"

    view
    |> element(~s(button[phx-click="toggle_controls_panel"]))
    |> render_click()

    html =
      view
      |> element(~s(button[phx-click="toggle_topology_layer"][phx-value-layer="inferred"]))
      |> render_click()

    assert_push_event(view, "god_view:set_topology_layers", %{
      layers: %{
        "backbone" => true,
        "endpoints" => false,
        "inferred" => true,
        "mtr_paths" => true
      }
    })

    assert html =~ "Topology"
  end

  test "shows the backbone-empty warning with per-class counts and layer call-to-action", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_stream_stats", %{
        "node_count" => 60,
        "edge_count" => 72,
        "pipeline_stats" => %{
          "final_edges" => 72,
          "backbone_edge_count" => 0,
          "edge_class_backbone" => 0,
          "edge_class_attachment" => 57,
          "edge_class_inferred" => 12,
          "edge_class_hosted" => 3,
          "edge_class_observed" => 0
        }
      })

    assert html =~ "Backbone unavailable"
    assert html =~ ~s(data-god-view-safe-area="top")
    assert html =~ "no backbone topology edges"
    assert html =~ "bb:0"
    assert html =~ "att:57"
    assert html =~ "inf:12"
    assert html =~ "host:3"
    assert html =~ "Show attachment layers"
    refute html =~ "No topology data yet"

    html =
      view
      |> element(~s(button[phx-click="enable_attachment_layers"]))
      |> render_click()

    assert_push_event(view, "god_view:set_topology_layers", %{
      layers: %{
        "backbone" => true,
        "endpoints" => true,
        "inferred" => true,
        "mtr_paths" => true
      }
    })

    # The degraded state stays visible, but the CTA disappears once the
    # attachment/inferred layers are already enabled.
    assert html =~ "Backbone unavailable"
    refute html =~ "Show attachment layers"
  end

  test "does not show the backbone-empty warning for a healthy snapshot", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_stream_stats", %{
        "node_count" => 60,
        "edge_count" => 72,
        "pipeline_stats" => %{
          "final_edges" => 72,
          "backbone_edge_count" => 41,
          "edge_class_backbone" => 41,
          "edge_class_attachment" => 20,
          "edge_class_inferred" => 8,
          "edge_class_hosted" => 3,
          "edge_class_observed" => 0
        }
      })

    refute html =~ "Backbone unavailable"
    refute html =~ "Show attachment layers"
  end

  test "does not show the backbone-empty warning when per-class counts are unavailable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_stream_stats", %{
        "node_count" => 60,
        "edge_count" => 72,
        "pipeline_stats" => %{"final_edges" => 72, "final_attachment" => 57}
      })

    refute html =~ "Backbone unavailable"
  end

  test "opens a camera relay from a God-View camera action and renders the viewer panel", %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)
    previous_open_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)
    previous_close_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_close_result)
    previous_fetcher = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)
    previous_fetch_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetch_result)
    previous_poll_interval = Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      CameraRelaySessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_test_pid,
      self()
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_fetcher,
      fn _relay_session_id, _opts ->
        Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetch_result, {:ok, nil})
      end
    )

    Application.put_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, 30_000)

    on_exit(fn ->
      restore_env(:camera_relay_session_manager, previous_manager)
      restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      restore_env(:camera_relay_session_manager_close_result, previous_close_result)
      restore_env(:camera_relay_session_fetcher, previous_fetcher)
      restore_env(:camera_relay_session_fetch_result, previous_fetch_result)
      restore_env(:camera_relay_poll_interval_ms, previous_poll_interval)
      restore_env(:camera_relay_session_manager_test_pid, previous_test_pid)
    end)

    relay_session_id = Ecto.UUID.generate()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_open_result,
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-topology-camera-1",
         gateway_id: "gateway-topology-camera-1",
         status: :opening
       }}
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_close_result,
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-topology-camera-1",
         gateway_id: "gateway-topology-camera-1",
         status: :closing
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_open_camera_relay", %{
        "camera_source_id" => camera_source_id,
        "stream_profile_id" => stream_profile_id,
        "device_uid" => "sr:camera-topology-01",
        "camera_label" => "Lobby Camera",
        "profile_label" => "Main Stream"
      })

    assert_receive {:open_session, ^camera_source_id, ^stream_profile_id, opts}
    assert html =~ "Topology Camera Viewer"
    assert html =~ "Lobby Camera"
    assert html =~ "Main Stream"
    assert html =~ "Preferred transport: websocket_h264_annexb_webcodecs"
    assert html =~ "/v1/camera-relay-sessions/#{relay_session_id}/stream"

    html =
      view
      |> element("button[phx-click='close_camera_relay']")
      |> render_click()

    assert_receive {:close_session, ^relay_session_id, close_opts}
    assert opts[:scope].user.id == close_opts[:scope].user.id
    assert html =~ "Camera relay closing"
  end

  test "passes insecure skip verify when opening a topology camera relay", %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)
    previous_open_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      CameraRelaySessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_test_pid,
      self()
    )

    on_exit(fn ->
      restore_env(:camera_relay_session_manager, previous_manager)
      restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      restore_env(:camera_relay_session_manager_test_pid, previous_test_pid)
    end)

    relay_session_id = Ecto.UUID.generate()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_open_result,
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-topology-camera-1",
         gateway_id: "gateway-topology-camera-1",
         status: :opening
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/topology")

    render_hook(view, "god_view_open_camera_relay", %{
      "camera_source_id" => camera_source_id,
      "stream_profile_id" => stream_profile_id,
      "insecure_skip_verify" => true
    })

    assert_receive {:open_session, ^camera_source_id, ^stream_profile_id, opts}
    assert opts[:insecure_skip_verify] == true
  end

  test "shows auth-required viewer state when topology relay open is rejected", %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)
    previous_open_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      CameraRelaySessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_test_pid,
      self()
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_open_result,
      {:error, "camera authentication required for this source"}
    )

    on_exit(fn ->
      restore_env(:camera_relay_session_manager, previous_manager)
      restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      restore_env(:camera_relay_session_manager_test_pid, previous_test_pid)
    end)

    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_open_camera_relay", %{
        "camera_source_id" => camera_source_id,
        "stream_profile_id" => stream_profile_id,
        "device_uid" => "sr:camera-topology-02",
        "camera_label" => "Warehouse Camera",
        "profile_label" => "Main Stream"
      })

    assert_receive {:open_session, ^camera_source_id, ^stream_profile_id, _opts}
    assert html =~ "Topology Camera Viewer"
    assert html =~ "Camera Authentication Required"
    assert html =~ "camera authentication required for this source"
    assert html =~ "Update camera credentials or source configuration"
  end

  test "shows relay failure details when topology relay refresh returns a failed session", %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)
    previous_open_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)
    previous_fetcher = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)
    previous_fetch_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetch_result)
    previous_poll_interval = Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      CameraRelaySessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_test_pid,
      self()
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_fetcher,
      fn _relay_session_id, _opts ->
        Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetch_result, {:ok, nil})
      end
    )

    Application.put_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, 30_000)

    on_exit(fn ->
      restore_env(:camera_relay_session_manager, previous_manager)
      restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      restore_env(:camera_relay_session_fetcher, previous_fetcher)
      restore_env(:camera_relay_session_fetch_result, previous_fetch_result)
      restore_env(:camera_relay_poll_interval_ms, previous_poll_interval)
      restore_env(:camera_relay_session_manager_test_pid, previous_test_pid)
    end)

    relay_session_id = Ecto.UUID.generate()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_open_result,
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-topology-camera-2",
         gateway_id: "gateway-topology-camera-2",
         status: :opening
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/topology")

    _html =
      render_hook(view, "god_view_open_camera_relay", %{
        "camera_source_id" => camera_source_id,
        "stream_profile_id" => stream_profile_id,
        "device_uid" => "sr:camera-topology-03",
        "camera_label" => "Loading Dock Camera",
        "profile_label" => "Sub Stream"
      })

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_fetch_result,
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         agent_id: "agent-topology-camera-2",
         gateway_id: "gateway-topology-camera-2",
         status: :failed,
         termination_kind: "failure",
         close_reason: "relay session failed",
         failure_reason: "camera relay source runtime unavailable"
       }}
    )

    send(view.pid, {:refresh_camera_relay_session, relay_session_id})
    html = render(view)

    assert html =~ "Topology Camera Viewer"
    assert html =~ "Camera Relay Unavailable"
    assert html =~ "Failure reason: camera relay source runtime unavailable"
    assert html =~ "Last relay status: Failed"
  end

  test "opens a bounded topology camera tile set from clustered camera payloads", %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)
    previous_open_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)
    previous_tile_limit = Application.get_env(:serviceradar_web_ng, :camera_relay_tile_limit)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      CameraRelaySessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_test_pid,
      self()
    )

    Application.put_env(:serviceradar_web_ng, :camera_relay_tile_limit, 2)

    session_ids = %{
      "11111111-1111-1111-1111-111111111111" => Ecto.UUID.generate(),
      "33333333-3333-3333-3333-333333333333" => Ecto.UUID.generate()
    }

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_open_result,
      fn camera_source_id, stream_profile_id, _opts ->
        {:ok,
         %{
           id: Map.fetch!(session_ids, camera_source_id),
           camera_source_id: camera_source_id,
           stream_profile_id: stream_profile_id,
           agent_id: "agent-topology-camera-cluster-1",
           gateway_id: "gateway-topology-camera-cluster-1",
           status: :opening
         }}
      end
    )

    on_exit(fn ->
      restore_env(:camera_relay_session_manager, previous_manager)
      restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      restore_env(:camera_relay_tile_limit, previous_tile_limit)
      restore_env(:camera_relay_session_manager_test_pid, previous_test_pid)
    end)

    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_open_camera_relay_cluster", %{
        "cluster_id" => "cluster:endpoints:sr:switch-01",
        "cluster_label" => "5 endpoints",
        "camera_tiles" => [
          %{
            "camera_source_id" => "11111111-1111-1111-1111-111111111111",
            "stream_profile_id" => "22222222-2222-2222-2222-222222222222",
            "device_uid" => "sr:camera-topology-01",
            "camera_label" => "Lobby Camera",
            "profile_label" => "Main Stream"
          },
          %{
            "camera_source_id" => "33333333-3333-3333-3333-333333333333",
            "stream_profile_id" => "44444444-4444-4444-4444-444444444444",
            "device_uid" => "sr:camera-topology-02",
            "camera_label" => "Loading Dock Camera",
            "profile_label" => "Main Stream"
          },
          %{
            "camera_source_id" => "55555555-5555-5555-5555-555555555555",
            "stream_profile_id" => "66666666-6666-6666-6666-666666666666",
            "device_uid" => "sr:camera-topology-03",
            "camera_label" => "Parking Lot Camera",
            "profile_label" => "Main Stream"
          }
        ]
      })

    assert_receive {:open_session, "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", _opts}

    assert_receive {:open_session, "33333333-3333-3333-3333-333333333333", "44444444-4444-4444-4444-444444444444", _opts}

    refute_receive {:open_session, "55555555-5555-5555-5555-555555555555", _, _}

    assert html =~ "Topology Camera Tile Set"
    assert html =~ "Lobby Camera"
    assert html =~ "Loading Dock Camera"
    refute html =~ "Parking Lot Camera"
    assert html =~ "skipped to stay within the tile limit"
    assert html =~ "/v1/camera-relay-sessions/#{session_ids["11111111-1111-1111-1111-111111111111"]}/stream"
    assert html =~ "/v1/camera-relay-sessions/#{session_ids["33333333-3333-3333-3333-333333333333"]}/stream"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
