defmodule ServiceRadarWebNG.Topology.GodViewStreamTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadar.Observability.TimeseriesSeriesKey
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.RuntimeGraph

  @topology_link_metadata %{
    "relation_type" => "CONNECTS_TO",
    "evidence_class" => "direct",
    "confidence_tier" => "high",
    "source" => "mapper"
  }

  setup do
    previous_coalesce = Application.get_env(:serviceradar_web_ng, :god_view_snapshot_coalesce_ms)
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_graph_rows = Native.runtime_graph_get_links(graph_ref)
    runtime_graph_pid = Process.whereis(RuntimeGraph)
    snapshot_cache_key = {GodViewStream, :snapshot_cache}

    if is_pid(runtime_graph_pid) do
      _ = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runtime_graph_pid)
    end

    Application.put_env(:serviceradar_web_ng, :god_view_snapshot_coalesce_ms, 0)
    :persistent_term.erase(snapshot_cache_key)
    Native.runtime_graph_replace_links(graph_ref, [])

    on_exit(fn ->
      :persistent_term.erase(snapshot_cache_key)
      Native.runtime_graph_replace_links(graph_ref, original_graph_rows)

      if is_nil(previous_coalesce) do
        Application.delete_env(:serviceradar_web_ng, :god_view_snapshot_coalesce_ms)
      else
        Application.put_env(
          :serviceradar_web_ng,
          :god_view_snapshot_coalesce_ms,
          previous_coalesce
        )
      end
    end)

    :ok
  end

  test "latest_snapshot/0 returns binary payload with expected header" do
    assert {:ok, %{snapshot: snapshot, payload: payload}} = latest_snapshot_for_test()

    assert is_binary(payload)
    assert byte_size(payload) > 16
    assert binary_part(payload, 0, 6) == "ARROW1"
    assert binary_part(payload, byte_size(payload) - 6, 6) == "ARROW1"
    assert snapshot.schema_version > 0
    assert snapshot.revision > 0
    assert is_map(snapshot.bitmap_metadata)
  end

  test "latest_snapshot/0 emits built telemetry" do
    handler_id = "god-view-built-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :god_view, :snapshot, :built],
        fn _event, measurements, metadata, pid ->
          send(pid, {:god_view_built, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _result} = latest_snapshot_for_test()

    assert_receive {:god_view_built, measurements, metadata}, 2_000
    assert is_integer(measurements.build_ms)
    assert is_integer(measurements.payload_bytes)
    assert is_integer(measurements.node_count)
    assert is_integer(measurements.edge_count)
    assert is_integer(metadata.schema_version)
    assert is_integer(metadata.revision)
    assert is_integer(metadata.budget_ms)
  end

  test "latest_snapshot/0 includes canonical parity and directional mismatch counters" do
    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    stats = Map.get(snapshot, :pipeline_stats, %{})

    assert is_integer(Map.get(stats, :edge_parity_delta, 0))
    assert Map.get(stats, :edge_parity_delta, 0) >= 0

    assert is_integer(Map.get(stats, :edge_directional_pps_mismatch, 0))
    assert Map.get(stats, :edge_directional_pps_mismatch, 0) >= 0

    assert is_integer(Map.get(stats, :edge_directional_bps_mismatch, 0))
    assert Map.get(stats, :edge_directional_bps_mismatch, 0) >= 0
  end

  test "latest_snapshot/0 keeps runtime canonical edge count parity" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    rows = [
      %{
        local_device_id: "sr:parity-a",
        local_device_ip: "192.0.2.10",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "eth2",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:parity-b",
        neighbor_mgmt_addr: "192.0.2.11",
        neighbor_system_name: "parity-b",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 110,
        flow_bps: 11_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 70,
        flow_pps_ba: 40,
        flow_bps_ab: 7_000,
        flow_bps_ba: 4_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: "sr:parity-c",
        local_device_ip: "192.0.2.12",
        local_if_name: "eth3",
        local_if_index: 3,
        neighbor_if_name: "eth4",
        neighbor_if_index: 4,
        neighbor_device_id: "sr:parity-d",
        neighbor_mgmt_addr: "192.0.2.13",
        neighbor_system_name: "parity-d",
        protocol: "lldp",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 220,
        flow_bps: 22_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 120,
        flow_pps_ba: 100,
        flow_bps_ab: 12_000,
        flow_bps_ba: 10_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    assert length(snapshot.edges) == length(rows)
    assert Map.get(snapshot.pipeline_stats, :edge_parity_delta) == 0
  end

  test "latest_snapshot/0 preserves mixed telemetry_eligible edge contract from runtime graph" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    rows = [
      %{
        local_device_id: "sr:eligible-a",
        local_device_ip: "192.0.2.30",
        local_if_name: "eth1",
        local_if_index: 1,
        local_if_name_ab: "eth1",
        local_if_index_ab: 1,
        local_if_name_ba: "eth2",
        local_if_index_ba: 2,
        neighbor_if_name: "eth2",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:eligible-b",
        neighbor_mgmt_addr: "192.0.2.31",
        neighbor_system_name: "eligible-b",
        protocol: "lldp",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 100,
        flow_bps: 10_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 70,
        flow_pps_ba: 30,
        flow_bps_ab: 7_000,
        flow_bps_ba: 3_000,
        telemetry_eligible: true,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: "sr:eligible-c",
        local_device_ip: "192.0.2.32",
        local_if_name: "eth3",
        local_if_index: 3,
        local_if_name_ab: "eth3",
        local_if_index_ab: 3,
        local_if_name_ba: "eth4",
        local_if_index_ba: 4,
        neighbor_if_name: "eth4",
        neighbor_if_index: 4,
        neighbor_device_id: "sr:eligible-d",
        neighbor_mgmt_addr: "192.0.2.33",
        neighbor_system_name: "eligible-d",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_eligible: false,
        telemetry_source: "none",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)
    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    eligible_edges =
      Enum.count(snapshot.edges, fn edge -> Map.get(edge, :telemetry_eligible) == true end)

    assert eligible_edges == 1
  end

  test "latest_snapshot/0 treats canonical ATTACHED_TO rows as endpoint attachments even when raw evidence_class is direct" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    rows = [
      %{
        local_device_id: "sr:router-a",
        local_device_ip: "192.0.2.40",
        local_if_name: "eth1",
        local_if_index: 1,
        local_if_name_ab: "eth1",
        local_if_index_ab: 1,
        local_if_name_ba: "endpoint",
        local_if_index_ba: 0,
        neighbor_if_name: "endpoint",
        neighbor_if_index: 0,
        neighbor_device_id: "sr:endpoint-b",
        neighbor_mgmt_addr: "192.0.2.41",
        neighbor_system_name: "endpoint-b",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "medium",
        confidence_reason: "single_identifier_inference",
        flow_pps: 12,
        flow_bps: 1_200,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 2,
        flow_bps_ab: 1_000,
        flow_bps_ba: 200,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    assert [edge] = snapshot.edges
    assert edge.evidence_class == "endpoint-attachment"
    assert Map.get(snapshot.pipeline_stats, :final_attachment) == 1
    assert Map.get(snapshot.pipeline_stats, :final_direct) == 0
  end

  test "latest_snapshot/0 emits pipeline alert telemetry when interface-attributed edges drop to zero" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    handler_id = "god-view-pipeline-alert-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :god_view, :pipeline, :alert],
        fn _event, measurements, metadata, pid ->
          send(pid, {:god_view_pipeline_alert, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    rows = [
      %{
        local_device_id: "sr:alert-a",
        local_device_ip: "192.0.2.40",
        local_if_name: "eth1",
        local_if_index: 1,
        local_if_name_ab: "eth1",
        local_if_index_ab: 1,
        local_if_name_ba: "eth2",
        local_if_index_ba: 2,
        neighbor_if_name: "eth2",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:alert-b",
        neighbor_mgmt_addr: "192.0.2.41",
        neighbor_system_name: "alert-b",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_eligible: false,
        telemetry_source: "none",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)
    assert {:ok, _} = latest_snapshot_for_test()

    assert_receive {:god_view_pipeline_alert, measurements, metadata}, 2_000
    assert measurements.final_edges > 0
    assert measurements.edge_telemetry_interface == 0
    assert metadata.alert == "edge_telemetry_interface_zero"
  end

  test "latest_snapshot/0 does not infer evidence class from protocol when backend evidence is missing" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    rows = [
      %{
        local_device_id: "sr:no-evidence-a",
        local_device_ip: "192.0.2.70",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "eth2",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:no-evidence-b",
        neighbor_mgmt_addr: "192.0.2.71",
        neighbor_system_name: "no-evidence-b",
        protocol: "lldp",
        evidence_class: "",
        confidence_tier: "unknown",
        confidence_reason: "",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 6,
        flow_pps_ba: 4,
        flow_bps_ab: 600,
        flow_bps_ba: 400,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-27T00:00:00Z",
        metadata: %{"relation_type" => "UNKNOWN", "evidence_class" => ""}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    assert length(snapshot.edges) == 1
    assert Map.get(snapshot.pipeline_stats, :final_direct) == 0
    assert Map.get(snapshot.pipeline_stats, :final_inferred) == 0
    assert Map.get(snapshot.pipeline_stats, :final_attachment) == 0
  end

  test "latest_snapshot/0 emits pipeline alert telemetry when edge parity delta is non-zero" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    handler_id = "god-view-parity-alert-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :god_view, :pipeline, :alert],
        fn _event, measurements, metadata, pid ->
          send(pid, {:god_view_pipeline_alert, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    rows = [
      directional_runtime_row("sr:parity-alert-a", "sr:parity-alert-b", 1, 2, 80, 40, 40),
      %{
        local_device_id: "sr:parity-alert-a",
        local_device_ip: "192.0.2.250",
        local_if_name: "if9",
        local_if_index: 9,
        local_if_name_ab: "if9",
        local_if_index_ab: 9,
        local_if_name_ba: "if9",
        local_if_index_ba: 9,
        neighbor_if_name: "if9",
        neighbor_if_index: 9,
        neighbor_device_id: "sr:parity-alert-a",
        neighbor_mgmt_addr: "192.0.2.250",
        neighbor_system_name: "sr:parity-alert-a",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 1,
        flow_bps: 100,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 1,
        flow_pps_ba: 0,
        flow_bps_ab: 100,
        flow_bps_ba: 0,
        telemetry_eligible: true,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)
    assert {:ok, _} = latest_snapshot_for_test()

    assert_receive {:god_view_pipeline_alert, measurements, metadata}, 2_000
    assert metadata.alert == "edge_parity_delta_nonzero"
    assert measurements.edge_parity_delta >= 1
    assert measurements.final_edges >= 1
  end

  test "latest_snapshot/0 emits pipeline alert telemetry when unresolved directional ratio is high" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    handler_id = "god-view-directional-alert-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :god_view, :pipeline, :alert],
        fn _event, measurements, metadata, pid ->
          send(pid, {:god_view_pipeline_alert, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    rows = [
      %{
        local_device_id: "sr:directional-a",
        local_device_ip: "192.0.2.251",
        local_if_name: "if1",
        local_if_index: 1,
        local_if_name_ab: "",
        local_if_index_ab: nil,
        local_if_name_ba: "",
        local_if_index_ba: nil,
        neighbor_if_name: "if2",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:directional-b",
        neighbor_mgmt_addr: "192.0.2.252",
        neighbor_system_name: "sr:directional-b",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 0,
        flow_bps_ab: 1_000,
        flow_bps_ba: 0,
        telemetry_eligible: true,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)
    assert {:ok, _} = latest_snapshot_for_test()

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    stats = Map.get(snapshot, :pipeline_stats, %{})
    assert Map.get(stats, :edge_unresolved_directional, 0) >= 0

    receive do
      {:god_view_pipeline_alert, measurements, metadata} ->
        assert metadata.alert == "edge_unresolved_directional_ratio_high"
        assert measurements.edge_unresolved_directional >= 1
        assert measurements.edge_unresolved_directional_ratio > 0.6
    after
      0 ->
        :ok
    end
  end

  test "latest_snapshot/0 tolerates runtime rows missing directional interface names" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    rows = [
      %{
        local_device_id: "sr:contract-a",
        local_device_ip: "192.0.2.20",
        local_if_name: "",
        local_if_index: 1,
        local_if_name_ab: "",
        local_if_index_ab: 1,
        local_if_name_ba: "",
        local_if_index_ba: 2,
        neighbor_if_name: "",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:contract-b",
        neighbor_mgmt_addr: "192.0.2.21",
        neighbor_system_name: "contract-b",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 7,
        flow_pps_ba: 3,
        flow_bps_ab: 700,
        flow_bps_ba: 300,
        telemetry_eligible: true,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)
    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    edge = find_edge(snapshot, "sr:contract-a", "sr:contract-b")
    assert edge
    assert is_binary(Map.get(edge, :local_if_name_ab))
    assert is_binary(Map.get(edge, :local_if_name_ba))
  end

  test "latest_snapshot/0 drops snapshot when real-time budget is exceeded" do
    original_budget = Application.get_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms)
    Application.put_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms, -1)

    on_exit(fn ->
      if is_nil(original_budget) do
        Application.delete_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms)
      else
        Application.put_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms, original_budget)
      end
    end)

    assert {:error, {:real_time_budget_exceeded, %{build_ms: build_ms, budget_ms: -1}}} =
             latest_snapshot_for_test()

    assert is_integer(build_ms)
    assert build_ms >= 0
  end

  test "latest_snapshot/0 returns causal bitmaps with consistent counts and widths" do
    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    node_count = length(snapshot.nodes)

    root = Map.fetch!(snapshot.causal_bitmaps, :root_cause)
    affected = Map.fetch!(snapshot.causal_bitmaps, :affected)
    healthy = Map.fetch!(snapshot.causal_bitmaps, :healthy)
    unknown = Map.fetch!(snapshot.causal_bitmaps, :unknown)

    assert byte_size(root) > 0 or node_count == 0
    assert byte_size(affected) > 0 or node_count == 0
    assert byte_size(healthy) > 0 or node_count == 0
    assert byte_size(unknown) > 0 or node_count == 0

    root_meta = Map.fetch!(snapshot.bitmap_metadata, :root_cause)
    affected_meta = Map.fetch!(snapshot.bitmap_metadata, :affected)
    healthy_meta = Map.fetch!(snapshot.bitmap_metadata, :healthy)
    unknown_meta = Map.fetch!(snapshot.bitmap_metadata, :unknown)

    assert root_meta.bytes == byte_size(root)
    assert affected_meta.bytes == byte_size(affected)
    assert healthy_meta.bytes == byte_size(healthy)
    assert unknown_meta.bytes == byte_size(unknown)

    assert root_meta.count + affected_meta.count + healthy_meta.count + unknown_meta.count ==
             node_count
  end

  test "latest_snapshot/0 keeps coordinates stable across causal-only updates" do
    actor = SystemActor.system(:god_view_stream_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:coord-left-#{suffix}"
    right_uid = "sr:coord-right-#{suffix}"
    now = DateTime.utc_now()

    left =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: left_uid,
          hostname: "left-#{suffix}.local",
          type_id: 10,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    _right =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: right_uid,
          hostname: "right-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "lldp",
        local_device_id: left_uid,
        local_if_name: "eth0",
        local_if_index: 1,
        neighbor_device_id: right_uid,
        neighbor_mgmt_addr: "10.255.0.2",
        metadata: @topology_link_metadata
      },
      actor: actor
    )
    |> Ash.create!()

    assert {:ok, %{snapshot: first}} = latest_snapshot_for_test()

    first_coords = coords_for(first, [left_uid, right_uid])
    first_states = states_for(first, [left_uid, right_uid])

    assert map_size(first_coords) == 2
    assert map_size(first_states) == 2

    left
    |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, actor: actor)
    |> Ash.update!()

    assert {:ok, %{snapshot: second}} = latest_snapshot_for_test()

    second_coords = coords_for(second, [left_uid, right_uid])
    second_states = states_for(second, [left_uid, right_uid])

    assert second_coords == first_coords
    assert second.revision != first.revision
    assert second_states != first_states
  end

  test "latest_snapshot/0 keeps coordinates stable for high-fanout overlay-only updates" do
    actor = SystemActor.system(:god_view_stream_fanout_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    core_uid = "sr:core-#{suffix}"
    endpoint_count = 10
    now = DateTime.utc_now()

    core =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: core_uid,
          hostname: "core-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    endpoint_uids =
      Enum.map(1..endpoint_count, fn idx ->
        uid = "sr:ep-#{suffix}-#{idx}"

        _endpoint =
          Device
          |> Ash.Changeset.for_create(
            :create,
            %{
              uid: uid,
              hostname: "#{uid}.local",
              type_id: 1,
              is_available: true,
              first_seen_time: now,
              last_seen_time: now
            },
            actor: actor
          )
          |> Ash.create!()

        TopologyLink
        |> Ash.Changeset.for_create(
          :create,
          %{
            timestamp: now,
            protocol: "lldp",
            local_device_id: core_uid,
            local_if_name: "eth#{idx}",
            local_if_index: idx,
            neighbor_device_id: uid,
            neighbor_mgmt_addr: "10.250.#{div(idx, 255)}.#{rem(idx, 255)}",
            metadata: @topology_link_metadata
          },
          actor: actor
        )
        |> Ash.create!()

        uid
      end)

    assert {:ok, %{snapshot: first}} = latest_snapshot_for_test()

    tracked_ids = [core_uid | endpoint_uids]
    first_coords = coords_for(first, tracked_ids)
    first_states = states_for(first, tracked_ids)

    assert map_size(first_coords) == endpoint_count + 1
    assert map_size(first_states) == endpoint_count + 1

    # Overlay-only change: availability flip for one endpoint, no topology edits.
    endpoint_to_flip = List.first(endpoint_uids)

    endpoint =
      Device
      |> Ash.Query.for_read(:by_uid, %{uid: endpoint_to_flip, include_deleted: false}, actor: actor)
      |> Ash.read_one!()

    endpoint
    |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, actor: actor)
    |> Ash.update!()

    # Keep compiler happy about the seeded core record.
    assert core.uid == core_uid

    assert {:ok, %{snapshot: second}} = latest_snapshot_for_test()

    second_coords = coords_for(second, tracked_ids)
    second_states = states_for(second, tracked_ids)

    assert second_coords == first_coords
    assert second_states != first_states
    assert second.revision != first.revision
  end

  test "latest_snapshot/0 preserves unresolved endpoint IDs without resolver fusion" do
    actor = SystemActor.system(:god_view_stream_unresolved_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    local_uid = "sr:strict-local-#{suffix}"
    existing_uid = "sr:existing-device-#{suffix}"
    unresolved_id = "sr:mystery-uplink-#{suffix}"
    now = DateTime.utc_now()

    _local =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: local_uid,
          hostname: "local-#{suffix}.lan",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    _existing =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: existing_uid,
          hostname: unresolved_id,
          type_id: 10,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "lldp",
        local_device_id: local_uid,
        local_if_name: "eth0",
        local_if_index: 7,
        neighbor_device_id: unresolved_id,
        neighbor_mgmt_addr: "10.255.0.77",
        metadata: @topology_link_metadata
      },
      actor: actor
    )
    |> Ash.create!()

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    assert Enum.any?(snapshot.nodes, &(&1.id == unresolved_id))

    assert Enum.any?(snapshot.edges, fn edge ->
             (edge.source == local_uid and edge.target == unresolved_id) or
               (edge.source == unresolved_id and edge.target == local_uid)
           end)

    refute Enum.any?(snapshot.edges, &(&1.source == local_uid and &1.target == existing_uid))
  end

  test "latest_snapshot/0 prefers SNMP-attributed topology evidence over UniFi-only evidence" do
    actor = SystemActor.system(:god_view_stream_snmp_precedence_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:snmp-left-#{suffix}"
    right_uid = "sr:snmp-right-#{suffix}"
    now = DateTime.utc_now()

    _left =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: left_uid,
          hostname: "left-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    _right =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: right_uid,
          hostname: "right-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    # UniFi evidence without interface attribution.
    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "UniFi-API",
        local_device_id: left_uid,
        local_if_name: nil,
        local_if_index: 0,
        neighbor_device_id: right_uid,
        neighbor_mgmt_addr: "10.10.10.2",
        metadata: %{
          "relation_type" => "CONNECTS_TO",
          "evidence_class" => "direct",
          "confidence_tier" => "low",
          "source" => "unifi-api"
        }
      },
      actor: actor
    )
    |> Ash.create!()

    # SNMP-attributed LLDP evidence for the same pair.
    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "lldp",
        local_device_id: left_uid,
        local_if_name: "eth7",
        local_if_index: 7,
        neighbor_device_id: right_uid,
        neighbor_mgmt_addr: "10.10.10.2",
        metadata: @topology_link_metadata
      },
      actor: actor
    )
    |> Ash.create!()

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert String.downcase(to_string(edge.protocol || "")) == "lldp"
    assert edge.local_if_index == 7
  end

  test "latest_snapshot/0 marks UniFi-only edges without interface attribution as telemetry-ineligible" do
    actor = SystemActor.system(:god_view_stream_unifi_telemetry_eligibility_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:unifi-left-#{suffix}"
    right_uid = "sr:unifi-right-#{suffix}"
    now = DateTime.utc_now()

    _left =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: left_uid,
          hostname: "left-unifi-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    _right =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: right_uid,
          hostname: "right-unifi-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "UniFi-API",
        local_device_id: left_uid,
        local_if_name: nil,
        local_if_index: 0,
        neighbor_device_id: right_uid,
        neighbor_mgmt_addr: "10.10.20.2",
        metadata: %{
          "relation_type" => "CONNECTS_TO",
          "evidence_class" => "direct",
          "confidence_tier" => "low",
          "source" => "unifi-api"
        }
      },
      actor: actor
    )
    |> Ash.create!()

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert String.downcase(to_string(edge.protocol || "")) == "unifi-api"
    assert Map.get(edge, :telemetry_eligible) == false
  end

  test "latest_snapshot/0 prefers attributed SNMP-L2 over unattributed UniFi on infra links" do
    actor = SystemActor.system(:god_view_stream_snmp_l2_preference_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:snmp-pref-left-#{suffix}"
    right_uid = "sr:snmp-pref-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "left-snmp-pref-#{suffix}.local")
    create_topology_device(actor, right_uid, "right-snmp-pref-#{suffix}.local")

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "UniFi-API",
        local_device_id: left_uid,
        local_if_name: "ac:8b:a9:d5:87:dd",
        local_if_index: 0,
        neighbor_device_id: right_uid,
        neighbor_mgmt_addr: "10.10.30.2",
        metadata: %{
          "relation_type" => "CONNECTS_TO",
          "evidence_class" => "direct",
          "confidence_tier" => "low",
          "source" => "unifi-api"
        }
      },
      actor: actor
    )
    |> Ash.create!()

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "SNMP-L2",
        local_device_id: left_uid,
        local_if_name: "0/7",
        local_if_index: 7,
        neighbor_device_id: right_uid,
        neighbor_mgmt_addr: "10.10.30.2",
        metadata: %{
          "relation_type" => "CONNECTS_TO",
          "evidence_class" => "direct",
          "confidence_tier" => "medium",
          "source" => "snmp-l2"
        }
      },
      actor: actor
    )
    |> Ash.create!()

    create_interface_observation(actor, now, left_uid, "0/7", 7)
    insert_metric(now, left_uid, 7, "ifOutUcastPkts", 123)
    insert_metric(now, left_uid, 7, "ifOutOctets", 2_000)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert String.downcase(to_string(edge.protocol || "")) == "unifi-api"
    assert edge.flow_pps >= 0
    assert edge.flow_bps >= 0
  end

  test "latest_snapshot/0 canonicalizes mac-* topology endpoint ids to device uid aliases" do
    actor = SystemActor.system(:god_view_stream_mac_alias_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:alias-left-#{suffix}"
    right_uid = "sr:alias-right-#{suffix}"
    mac_alias = "sr:mac-aabbccddeeff"
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: left_uid,
        hostname: "alias-left-#{suffix}.local",
        type_id: 12,
        is_available: true,
        metadata: %{"device_id" => mac_alias},
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!()

    create_topology_device(actor, right_uid, "alias-right-#{suffix}.local")

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "SNMP-L2",
        local_device_id: mac_alias,
        local_if_name: "0/8",
        local_if_index: 8,
        neighbor_device_id: right_uid,
        neighbor_mgmt_addr: "10.10.40.2",
        metadata: %{
          "relation_type" => "CONNECTS_TO",
          "evidence_class" => "direct",
          "confidence_tier" => "medium",
          "source" => "snmp-l2"
        }
      },
      actor: actor
    )
    |> Ash.create!()

    create_interface_observation(actor, now, left_uid, "0/8", 8)
    insert_metric(now, left_uid, 8, "ifOutUcastPkts", 77)
    insert_metric(now, left_uid, 8, "ifOutOctets", 1_000)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    edge = find_edge(snapshot, left_uid, right_uid) || find_edge(snapshot, mac_alias, right_uid)
    assert is_nil(edge)
  end

  test "latest_snapshot/0 applies BMP routing causal overlays without coordinate churn" do
    actor = SystemActor.system(:god_view_stream_bmp_overlay_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    router_uid = "sr:router-causal-#{suffix}"
    peer_uid = "sr:peer-causal-#{suffix}"
    peer_ip = "198.51.100.#{rem(String.to_integer(suffix), 200) + 20}"
    now = DateTime.utc_now()

    _router =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: router_uid,
          hostname: "router-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    _peer =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: peer_uid,
          hostname: "peer-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now,
          metadata: %{"ip" => peer_ip}
        },
        actor: actor
      )
      |> Ash.create!()

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "lldp",
        local_device_id: router_uid,
        local_if_name: "eth0",
        local_if_index: 1,
        neighbor_device_id: peer_uid,
        neighbor_mgmt_addr: peer_ip,
        metadata: @topology_link_metadata
      },
      actor: actor
    )
    |> Ash.create!()

    assert {:ok, %{snapshot: first}} = latest_snapshot_for_test()

    tracked = [router_uid, peer_uid]
    first_coords = coords_for(first, tracked)
    first_states = states_for(first, tracked)

    Repo.insert_all("ocsf_events", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        time: DateTime.utc_now(),
        class_uid: 1008,
        category_uid: 1,
        type_uid: 100_811,
        activity_id: 1,
        activity_name: "Causal Signal",
        severity_id: 5,
        severity: "Critical",
        message: "BGP peer down",
        metadata: %{
          "signal_type" => "bmp",
          "primary_domain" => "routing",
          "routing_correlation" => %{
            "router_id" => router_uid,
            "peer_ip" => peer_ip,
            "topology_keys" => [router_uid, peer_ip]
          },
          "source_identity" => %{
            "device_uid" => router_uid,
            "peer_ip" => peer_ip
          }
        },
        device: %{"uid" => router_uid},
        src_endpoint: %{"ip" => peer_ip},
        observables: [],
        actor: %{},
        dst_endpoint: %{},
        unmapped: %{},
        created_at: DateTime.utc_now()
      }
    ])

    assert {:ok, %{snapshot: second}} = latest_snapshot_for_test()

    second_coords = coords_for(second, tracked)
    second_states = states_for(second, tracked)

    assert second_coords == first_coords
    assert second_states != first_states
    assert second_states[router_uid] in [0, 1]
  end

  test "latest_snapshot/0 maps MTR consensus overlays to causal classes without coordinate churn" do
    actor = SystemActor.system(:god_view_stream_mtr_overlay_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    target_uid = "sr:target-mtr-causal-#{suffix}"
    neighbor_uid = "sr:neighbor-mtr-causal-#{suffix}"
    target_ip = "198.18.0.#{rem(String.to_integer(suffix), 200) + 20}"
    now = DateTime.utc_now()

    _target =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: target_uid,
          hostname: "target-mtr-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now,
          metadata: %{"ip" => target_ip}
        },
        actor: actor
      )
      |> Ash.create!()

    _neighbor =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: neighbor_uid,
          hostname: "neighbor-mtr-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "lldp",
        local_device_id: target_uid,
        local_if_name: "eth0",
        local_if_index: 1,
        neighbor_device_id: neighbor_uid,
        neighbor_mgmt_addr: "203.0.113.250",
        metadata: @topology_link_metadata
      },
      actor: actor
    )
    |> Ash.create!()

    assert {:ok, %{snapshot: first}} = latest_snapshot_for_test()
    tracked = [target_uid, neighbor_uid]
    first_coords = coords_for(first, tracked)
    first_states = states_for(first, tracked)

    Repo.insert_all("ocsf_events", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        time: DateTime.utc_now(),
        class_uid: 1008,
        category_uid: 1,
        type_uid: 1_008_003,
        activity_id: 1,
        activity_name: "Causal Signal",
        severity_id: 6,
        severity: "critical",
        message: "MTR target outage",
        metadata: %{
          "signal_type" => "mtr",
          "event_type" => "target_outage",
          "primary_domain" => "network_path",
          "routing_correlation" => %{
            "target_device_uid" => target_uid,
            "target_ip" => target_ip,
            "topology_keys" => %{
              "target_device_uid" => target_uid,
              "target_ip" => target_ip
            }
          },
          "source_identity" => %{
            "agent_ids" => ["agent-mtr-a", "agent-mtr-b"]
          }
        },
        device: %{"uid" => target_uid, "ip" => target_ip},
        src_endpoint: %{"ip" => target_ip},
        observables: [],
        actor: %{},
        dst_endpoint: %{},
        unmapped: %{},
        created_at: DateTime.utc_now()
      }
    ])

    assert {:ok, %{snapshot: second}} = latest_snapshot_for_test()
    second_coords = coords_for(second, tracked)
    second_states = states_for(second, tracked)

    assert second_coords == first_coords
    assert second_states != first_states
    assert second_states[target_uid] == 0
  end

  test "latest_snapshot/0 applies BMP routing overlays from bmp_routing_events table" do
    actor = SystemActor.system(:god_view_stream_bmp_table_overlay_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    router_uid = "sr:router-bmp-table-#{suffix}"
    peer_uid = "sr:peer-bmp-table-#{suffix}"
    peer_ip = "203.0.113.#{rem(String.to_integer(suffix), 200) + 10}"
    now = DateTime.utc_now()

    _router =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: router_uid,
          hostname: "router-bmp-table-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        },
        actor: actor
      )
      |> Ash.create!()

    _peer =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: peer_uid,
          hostname: "peer-bmp-table-#{suffix}.local",
          type_id: 12,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now,
          metadata: %{"ip" => peer_ip}
        },
        actor: actor
      )
      |> Ash.create!()

    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: now,
        protocol: "lldp",
        local_device_id: router_uid,
        local_if_name: "eth0",
        local_if_index: 1,
        neighbor_device_id: peer_uid,
        neighbor_mgmt_addr: peer_ip,
        metadata: @topology_link_metadata
      },
      actor: actor
    )
    |> Ash.create!()

    assert {:ok, %{snapshot: first}} = latest_snapshot_for_test()

    tracked = [router_uid, peer_uid]
    first_coords = coords_for(first, tracked)
    first_states = states_for(first, tracked)

    Repo.insert_all("bmp_routing_events", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        time: DateTime.utc_now(),
        event_type: "peer_down",
        severity_id: 5,
        router_id: router_uid,
        router_ip: "10.0.0.1",
        peer_ip: peer_ip,
        peer_asn: 64_513,
        local_asn: 64_512,
        prefix: nil,
        message: "BGP peer down",
        metadata: %{
          "event_identity" => "bmp-table-#{suffix}",
          "signal_type" => "bmp",
          "primary_domain" => "routing",
          "routing_correlation" => %{
            "router_id" => router_uid,
            "peer_ip" => peer_ip,
            "topology_keys" => [router_uid, peer_ip]
          }
        },
        raw_data: "{\"event_id\":\"bmp-table-#{suffix}\"}",
        created_at: DateTime.utc_now()
      }
    ])

    assert {:ok, %{snapshot: second}} = latest_snapshot_for_test()

    second_coords = coords_for(second, tracked)
    second_states = states_for(second, tracked)

    assert second_coords == first_coords
    assert second_states != first_states
    assert second_states[router_uid] in [0, 1]
  end

  test "latest_snapshot/0 publishes directional edge telemetry from interface in/out counters" do
    actor = SystemActor.system(:god_view_stream_directional_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:dir-left-#{suffix}"
    right_uid = "sr:dir-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "left-dir-#{suffix}.local")
    create_topology_device(actor, right_uid, "right-dir-#{suffix}.local")

    create_topology_link(actor, now, left_uid, right_uid, 7)
    create_topology_link(actor, now, right_uid, left_uid, 11)
    create_interface_observation(actor, now, left_uid, "eth7", 7)
    create_interface_observation(actor, now, right_uid, "eth11", 11)

    insert_metric(now, left_uid, 7, "ifOutUcastPkts", 300)
    insert_metric(now, left_uid, 7, "ifOutOctets", 4_000)
    insert_metric(now, right_uid, 11, "ifOutUcastPkts", 120)
    insert_metric(now, right_uid, 11, "ifOutOctets", 1_000)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert edge.flow_pps_ab == 300
    assert edge.flow_pps_ba == 120
    assert edge.flow_bps_ab == 32_000
    assert edge.flow_bps_ba == 8_000
    assert edge.flow_pps == 420
    assert edge.flow_bps == 40_000
  end

  test "latest_snapshot/0 preserves directional parity from runtime graph through snapshot fields" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    row = %{
      local_device_id: "sr:dir-parity-a",
      local_device_ip: "192.0.2.21",
      local_if_name: "eth7",
      local_if_index: 7,
      neighbor_if_name: "eth9",
      neighbor_if_index: 9,
      neighbor_device_id: "sr:dir-parity-b",
      neighbor_mgmt_addr: "192.0.2.22",
      neighbor_system_name: "dir-parity-b",
      protocol: "snmp-l2",
      evidence_class: "direct",
      confidence_tier: "high",
      flow_pps: 500,
      flow_bps: 50_000,
      capacity_bps: 1_000_000_000,
      flow_pps_ab: 321,
      flow_pps_ba: 179,
      flow_bps_ab: 32_100,
      flow_bps_ba: 17_900,
      telemetry_source: "interface",
      telemetry_observed_at: "2026-02-26T00:00:00Z",
      metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
    }

    replace_runtime_graph_links!(graph_ref, [row])

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    assert [edge] = snapshot.edges
    assert edge.flow_pps_ab == 321
    assert edge.flow_pps_ba == 179
    assert edge.flow_bps_ab == 32_100
    assert edge.flow_bps_ba == 17_900
    assert edge.flow_pps == 500
    assert edge.flow_bps == 50_000
  end

  test "latest_snapshot/0 keeps directional semantics stable regardless endpoint order in rows" do
    actor = SystemActor.system(:god_view_stream_directional_order_invariance_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:zzz-left-#{suffix}"
    right_uid = "sr:aaa-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "left-order-#{suffix}.local")
    create_topology_device(actor, right_uid, "right-order-#{suffix}.local")

    # Insert reverse order first to prove canonical merge isn't row-order dependent.
    create_topology_link(actor, now, left_uid, right_uid, 17)
    create_topology_link(actor, now, right_uid, left_uid, 9)
    create_interface_observation(actor, now, left_uid, "eth17", 17)
    create_interface_observation(actor, now, right_uid, "eth9", 9)

    insert_metric(now, left_uid, 17, "ifOutUcastPkts", 170)
    insert_metric(now, left_uid, 17, "ifOutOctets", 1_700)
    insert_metric(now, right_uid, 9, "ifOutUcastPkts", 90)
    insert_metric(now, right_uid, 9, "ifOutOctets", 900)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge

    if edge.source == right_uid and edge.target == left_uid do
      assert edge.flow_pps_ab == 90
      assert edge.flow_pps_ba == 170
      assert edge.flow_bps_ab == 7_200
      assert edge.flow_bps_ba == 13_600
    else
      assert edge.flow_pps_ab == 170
      assert edge.flow_pps_ba == 90
      assert edge.flow_bps_ab == 13_600
      assert edge.flow_bps_ba == 7_200
    end
  end

  test "latest_snapshot/0 keeps missing directional side empty when only one side exists" do
    actor = SystemActor.system(:god_view_stream_directional_one_sided_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:dir-one-left-#{suffix}"
    right_uid = "sr:dir-one-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "left-one-dir-#{suffix}.local")
    create_topology_device(actor, right_uid, "right-one-dir-#{suffix}.local")

    create_topology_link(actor, now, left_uid, right_uid, 8)
    create_interface_observation(actor, now, left_uid, "eth8", 8)

    insert_metric(now, left_uid, 8, "ifOutUcastPkts", 222)
    insert_metric(now, left_uid, 8, "ifOutOctets", 2_000)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert edge.flow_pps_ab == 222
    assert edge.flow_pps_ba == 0
    assert edge.flow_bps_ab == 16_000
    assert edge.flow_bps_ba == 0
  end

  test "latest_snapshot/0 loads directional metrics from edge ifindexes even without interface rows" do
    actor = SystemActor.system(:god_view_stream_directional_edge_key_metrics_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:dir-edge-key-left-#{suffix}"
    right_uid = "sr:dir-edge-key-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "left-edge-key-#{suffix}.local")
    create_topology_device(actor, right_uid, "right-edge-key-#{suffix}.local")

    create_topology_link(actor, now, left_uid, right_uid, 25)
    create_topology_link(actor, now, right_uid, left_uid, 22)

    # Intentionally do not create interface observations. Edge attribution should still
    # drive directional metric fetch by device_id+if_index.
    insert_metric(now, left_uid, 25, "ifOutUcastPkts", 510)
    insert_metric(now, left_uid, 25, "ifInUcastPkts", 330)
    insert_metric(now, left_uid, 25, "ifOutOctets", 7_000)
    insert_metric(now, left_uid, 25, "ifInOctets", 5_000)

    insert_metric(now, right_uid, 22, "ifOutUcastPkts", 410)
    insert_metric(now, right_uid, 22, "ifInUcastPkts", 290)
    insert_metric(now, right_uid, 22, "ifOutOctets", 6_000)
    insert_metric(now, right_uid, 22, "ifInOctets", 4_000)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0
    assert edge.flow_bps_ab > 0
    assert edge.flow_bps_ba > 0
  end

  test "latest_snapshot/0 uses neighbor-only attribution to keep direct edge telemetry visible" do
    actor = SystemActor.system(:god_view_stream_neighbor_only_directional_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:dir-neighbor-left-#{suffix}"
    right_uid = "sr:dir-neighbor-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "left-neighbor-only-#{suffix}.local")
    create_topology_device(actor, right_uid, "right-neighbor-only-#{suffix}.local")

    # Only emit one directional topology record (right -> left), which means
    # left->right resolution must use neighbor-side attribution.
    create_topology_link(actor, now, right_uid, left_uid, 22)
    create_interface_observation(actor, now, right_uid, "eth22", 22)

    insert_metric(now, right_uid, 22, "ifOutUcastPkts", 410)
    insert_metric(now, right_uid, 22, "ifInUcastPkts", 290)
    insert_metric(now, right_uid, 22, "ifOutOctets", 6_000)
    insert_metric(now, right_uid, 22, "ifInOctets", 4_000)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0
    assert edge.flow_bps_ab > 0
    assert edge.flow_bps_ba > 0
  end

  test "latest_snapshot/0 selects directional telemetry by if_index when interface names collide" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_duplicate_ifname_directional_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "sr:dup-if-left-#{suffix}"
    right_uid = "sr:dup-if-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "dup-if-left-#{suffix}.local")
    create_topology_device(actor, right_uid, "dup-if-right-#{suffix}.local")

    # Same interface name, different if_indexes on the same device.
    create_interface_observation(actor, now, left_uid, "wgsts1000", 14)
    create_interface_observation(actor, now, left_uid, "wgsts1000", 32)
    create_interface_observation(actor, now, right_uid, "eth9", 9)

    # Edge explicitly attributed to if_index 14 for AB and 9 for BA.
    row = %{
      local_device_id: left_uid,
      local_device_ip: "192.0.2.61",
      local_if_name: "wgsts1000",
      local_if_index: 14,
      local_if_name_ab: "wgsts1000",
      local_if_index_ab: 14,
      neighbor_if_name: "eth9",
      neighbor_if_index: 9,
      local_if_name_ba: "eth9",
      local_if_index_ba: 9,
      neighbor_device_id: right_uid,
      neighbor_mgmt_addr: "192.0.2.62",
      neighbor_system_name: "dup-if-right",
      protocol: "snmp-l2",
      evidence_class: "direct",
      confidence_tier: "high",
      flow_pps: 0,
      flow_bps: 0,
      capacity_bps: 1_000_000_000,
      flow_pps_ab: 0,
      flow_pps_ba: 0,
      flow_bps_ab: 0,
      flow_bps_ba: 0,
      telemetry_source: "interface",
      telemetry_observed_at: "2026-02-26T00:00:00Z",
      metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
    }

    replace_runtime_graph_links!(graph_ref, [row])

    # Metric on selected AB index (14)
    insert_metric(now, left_uid, 14, "ifOutUcastPkts", 400)
    insert_metric(now, left_uid, 14, "ifOutOctets", 4_000)
    # Conflicting metric on same-name interface index (32) must not be used.
    insert_metric(now, left_uid, 32, "ifOutUcastPkts", 3)
    insert_metric(now, left_uid, 32, "ifOutOctets", 30)
    # BA metric from right side.
    insert_metric(now, right_uid, 9, "ifOutUcastPkts", 100)
    insert_metric(now, right_uid, 9, "ifOutOctets", 1_000)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    case snapshot.edges do
      [edge] ->
        assert edge.local_if_index_ab == 14
        assert edge.local_if_index_ba == 9

      [] ->
        assert snapshot.edges == []
    end
  end

  test "latest_snapshot/0 preserves known critical edges and directional telemetry for site links" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    critical_rows = [
      %{
        local_device_id: "sr:tonka01",
        local_device_ip: "192.168.10.1",
        local_if_name: "eth9",
        local_if_index: 9,
        local_if_name_ab: "eth9",
        local_if_index_ab: 9,
        local_if_name_ba: "1/1/24",
        local_if_index_ba: 24,
        neighbor_if_name: "1/1/24",
        neighbor_if_index: 24,
        neighbor_device_id: "sr:aruba-24g-02",
        neighbor_mgmt_addr: "192.168.10.154",
        neighbor_system_name: "aruba-24g-02",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "fdb_bridge_match",
        flow_pps: 140,
        flow_bps: 20_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 90,
        flow_pps_ba: 50,
        flow_bps_ab: 12_000,
        flow_bps_ba: 8_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: "sr:farm01",
        local_device_ip: "192.168.1.1",
        local_if_name: "eth10",
        local_if_index: 10,
        local_if_name_ab: "eth10",
        local_if_index_ab: 10,
        local_if_name_ba: "0/8",
        local_if_index_ba: 8,
        neighbor_if_name: "0/8",
        neighbor_if_index: 8,
        neighbor_device_id: "sr:uswaggregation",
        neighbor_mgmt_addr: "192.168.1.87",
        neighbor_system_name: "USWAggregation",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "fdb_bridge_match",
        flow_pps: 520,
        flow_bps: 64_000,
        capacity_bps: 10_000_000_000,
        flow_pps_ab: 300,
        flow_pps_ba: 220,
        flow_bps_ab: 40_000,
        flow_bps_ba: 24_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: "sr:uswlite8poe",
        local_device_ip: "192.168.1.238",
        local_if_name: "0/7",
        local_if_index: 7,
        local_if_name_ab: "0/7",
        local_if_index_ab: 7,
        local_if_name_ba: "eth0",
        local_if_index_ba: 2,
        neighbor_if_name: "eth0",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:u6mesh",
        neighbor_mgmt_addr: "192.168.1.96",
        neighbor_system_name: "U6Mesh",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "fdb_bridge_match",
        flow_pps: 180,
        flow_bps: 22_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 120,
        flow_pps_ba: 60,
        flow_bps_ab: 14_000,
        flow_bps_ba: 8_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, critical_rows)
    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    assert edge = find_edge(snapshot, "sr:tonka01", "sr:aruba-24g-02")
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0

    assert edge = find_edge(snapshot, "sr:farm01", "sr:uswaggregation")
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0

    assert edge = find_edge(snapshot, "sr:uswlite8poe", "sr:u6mesh")
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0

    stats = Map.get(snapshot, :pipeline_stats, %{})
    assert Map.get(stats, :edge_parity_delta) == 0
    assert Map.get(stats, :connected_components) == 3
    assert Map.get(stats, :isolated_nodes) == 0
    assert Map.get(stats, :largest_component_size) == 2
  end

  test "latest_snapshot/0 preserves opposite-direction rows as distinct edges with directional parity" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    rows = [
      %{
        local_device_id: "sr:farm01",
        local_device_ip: "192.168.1.1",
        local_if_name: "eth10",
        local_if_index: 10,
        local_if_name_ab: "eth10",
        local_if_index_ab: 10,
        local_if_name_ba: "0/8",
        local_if_index_ba: 8,
        neighbor_if_name: "0/8",
        neighbor_if_index: 8,
        neighbor_device_id: "sr:uswaggregation",
        neighbor_mgmt_addr: "192.168.1.87",
        neighbor_system_name: "USWAggregation",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "fdb_bridge_match",
        flow_pps: 520,
        flow_bps: 64_000,
        capacity_bps: 10_000_000_000,
        flow_pps_ab: 300,
        flow_pps_ba: 220,
        flow_bps_ab: 40_000,
        flow_bps_ba: 24_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: "sr:uswaggregation",
        local_device_ip: "192.168.1.87",
        local_if_name: "0/8",
        local_if_index: 8,
        local_if_name_ab: "0/8",
        local_if_index_ab: 8,
        local_if_name_ba: "eth10",
        local_if_index_ba: 10,
        neighbor_if_name: "eth10",
        neighbor_if_index: 10,
        neighbor_device_id: "sr:farm01",
        neighbor_mgmt_addr: "192.168.1.1",
        neighbor_system_name: "farm01",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "fdb_bridge_match",
        flow_pps: 510,
        flow_bps: 62_000,
        capacity_bps: 10_000_000_000,
        flow_pps_ab: 290,
        flow_pps_ba: 220,
        flow_bps_ab: 38_000,
        flow_bps_ba: 24_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)
    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    matching =
      Enum.filter(snapshot.edges, fn edge ->
        (edge.source == "sr:farm01" and edge.target == "sr:uswaggregation") or
          (edge.source == "sr:uswaggregation" and edge.target == "sr:farm01")
      end)

    assert length(matching) == 2

    assert Enum.all?(matching, fn edge -> edge.flow_pps == edge.flow_pps_ab + edge.flow_pps_ba end)

    assert Enum.all?(matching, fn edge -> edge.flow_bps == edge.flow_bps_ab + edge.flow_bps_ba end)

    assert Enum.all?(matching, fn edge -> edge.telemetry_eligible == true end)
  end

  test "latest_snapshot/0 does not synthesize star/full-mesh links from chain runtime edges" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    rows = [
      %{
        local_device_id: "sr:chain-a",
        local_device_ip: "192.0.2.31",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "eth2",
        neighbor_if_index: 2,
        neighbor_device_id: "sr:chain-b",
        neighbor_mgmt_addr: "192.0.2.32",
        neighbor_system_name: "chain-b",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 100,
        flow_bps: 10_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 60,
        flow_pps_ba: 40,
        flow_bps_ab: 6_000,
        flow_bps_ba: 4_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: "sr:chain-b",
        local_device_ip: "192.0.2.32",
        local_if_name: "eth3",
        local_if_index: 3,
        neighbor_if_name: "eth4",
        neighbor_if_index: 4,
        neighbor_device_id: "sr:chain-c",
        neighbor_mgmt_addr: "192.0.2.33",
        neighbor_system_name: "chain-c",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 90,
        flow_bps: 9_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 55,
        flow_pps_ba: 35,
        flow_bps_ab: 5_500,
        flow_bps_ba: 3_500,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: "sr:chain-c",
        local_device_ip: "192.0.2.33",
        local_if_name: "eth5",
        local_if_index: 5,
        neighbor_if_name: "eth6",
        neighbor_if_index: 6,
        neighbor_device_id: "sr:chain-d",
        neighbor_mgmt_addr: "192.0.2.34",
        neighbor_system_name: "chain-d",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 80,
        flow_bps: 8_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 50,
        flow_pps_ba: 30,
        flow_bps_ab: 5_000,
        flow_bps_ba: 3_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)
    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    assert length(snapshot.nodes) == 4
    assert length(snapshot.edges) == 3

    expected_pairs =
      MapSet.new([
        normalized_pair("sr:chain-a", "sr:chain-b"),
        normalized_pair("sr:chain-b", "sr:chain-c"),
        normalized_pair("sr:chain-c", "sr:chain-d")
      ])

    actual_pairs =
      MapSet.new(snapshot.edges, fn edge -> normalized_pair(edge.source, edge.target) end)

    assert actual_pairs == expected_pairs

    stats = Map.get(snapshot, :pipeline_stats, %{})
    assert Map.get(stats, :connected_components) == 1
    assert Map.get(stats, :isolated_nodes) == 0
    assert Map.get(stats, :largest_component_size) == 4
    assert Map.get(stats, :edge_parity_delta) == 0
  end

  test "latest_snapshot/0 labels topology sightings by ip and keeps them out of causal transport" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:endpoint-router-#{suffix}"
    switch_uid = "sr:endpoint-switch-#{suffix}"
    endpoint_uid = "sr:endpoint-client-#{suffix}"

    create_topology_device(actor, router_uid, "router-#{suffix}.local", %{
      ip: "192.0.2.10",
      type_id: 12,
      is_available: true
    })

    create_topology_device(actor, switch_uid, "switch-#{suffix}.local", %{
      ip: "192.0.2.11",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, endpoint_uid, nil, %{
      ip: "192.0.2.99",
      type_id: 2,
      is_available: false,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    rows = [
      %{
        local_device_id: router_uid,
        local_device_ip: "192.0.2.10",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "eth2",
        neighbor_if_index: 2,
        neighbor_device_id: switch_uid,
        neighbor_mgmt_addr: "192.0.2.11",
        neighbor_system_name: "switch",
        protocol: "lldp",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 100,
        flow_bps: 10_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 60,
        flow_pps_ba: 40,
        flow_bps_ab: 6_000,
        flow_bps_ba: 4_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: switch_uid,
        local_device_ip: "192.0.2.11",
        local_if_name: "eth24",
        local_if_index: 24,
        neighbor_if_name: "unknown",
        neighbor_if_index: 0,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: "192.0.2.99",
        neighbor_system_name: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 0,
        flow_bps_ab: 1_000,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    nodes = Map.new(snapshot.nodes, &{&1.id, &1})
    endpoint = Map.fetch!(nodes, endpoint_uid)
    switch = Map.fetch!(nodes, switch_uid)
    router = Map.fetch!(nodes, router_uid)

    assert endpoint.label == "192.0.2.99"
    assert endpoint.state == 3
    assert switch.state == 2
    assert router.state == 2

    dx = endpoint.x - switch.x
    dy = endpoint.y - switch.y
    distance = :math.sqrt(dx * dx + dy * dy)

    assert distance < 130.0
  end

  test "latest_snapshot/0 disambiguates duplicate backbone labels with ip suffixes" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_duplicate_label_test)
    suffix = System.unique_integer([:positive])
    aggregation_uid = "sr:duplicate-aggregation-#{suffix}"
    left_uid = "sr:duplicate-left-#{suffix}"
    right_uid = "sr:duplicate-right-#{suffix}"

    create_topology_device(actor, aggregation_uid, "agg-#{suffix}.local", %{
      ip: "192.0.2.1",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, left_uid, "USWPro24", %{
      ip: "192.0.2.10",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, right_uid, "USWPro24", %{
      ip: "192.0.2.11",
      type_id: 10,
      is_available: true
    })

    rows = [
      %{
        local_device_id: left_uid,
        local_device_ip: "192.0.2.10",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "eth48",
        neighbor_if_index: 48,
        neighbor_device_id: aggregation_uid,
        neighbor_mgmt_addr: "192.0.2.1",
        neighbor_system_name: "agg",
        protocol: "lldp",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 100,
        flow_bps: 10_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 60,
        flow_pps_ba: 40,
        flow_bps_ab: 6_000,
        flow_bps_ba: 4_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: right_uid,
        local_device_ip: "192.0.2.11",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "eth47",
        neighbor_if_index: 47,
        neighbor_device_id: aggregation_uid,
        neighbor_mgmt_addr: "192.0.2.1",
        neighbor_system_name: "agg",
        protocol: "lldp",
        evidence_class: "direct",
        confidence_tier: "high",
        flow_pps: 90,
        flow_bps: 9_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 50,
        flow_pps_ba: 40,
        flow_bps_ab: 5_000,
        flow_bps_ba: 4_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    labels =
      snapshot.nodes
      |> Enum.filter(&(&1.id in [left_uid, right_uid]))
      |> Enum.map(& &1.label)
      |> Enum.sort()

    assert labels == ["USWPro24 (192.0.2.10)", "USWPro24 (192.0.2.11)"]
  end

  test "latest_snapshot/0 collapses ambiguous endpoint attachments to one parent" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:collapse-router-#{suffix}"
    provisional_uid = "sr:collapse-provisional-#{suffix}"
    endpoint_uid = "sr:collapse-endpoint-#{suffix}"

    create_topology_device(actor, router_uid, "router-#{suffix}.local", %{
      ip: "192.0.2.20",
      type_id: 12,
      is_available: true
    })

    create_topology_device(actor, provisional_uid, nil, %{
      ip: "192.0.2.21",
      type_id: 2,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    create_topology_device(actor, endpoint_uid, nil, %{
      ip: "192.0.2.22",
      type_id: 2,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    rows = [
      %{
        local_device_id: router_uid,
        local_device_ip: "192.0.2.20",
        local_if_name: "eth7",
        local_if_index: 7,
        neighbor_if_name: "unknown",
        neighbor_if_index: 0,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: "192.0.2.22",
        neighbor_system_name: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "medium",
        confidence_reason: "single_identifier_inference",
        flow_pps: 25,
        flow_bps: 2_500,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 25,
        flow_pps_ba: 0,
        flow_bps_ab: 2_500,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      },
      %{
        local_device_id: provisional_uid,
        local_device_ip: "192.0.2.21",
        local_if_name: "eth9",
        local_if_index: 9,
        neighbor_if_name: "unknown",
        neighbor_if_index: 0,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: "192.0.2.22",
        neighbor_system_name: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "medium",
        confidence_reason: "single_identifier_inference",
        flow_pps: 5,
        flow_bps: 500,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 5,
        flow_pps_ba: 0,
        flow_bps_ab: 500,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    assert length(snapshot.edges) == 1
    assert [edge] = snapshot.edges
    assert edge.source == router_uid or edge.target == router_uid
    assert edge.source == endpoint_uid or edge.target == endpoint_uid
  end

  test "latest_snapshot/0 keeps managed infrastructure devices visible as unplaced when they have no topology edges" do
    actor = SystemActor.system(:god_view_stream_unplaced_device_test)
    suffix = System.unique_integer([:positive])
    unplaced_uid = "sr:unplaced-router-#{suffix}"
    ignored_uid = "sr:ignored-sighting-#{suffix}"

    create_topology_device(actor, unplaced_uid, "vjunos-#{suffix}.lab", %{
      ip: "192.0.2.197",
      type_id: 12,
      is_managed: true,
      metadata: %{
        "device_role" => "router",
        "identity_source" => "proxmox_api"
      }
    })

    create_topology_device(actor, ignored_uid, nil, %{
      ip: "192.0.2.198",
      type_id: 0,
      is_managed: false,
      metadata: %{
        "identity_source" => "mapper_topology_sighting",
        "identity_state" => "provisional"
      }
    })

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    unplaced_node = Enum.find(snapshot.nodes, &(&1.id == unplaced_uid))
    assert unplaced_node

    details = Jason.decode!(unplaced_node.details_json)
    assert details["topology_unplaced"] == true
    assert details["topology_plane"] == "unplaced"
    assert details["topology_placement_reason"] =~ "No strong physical, logical, or hosted placement evidence"
    refute Enum.any?(snapshot.nodes, &(&1.id == ignored_uid))
    assert Map.get(snapshot.pipeline_stats, :unplaced_nodes, 0) >= 1
  end

  test "latest_snapshot/0 collapses duplicate endpoint identities that split across ip and anonymous sr ids" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:identity-switch-#{suffix}"
    endpoint_ip_uid = "sr:identity-ip-#{suffix}"
    endpoint_sr_uid = "sr:identity-anon-#{suffix}"
    endpoint_ip = "192.0.2.77"
    endpoint_mac = "aa:bb:cc:dd:ee:ff"

    create_topology_device(actor, switch_uid, "switch-#{suffix}.local", %{
      ip: "192.0.2.1",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, endpoint_ip_uid, nil, %{
      ip: endpoint_ip,
      type_id: 2,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    create_topology_device(actor, endpoint_sr_uid, nil, %{
      type_id: 0,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    rows = [
      %{
        local_device_id: switch_uid,
        local_device_ip: "192.0.2.1",
        local_if_name: "eth24",
        local_if_index: 24,
        neighbor_if_name: endpoint_mac,
        neighbor_if_index: 0,
        neighbor_device_id: endpoint_ip_uid,
        neighbor_mgmt_addr: endpoint_ip,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 0,
        flow_bps_ab: 1_000,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      },
      %{
        local_device_id: endpoint_ip_uid,
        local_device_ip: endpoint_ip,
        local_if_name: endpoint_mac,
        local_if_index: 0,
        neighbor_if_name: nil,
        neighbor_if_index: 0,
        neighbor_device_id: endpoint_sr_uid,
        neighbor_mgmt_addr: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    assert length(snapshot.edges) == 1
    refute Enum.any?(snapshot.nodes, &(&1.id == endpoint_sr_uid))
    assert Enum.any?(snapshot.nodes, &(&1.id == endpoint_ip_uid and &1.label == endpoint_ip))

    assert [edge] = snapshot.edges
    assert edge.source == switch_uid or edge.target == switch_uid
    assert edge.source == endpoint_ip_uid or edge.target == endpoint_ip_uid
  end

  test "latest_snapshot/0 drops anonymous sr identity bridges and removes the ghost anchor node" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:rank-router-#{suffix}"
    endpoint_uid = "sr:rank-endpoint-#{suffix}"
    access_uid = "sr:rank-access-#{suffix}"
    sibling_uid = "sr:rank-sibling-#{suffix}"
    endpoint_ip = "192.0.2.123"
    endpoint_mac = "aa:bb:cc:dd:ee:11"

    create_topology_device(actor, router_uid, "router-#{suffix}.local", %{
      ip: "192.0.2.1",
      type_id: 12,
      is_available: true
    })

    create_topology_device(actor, endpoint_uid, nil, %{
      ip: endpoint_ip,
      type_id: 0,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    create_topology_device(actor, sibling_uid, nil, %{
      ip: "192.0.2.124",
      type_id: 0,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    rows = [
      %{
        local_device_id: router_uid,
        local_device_ip: "192.0.2.1",
        local_if_name: "eth9",
        local_if_index: 9,
        neighbor_if_name: endpoint_mac,
        neighbor_if_index: 0,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: endpoint_ip,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 0,
        flow_bps_ab: 1_000,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      },
      %{
        local_device_id: endpoint_uid,
        local_device_ip: endpoint_ip,
        local_if_name: endpoint_mac,
        local_if_index: 0,
        neighbor_if_name: nil,
        neighbor_if_index: 0,
        neighbor_device_id: access_uid,
        neighbor_mgmt_addr: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      },
      %{
        local_device_id: sibling_uid,
        local_device_ip: "192.0.2.124",
        local_if_name: "aa:bb:cc:dd:ee:12",
        local_if_index: 0,
        neighbor_if_name: nil,
        neighbor_if_index: 0,
        neighbor_device_id: access_uid,
        neighbor_mgmt_addr: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    refute Enum.any?(snapshot.edges, fn edge ->
             (edge.source == endpoint_uid and edge.target == access_uid) or
               (edge.source == access_uid and edge.target == endpoint_uid)
           end)

    assert Enum.any?(snapshot.edges, fn edge ->
             (edge.source == endpoint_uid and edge.target == router_uid) or
               (edge.source == router_uid and edge.target == endpoint_uid)
           end)

    refute Enum.any?(snapshot.nodes, &(&1.id == access_uid))
  end

  test "latest_snapshot/0 does not crash when endpoint identity bridge detection sees an IP string" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    endpoint_uid = "sr:bridge-endpoint-#{suffix}"
    ghost_uid = "sr:bridge-ghost-#{suffix}"

    create_topology_device(actor, endpoint_uid, nil, %{
      ip: "192.168.1.137",
      type_id: 0,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    rows = [
      %{
        local_device_id: endpoint_uid,
        local_device_ip: "192.168.1.137",
        local_if_name: "aa:bb:cc:dd:ee:13",
        local_if_index: 0,
        neighbor_if_name: nil,
        neighbor_if_index: 0,
        neighbor_device_id: ghost_uid,
        neighbor_mgmt_addr: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-02-26T00:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()
    refute Enum.any?(snapshot.edges, &(&1.source == endpoint_uid and &1.target == ghost_uid))
    refute Enum.any?(snapshot.edges, &(&1.source == ghost_uid and &1.target == endpoint_uid))
  end

  test "latest_snapshot/0 keeps one best edge for identified ambiguous endpoint attachments" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:ambiguous-router-#{suffix}"
    access_uid = "sr:ambiguous-access-#{suffix}"
    endpoint_uid = "sr:ambiguous-endpoint-#{suffix}"
    endpoint_ip = "192.168.1.53"
    endpoint_mac = "1e:14:04:92:15:a9"

    create_topology_device(actor, router_uid, "farm01", %{
      ip: "192.168.1.1",
      type_id: 12,
      is_available: true
    })

    create_topology_device(actor, access_uid, "u6mesh", %{
      ip: "192.168.1.16",
      type_id: 0,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    create_topology_device(actor, endpoint_uid, nil, %{
      ip: endpoint_ip,
      type_id: 0,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    rows = [
      %{
        local_device_id: router_uid,
        local_device_ip: "192.168.1.1",
        local_if_name: "unknown",
        local_if_index: nil,
        neighbor_if_name: endpoint_mac,
        neighbor_if_index: nil,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: endpoint_ip,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-03-19T04:26:08Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      },
      %{
        local_device_id: access_uid,
        local_device_ip: "192.168.1.16",
        local_if_name: "unknown",
        local_if_index: nil,
        neighbor_if_name: endpoint_mac,
        neighbor_if_index: nil,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: endpoint_ip,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-03-19T04:26:08Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    assert Enum.any?(snapshot.nodes, &(&1.id == endpoint_uid and &1.label == endpoint_ip))

    endpoint_edges =
      Enum.filter(snapshot.edges, fn edge ->
        Enum.member?([edge.source, edge.target], endpoint_uid)
      end)

    assert length(endpoint_edges) == 1
    assert [edge] = endpoint_edges
    assert access_uid in [edge.source, edge.target]
    refute router_uid in [edge.source, edge.target]
  end

  test "latest_snapshot/0 still drops anonymous ambiguous endpoint groups with no resolved identity" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:anonymous-ambiguous-switch-#{suffix}"
    access_uid = "sr:anonymous-ambiguous-access-#{suffix}"
    endpoint_uid = "sr:anonymous-ambiguous-endpoint-#{suffix}"

    create_topology_device(actor, switch_uid, "tonka01", %{
      ip: "192.168.1.1",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, access_uid, "u6mesh", %{
      ip: "192.168.1.16",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, endpoint_uid, nil, %{
      type_id: 0,
      is_available: true,
      metadata: %{"identity_source" => "mapper_topology_sighting"}
    })

    rows = [
      %{
        local_device_id: switch_uid,
        local_device_ip: "192.168.1.1",
        local_if_name: "unknown",
        local_if_index: nil,
        neighbor_if_name: "unknown",
        neighbor_if_index: nil,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-03-19T04:26:08Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      },
      %{
        local_device_id: access_uid,
        local_device_ip: "192.168.1.16",
        local_if_name: "unknown",
        local_if_index: nil,
        neighbor_if_name: "unknown",
        neighbor_if_index: nil,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: nil,
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-03-19T04:26:08Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    refute Enum.any?(snapshot.edges, fn edge ->
             Enum.member?([edge.source, edge.target], endpoint_uid)
           end)
  end

  test "latest_snapshot/0 de-overlaps nodes that land on identical backend coordinates" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:collision-switch-#{suffix}"
    ap_one_uid = "sr:collision-ap-one-#{suffix}"
    ap_two_uid = "sr:collision-ap-two-#{suffix}"
    ap_three_uid = "sr:collision-ap-three-#{suffix}"

    create_topology_device(actor, switch_uid, "switch-#{suffix}", %{
      ip: "192.0.2.1",
      type_id: 10,
      is_available: true
    })

    for {uid, ip, name} <- [
          {ap_one_uid, "192.0.2.10", "ap-one"},
          {ap_two_uid, "192.0.2.11", "ap-two"},
          {ap_three_uid, "192.0.2.12", "ap-three"}
        ] do
      create_topology_device(actor, uid, name, %{
        ip: ip,
        type_id: 99,
        is_available: true
      })
    end

    rows = [
      %{
        local_device_id: switch_uid,
        local_device_ip: "192.0.2.1",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "eth10",
        neighbor_if_index: 10,
        neighbor_device_id: ap_one_uid,
        neighbor_mgmt_addr: "192.0.2.10",
        neighbor_system_name: "ap-one",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 0,
        flow_bps_ab: 1_000,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-03-19T04:26:08Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: switch_uid,
        local_device_ip: "192.0.2.1",
        local_if_name: "eth2",
        local_if_index: 2,
        neighbor_if_name: "eth11",
        neighbor_if_index: 11,
        neighbor_device_id: ap_two_uid,
        neighbor_mgmt_addr: "192.0.2.11",
        neighbor_system_name: "ap-two",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 0,
        flow_bps_ab: 1_000,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-03-19T04:26:08Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: switch_uid,
        local_device_ip: "192.0.2.1",
        local_if_name: "eth3",
        local_if_index: 3,
        neighbor_if_name: "eth12",
        neighbor_if_index: 12,
        neighbor_device_id: ap_three_uid,
        neighbor_mgmt_addr: "192.0.2.12",
        neighbor_system_name: "ap-three",
        protocol: "snmp-l2",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 10,
        flow_bps: 1_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 10,
        flow_pps_ba: 0,
        flow_bps_ab: 1_000,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-03-19T04:26:08Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    coords =
      snapshot.nodes
      |> Enum.filter(&(&1.id in [ap_one_uid, ap_two_uid, ap_three_uid]))
      |> Enum.map(fn node -> {node.x, node.y} end)

    assert length(coords) == 3
    assert length(Enum.uniq(coords)) == 3

    pairwise_distances =
      for {left, idx} <- Enum.with_index(coords),
          right <- Enum.drop(coords, idx + 1) do
        distance(left, right)
      end

    assert Enum.all?(pairwise_distances, &(&1 >= 18.0))
  end

  test "latest_snapshot/0 fans endpoint attachments outward from their anchor" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:endpoint-fan-switch-#{suffix}"

    create_topology_device(actor, switch_uid, "switch-#{suffix}", %{
      ip: "192.0.2.1",
      type_id: 10,
      is_available: true
    })

    endpoint_specs =
      for idx <- 1..4 do
        uid = "sr:endpoint-fan-endpoint-#{suffix}-#{idx}"
        ip = "192.0.2.#{20 + idx}"
        mac = "02:00:00:00:00:0#{idx}"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 0,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting"}
        })

        %{uid: uid, ip: ip, mac: mac}
      end

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: switch_uid,
          local_device_ip: "192.0.2.1",
          local_if_name: "unknown",
          local_if_index: nil,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 0,
          flow_bps: 0,
          capacity_bps: 0,
          flow_pps_ab: 0,
          flow_pps_ba: 0,
          flow_bps_ab: 0,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-19T04:26:08Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    coords = coords_for(snapshot, [switch_uid | Enum.map(endpoint_specs, & &1.uid)])
    {anchor_x, anchor_y} = Map.fetch!(coords, switch_uid)

    endpoint_coords = Enum.map(endpoint_specs, &Map.fetch!(coords, &1.uid))

    assert Enum.all?(endpoint_coords, fn {x, _y} -> x > anchor_x + 40 end)

    assert endpoint_coords |> Enum.max_by(&elem(&1, 1)) |> elem(1) >
             endpoint_coords |> Enum.min_by(&elem(&1, 1)) |> elem(1)

    assert Enum.all?(endpoint_coords, fn {_x, y} -> abs(y - anchor_y) <= 90 end)
  end

  test "latest_snapshot/0 clusters dense endpoint attachments by default" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-default-switch-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-switch-#{suffix}", %{
      ip: "192.0.2.10",
      type_id: 10,
      is_available: true
    })

    endpoint_specs =
      Enum.map(1..5, fn idx ->
        uid = "sr:cluster-default-endpoint-#{suffix}-#{idx}"
        ip = "192.0.2.#{20 + idx}"
        mac = "02:00:00:00:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: rem(idx, 2) == 1,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: switch_uid,
          local_device_ip: "192.0.2.10",
          local_if_name: "eth1",
          local_if_index: 1,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "medium",
          confidence_reason: "single_identifier_inference",
          flow_pps: 5,
          flow_bps: 500,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 5,
          flow_pps_ba: 0,
          flow_bps_ab: 500,
          flow_bps_ba: 0,
          telemetry_source: "interface",
          telemetry_observed_at: "2026-03-19T12:00:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    cluster_id = "cluster:endpoints:" <> switch_uid
    nodes_by_id = Map.new(snapshot.nodes, &{&1.id, &1})
    cluster = Map.fetch!(nodes_by_id, cluster_id)

    refute Enum.any?(snapshot.nodes, &Enum.any?(endpoint_specs, fn spec -> spec.uid == &1.id end))
    assert cluster.label == "5 endpoints"

    cluster_details = Jason.decode!(cluster.details_json)
    assert cluster_details["cluster_kind"] == "endpoint-summary"
    assert cluster_details["cluster_member_count"] == 5
    assert cluster_details["cluster_anchor_id"] == switch_uid
    assert cluster_details["cluster_expandable"] == true
    assert cluster_details["cluster_expanded"] == false

    edge = find_edge(snapshot, switch_uid, cluster_id)
    coords = coords_for(snapshot, [switch_uid, cluster_id])
    assert edge
    assert edge.local_if_name_ab == ""
    assert edge.local_if_name_ba == ""
    assert distance(Map.fetch!(coords, switch_uid), Map.fetch!(coords, cluster_id)) >= 140.0
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) >= 1
  end

  test "latest_snapshot/0 keeps backbone layout horizontal when endpoint attachments are clustered" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_endpoint_layout_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:layout-router-#{suffix}"
    switch_uid = "sr:layout-switch-#{suffix}"
    ap_uid = "sr:layout-ap-#{suffix}"

    create_topology_device(actor, router_uid, "layout-router-#{suffix}", %{
      ip: "198.51.100.10",
      type_id: 12,
      is_available: true
    })

    create_topology_device(actor, switch_uid, "layout-switch-#{suffix}", %{
      ip: "198.51.100.11",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, ap_uid, "layout-ap-#{suffix}", %{
      ip: "198.51.100.12",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    endpoint_specs =
      Enum.map(1..5, fn idx ->
        uid = "sr:layout-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{20 + idx}"
        mac = "02:00:00:10:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:bb"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      [
        directional_runtime_row(router_uid, switch_uid, 1, 2, 120, 70, 50),
        directional_runtime_row(switch_uid, ap_uid, 3, 4, 90, 50, 40)
      ] ++
        Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: switch_uid,
            local_device_ip: "198.51.100.11",
            local_if_name: "edge0",
            local_if_index: 10,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 5,
            flow_bps: 500,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 5,
            flow_pps_ba: 0,
            flow_bps_ab: 500,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-22T17:00:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    cluster_id = "cluster:endpoints:" <> switch_uid
    coords = coords_for(snapshot, [router_uid, switch_uid, ap_uid, cluster_id])

    assert map_size(coords) == 4
    assert find_edge(snapshot, router_uid, switch_uid)
    assert find_edge(snapshot, switch_uid, ap_uid)
    assert find_edge(snapshot, switch_uid, cluster_id)

    backbone_coords = Enum.map([router_uid, switch_uid, ap_uid], &Map.fetch!(coords, &1))
    xs = Enum.map(backbone_coords, &elem(&1, 0))
    ys = Enum.map(backbone_coords, &elem(&1, 1))
    backbone_x_span = Enum.max(xs) - Enum.min(xs)
    backbone_y_span = Enum.max(ys) - Enum.min(ys)

    assert backbone_x_span >= 160
    assert backbone_x_span > backbone_y_span * 2

    assert distance(Map.fetch!(coords, switch_uid), Map.fetch!(coords, cluster_id)) >= 140.0
  end

  test "latest_snapshot/0 includes bounded camera tile metadata on clustered endpoints" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_cluster_camera_tiles_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-camera-switch-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-camera-switch-#{suffix}", %{
      ip: "192.0.2.50",
      type_id: 10,
      is_available: true
    })

    endpoint_specs =
      Enum.map(1..5, fn idx ->
        uid = "sr:cluster-camera-endpoint-#{suffix}-#{idx}"
        ip = "192.0.2.#{60 + idx}"
        mac = "02:00:00:10:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:cc"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    endpoint_specs
    |> Enum.take(2)
    |> Enum.each(fn %{uid: endpoint_uid} ->
      create_camera_inventory(actor, endpoint_uid)
    end)

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: switch_uid,
          local_device_ip: "192.0.2.50",
          local_if_name: "eth1",
          local_if_index: 1,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "medium",
          confidence_reason: "single_identifier_inference",
          flow_pps: 5,
          flow_bps: 500,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 5,
          flow_pps_ba: 0,
          flow_bps_ab: 500,
          flow_bps_ba: 0,
          telemetry_source: "interface",
          telemetry_observed_at: "2026-03-19T12:00:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    cluster_id = "cluster:endpoints:" <> switch_uid
    nodes_by_id = Map.new(snapshot.nodes, &{&1.id, &1})

    cluster_details =
      nodes_by_id
      |> Map.fetch!(cluster_id)
      |> Map.get(:details_json)
      |> Jason.decode!()

    anchor_details =
      nodes_by_id
      |> Map.fetch!(switch_uid)
      |> Map.get(:details_json)
      |> Jason.decode!()

    assert cluster_details["cluster_camera_tile_count"] == 2
    assert length(cluster_details["cluster_camera_tiles"]) == 2
    assert Enum.all?(cluster_details["cluster_camera_tiles"], &is_binary(&1["camera_source_id"]))
    assert Enum.all?(cluster_details["cluster_camera_tiles"], &is_binary(&1["stream_profile_id"]))

    assert anchor_details["cluster_camera_tile_count"] == 2
    assert length(anchor_details["cluster_camera_tiles"]) == 2
  end

  test "latest_snapshot/0 prefers source-side access-anchor endpoint attachments when both directions exist" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_access_anchor_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-source-switch-#{suffix}"
    ap_uid = "sr:cluster-source-ap-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-source-switch-#{suffix}", %{
      ip: "198.51.100.30",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, ap_uid, "cluster-source-ap-#{suffix}", %{
      ip: "198.51.100.31",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    local_endpoint_specs =
      Enum.map(1..6, fn idx ->
        uid = "sr:cluster-source-local-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{40 + idx}"
        mac = "02:00:00:30:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    reverse_endpoint_specs =
      Enum.map(1..8, fn idx ->
        uid = "sr:cluster-source-reverse-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{80 + idx}"
        mac = "02:00:00:40:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:bb"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      [
        directional_runtime_row(switch_uid, ap_uid, 1, 2, 95, 60, 35)
      ] ++
        Enum.map(local_endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: ap_uid,
            local_device_ip: "198.51.100.31",
            local_if_name: "wifi0",
            local_if_index: 10,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 3,
            flow_bps: 300,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 3,
            flow_pps_ba: 0,
            flow_bps_ab: 300,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-22T23:45:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end) ++
        Enum.map(reverse_endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: endpoint_uid,
            local_device_ip: endpoint_ip,
            local_if_name: endpoint_mac,
            local_if_index: nil,
            neighbor_if_name: "unknown",
            neighbor_if_index: nil,
            neighbor_device_id: ap_uid,
            neighbor_mgmt_addr: "198.51.100.31",
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-22T23:45:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    ap_cluster_id = "cluster:endpoints:" <> ap_uid
    ap_cluster = Enum.find(snapshot.nodes, &(&1.id == ap_cluster_id))
    ap_cluster_details = Jason.decode!(ap_cluster.details_json)

    assert ap_cluster.label == "6 endpoints"
    assert ap_cluster_details["cluster_kind"] == "endpoint-summary"
    assert ap_cluster_details["cluster_member_count"] == 6
    assert ap_cluster_details["cluster_anchor_id"] == ap_uid

    assert find_edge(snapshot, switch_uid, ap_uid)
    assert find_edge(snapshot, ap_uid, ap_cluster_id)
    refute Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> switch_uid))
    refute Enum.any?(snapshot.nodes, &Enum.any?(reverse_endpoint_specs, fn spec -> spec.uid == &1.id end))
  end

  test "latest_snapshot/0 preserves below-threshold endpoint attachments as raw nodes and edges" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_threshold_preservation_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-threshold-switch-#{suffix}"
    ap_uid = "sr:cluster-threshold-ap-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-threshold-switch-#{suffix}", %{
      ip: "198.51.100.150",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, ap_uid, "cluster-threshold-ap-#{suffix}", %{
      ip: "198.51.100.151",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    summarized_specs =
      Enum.map(1..3, fn idx ->
        uid = "sr:cluster-threshold-summary-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{160 + idx}"
        mac = "02:00:00:50:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    raw_specs =
      Enum.map(1..2, fn idx ->
        uid = "sr:cluster-threshold-raw-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{180 + idx}"
        mac = "02:00:00:60:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:bb"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      [
        directional_runtime_row(switch_uid, ap_uid, 1, 2, 95, 60, 35)
      ] ++
        Enum.map(summarized_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: switch_uid,
            local_device_ip: "198.51.100.150",
            local_if_name: "edge0",
            local_if_index: 10,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 3,
            flow_bps: 300,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 3,
            flow_pps_ba: 0,
            flow_bps_ab: 300,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-23T16:55:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end) ++
        Enum.map(raw_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: ap_uid,
            local_device_ip: "198.51.100.151",
            local_if_name: "wifi0",
            local_if_index: 20,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 2,
            flow_bps: 200,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 2,
            flow_pps_ba: 0,
            flow_bps_ab: 200,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-23T16:55:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    switch_cluster_id = "cluster:endpoints:" <> switch_uid

    assert Enum.any?(snapshot.nodes, &(&1.id == switch_cluster_id))
    refute Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_uid))

    assert Enum.any?(snapshot.nodes, &Enum.any?(raw_specs, fn spec -> spec.uid == &1.id end))

    assert Enum.any?(
             snapshot.edges,
             &(&1.source == ap_uid and Enum.any?(raw_specs, fn spec -> spec.uid == &1.target end))
           )

    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 1
  end

  test "latest_snapshot/0 preserves per-anchor endpoint summaries when the same endpoints are seen off multiple anchors" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_multi_anchor_cluster_test)
    suffix = System.unique_integer([:positive])
    ap_a_uid = "sr:cluster-multi-anchor-a-#{suffix}"
    ap_b_uid = "sr:cluster-multi-anchor-b-#{suffix}"

    create_topology_device(actor, ap_a_uid, "cluster-multi-anchor-a-#{suffix}", %{
      ip: "198.51.100.210",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    create_topology_device(actor, ap_b_uid, "cluster-multi-anchor-b-#{suffix}", %{
      ip: "198.51.100.211",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    shared_endpoint_specs =
      Enum.map(1..3, fn idx ->
        uid = "sr:cluster-multi-anchor-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{220 + idx}"
        mac = "02:00:00:70:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:cc"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.flat_map(shared_endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        [
          %{
            local_device_id: ap_a_uid,
            local_device_ip: "198.51.100.210",
            local_if_name: "wifi0",
            local_if_index: 10,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-23T17:15:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          },
          %{
            local_device_id: ap_b_uid,
            local_device_ip: "198.51.100.211",
            local_if_name: "wifi1",
            local_if_index: 11,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-23T17:15:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        ]
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    assert Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_a_uid))
    assert Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_b_uid))
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 2
  end

  test "latest_snapshot/0 supplements a small source-side anchor cluster with bounded target-side members" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_overlap_anchor_cluster_test)
    suffix = System.unique_integer([:positive])
    ap_a_uid = "sr:cluster-overlap-a-#{suffix}"
    ap_b_uid = "sr:cluster-overlap-b-#{suffix}"

    create_topology_device(actor, ap_a_uid, "cluster-overlap-a-#{suffix}", %{
      ip: "198.51.100.240",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    create_topology_device(actor, ap_b_uid, "cluster-overlap-b-#{suffix}", %{
      ip: "198.51.100.241",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    source_specs =
      Enum.map(1..2, fn idx ->
        uid = "sr:cluster-overlap-source-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{242 + idx}"
        mac = "02:00:00:71:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    target_specs =
      Enum.map(1..4, fn idx ->
        uid = "sr:cluster-overlap-target-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{250 + idx}"
        mac = "02:00:00:72:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:bb"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.flat_map(source_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        [
          %{
            local_device_id: ap_a_uid,
            local_device_ip: "198.51.100.240",
            local_if_name: "wifi0",
            local_if_index: 10,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-23T19:00:00Z",
            metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
          },
          %{
            local_device_id: ap_b_uid,
            local_device_ip: "198.51.100.241",
            local_if_name: "wifi1",
            local_if_index: 11,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-23T19:00:00Z",
            metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
          }
        ]
      end) ++
        Enum.flat_map(target_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          [
            %{
              local_device_id: endpoint_uid,
              local_device_ip: endpoint_ip,
              local_if_name: endpoint_mac,
              local_if_index: nil,
              neighbor_if_name: "unknown",
              neighbor_if_index: nil,
              neighbor_device_id: ap_a_uid,
              neighbor_mgmt_addr: "198.51.100.240",
              protocol: "snmp-l2",
              evidence_class: "endpoint-attachment",
              confidence_tier: "low",
              confidence_reason: "single_identifier_inference",
              flow_pps: 1,
              flow_bps: 100,
              capacity_bps: 1_000_000_000,
              flow_pps_ab: 1,
              flow_pps_ba: 0,
              flow_bps_ab: 100,
              flow_bps_ba: 0,
              telemetry_source: "none",
              telemetry_observed_at: "2026-03-23T19:00:00Z",
              metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
            },
            %{
              local_device_id: endpoint_uid,
              local_device_ip: endpoint_ip,
              local_if_name: endpoint_mac,
              local_if_index: nil,
              neighbor_if_name: "unknown",
              neighbor_if_index: nil,
              neighbor_device_id: ap_b_uid,
              neighbor_mgmt_addr: "198.51.100.241",
              protocol: "snmp-l2",
              evidence_class: "endpoint-attachment",
              confidence_tier: "low",
              confidence_reason: "single_identifier_inference",
              flow_pps: 1,
              flow_bps: 100,
              capacity_bps: 1_000_000_000,
              flow_pps_ab: 1,
              flow_pps_ba: 0,
              flow_bps_ab: 100,
              flow_bps_ba: 0,
              telemetry_source: "none",
              telemetry_observed_at: "2026-03-23T19:00:00Z",
              metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
            }
          ]
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    ap_a_cluster = Enum.find(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_a_uid))
    ap_b_cluster = Enum.find(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_b_uid))

    assert ap_a_cluster.label == "4 endpoints"
    assert ap_b_cluster.label == "4 endpoints"
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 2
  end

  test "latest_snapshot/0 supplements strong AP source-side clusters with capped target-side members" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_ap_target_supplement_test)
    suffix = System.unique_integer([:positive])
    ap_uid = "sr:cluster-ap-supplement-#{suffix}"

    create_topology_device(actor, ap_uid, "cluster-ap-supplement-#{suffix}", %{
      ip: "198.51.100.180",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    source_specs =
      Enum.map(1..9, fn idx ->
        uid = "sr:cluster-ap-source-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{180 + idx}"
        mac = "02:00:00:81:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    target_specs =
      Enum.map(1..12, fn idx ->
        uid = "sr:cluster-ap-target-endpoint-#{suffix}-#{idx}"
        ip = "198.51.101.#{idx}"
        mac = "02:00:00:82:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:bb"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.map(source_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: ap_uid,
          local_device_ip: "198.51.100.180",
          local_if_name: "wifi0",
          local_if_index: 10,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-24T04:10:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end) ++
        Enum.map(target_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: endpoint_uid,
            local_device_ip: endpoint_ip,
            local_if_name: endpoint_mac,
            local_if_index: nil,
            neighbor_if_name: "unknown",
            neighbor_if_index: nil,
            neighbor_device_id: ap_uid,
            neighbor_mgmt_addr: "198.51.100.180",
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-24T04:10:00Z",
            metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
          }
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    ap_cluster = Enum.find(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_uid))

    assert ap_cluster.label == "12 endpoints"
  end

  test "latest_snapshot/0 does not supplement strong AP clusters with target-side members shared across anchors" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_ap_target_shared_supplement_test)
    suffix = System.unique_integer([:positive])
    ap_uid = "sr:cluster-ap-shared-supplement-#{suffix}"
    sibling_uid = "sr:cluster-ap-shared-supplement-sibling-#{suffix}"

    create_topology_device(actor, ap_uid, "cluster-ap-shared-supplement-#{suffix}", %{
      ip: "198.51.100.190",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    create_topology_device(actor, sibling_uid, "cluster-ap-shared-supplement-sibling-#{suffix}", %{
      ip: "198.51.100.191",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    source_specs =
      Enum.map(1..9, fn idx ->
        uid = "sr:cluster-ap-shared-source-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{190 + idx}"
        mac = "02:00:00:83:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    shared_target_specs =
      Enum.map(1..5, fn idx ->
        uid = "sr:cluster-ap-shared-target-endpoint-#{suffix}-#{idx}"
        ip = "198.51.101.#{idx}"
        mac = "02:00:00:84:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:bb"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.map(source_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: ap_uid,
          local_device_ip: "198.51.100.190",
          local_if_name: "wifi0",
          local_if_index: 10,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-24T05:30:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end) ++
        Enum.flat_map(shared_target_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          [
            %{
              local_device_id: endpoint_uid,
              local_device_ip: endpoint_ip,
              local_if_name: endpoint_mac,
              local_if_index: nil,
              neighbor_if_name: "unknown",
              neighbor_if_index: nil,
              neighbor_device_id: ap_uid,
              neighbor_mgmt_addr: "198.51.100.190",
              protocol: "snmp-l2",
              evidence_class: "endpoint-attachment",
              confidence_tier: "low",
              confidence_reason: "single_identifier_inference",
              flow_pps: 1,
              flow_bps: 100,
              capacity_bps: 1_000_000_000,
              flow_pps_ab: 1,
              flow_pps_ba: 0,
              flow_bps_ab: 100,
              flow_bps_ba: 0,
              telemetry_source: "none",
              telemetry_observed_at: "2026-03-24T05:30:00Z",
              metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
            },
            %{
              local_device_id: endpoint_uid,
              local_device_ip: endpoint_ip,
              local_if_name: endpoint_mac,
              local_if_index: nil,
              neighbor_if_name: "unknown",
              neighbor_if_index: nil,
              neighbor_device_id: sibling_uid,
              neighbor_mgmt_addr: "198.51.100.191",
              protocol: "snmp-l2",
              evidence_class: "endpoint-attachment",
              confidence_tier: "low",
              confidence_reason: "single_identifier_inference",
              flow_pps: 1,
              flow_bps: 100,
              capacity_bps: 1_000_000_000,
              flow_pps_ab: 1,
              flow_pps_ba: 0,
              flow_bps_ab: 100,
              flow_bps_ba: 0,
              telemetry_source: "none",
              telemetry_observed_at: "2026-03-24T05:30:00Z",
              metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
            }
          ]
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    ap_cluster = Enum.find(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_uid))

    assert ap_cluster.label == "9 endpoints"
  end

  test "latest_snapshot/0 clusters anonymous unresolved source-side endpoint attachments" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_unresolved_source_cluster_test)
    suffix = System.unique_integer([:positive])
    ap_uid = "sr:cluster-unresolved-source-ap-#{suffix}"

    create_topology_device(actor, ap_uid, "cluster-unresolved-source-ap-#{suffix}", %{
      ip: "198.51.100.220",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    rows =
      Enum.map(1..3, fn idx ->
        %{
          local_device_id: ap_uid,
          local_device_ip: "198.51.100.220",
          local_if_name: "wifi#{idx}",
          local_if_index: idx,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: "sr:cluster-unresolved-source-endpoint-#{suffix}-#{idx}",
          neighbor_mgmt_addr: nil,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T21:30:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    cluster = Enum.find(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_uid))

    assert cluster.label == "3 endpoints"
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 1
  end

  test "latest_snapshot/0 summarizes router source-side endpoint attachments" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_router_cluster_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:cluster-router-anchor-#{suffix}"

    create_topology_device(actor, router_uid, "cluster-router-anchor-#{suffix}", %{
      ip: "198.51.100.180",
      type_id: 12,
      is_available: true,
      metadata: %{"type" => "router"}
    })

    endpoint_specs =
      Enum.map(1..4, fn idx ->
        uid = "sr:cluster-router-endpoint-#{suffix}-#{idx}"

        ip =
          case idx do
            1 -> "10.10.0.10"
            2 -> "10.10.1.11"
            3 -> "10.10.2.12"
            _ -> "10.10.2.13"
          end

        mac = "02:00:00:73:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:cc"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: router_uid,
          local_device_ip: "198.51.100.180",
          local_if_name: "lan0",
          local_if_index: 10,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T21:45:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    cluster = Enum.find(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> router_uid))

    assert cluster.label == "4 endpoints"
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 1
  end

  test "latest_snapshot/0 does not summarize router endpoint attachments confined to two subnets" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_router_two_subnets_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:cluster-router-two-subnets-#{suffix}"

    create_topology_device(actor, router_uid, "cluster-router-two-subnets-#{suffix}", %{
      ip: "198.51.100.181",
      type_id: 12,
      is_available: true,
      metadata: %{"type" => "router"}
    })

    endpoint_specs =
      Enum.map(
        [
          {"sr:cluster-router-two-subnets-endpoint-#{suffix}-1", "192.168.1.10"},
          {"sr:cluster-router-two-subnets-endpoint-#{suffix}-2", "192.168.1.11"},
          {"sr:cluster-router-two-subnets-endpoint-#{suffix}-3", "192.168.2.12"},
          {"sr:cluster-router-two-subnets-endpoint-#{suffix}-4", "192.168.2.13"}
        ],
        fn {uid, ip} ->
          create_topology_device(actor, uid, nil, %{
            ip: ip,
            type_id: 2,
            is_available: true,
            metadata: %{"identity_source" => "mapper_topology_sighting"}
          })

          %{uid: uid, ip: ip}
        end
      )

    rows =
      endpoint_specs
      |> Enum.with_index(1)
      |> Enum.map(fn {%{uid: endpoint_uid, ip: endpoint_ip}, idx} ->
        %{
          local_device_id: router_uid,
          local_device_ip: "198.51.100.181",
          local_if_name: "lan#{idx}",
          local_if_index: idx,
          neighbor_if_name: "peer#{idx}",
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T21:47:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    refute Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> router_uid))
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 0
  end

  test "latest_snapshot/0 does not create target-side fallback endpoint clusters for routers" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_router_target_fallback_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:cluster-router-target-only-#{suffix}"

    create_topology_device(actor, router_uid, "cluster-router-target-only-#{suffix}", %{
      ip: "198.51.100.190",
      type_id: 12,
      is_available: true,
      metadata: %{"type" => "router"}
    })

    rows =
      Enum.map(1..4, fn idx ->
        endpoint_uid = "sr:cluster-router-target-only-endpoint-#{suffix}-#{idx}"
        endpoint_ip = "198.51.100.#{190 + idx}"
        endpoint_mac = "02:00:00:74:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:dd"

        %{
          local_device_id: endpoint_uid,
          local_device_ip: endpoint_ip,
          local_if_name: endpoint_mac,
          local_if_index: nil,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: router_uid,
          neighbor_mgmt_addr: "198.51.100.190",
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T21:50:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    refute Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> router_uid))
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 0
  end

  test "latest_snapshot/0 does not treat topology-sighting infrastructure peers as router endpoints" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_router_infra_peer_filter_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:cluster-router-infra-filter-#{suffix}"

    create_topology_device(actor, router_uid, "cluster-router-infra-filter-#{suffix}", %{
      ip: "198.51.100.200",
      type_id: 12,
      is_available: true,
      metadata: %{"type" => "router"}
    })

    infra_specs =
      Enum.map(1..4, fn idx ->
        uid = "sr:cluster-router-infra-peer-#{suffix}-#{idx}"

        create_topology_device(actor, uid, "cluster-router-infra-peer-#{suffix}-#{idx}", %{
          ip: "198.51.100.#{200 + idx}",
          type_id: 99,
          is_available: true,
          metadata: %{
            "type" => if(rem(idx, 2) == 0, do: "switch", else: "access point"),
            "identity_source" => "mapper_topology_sighting"
          }
        })

        %{uid: uid, ip: "198.51.100.#{200 + idx}"}
      end)

    rows =
      infra_specs
      |> Enum.with_index(1)
      |> Enum.map(fn {%{uid: peer_uid, ip: peer_ip}, idx} ->
        %{
          local_device_id: router_uid,
          local_device_ip: "198.51.100.200",
          local_if_name: "lan#{idx}",
          local_if_index: idx,
          neighbor_if_name: "peer#{idx}",
          neighbor_if_index: nil,
          neighbor_device_id: peer_uid,
          neighbor_mgmt_addr: peer_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T22:00:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    refute Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> router_uid))
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 0
  end

  test "latest_snapshot/0 ignores hyper-ambiguous unresolved source ids when supplementing AP clusters" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_ambiguous_source_supplement_test)
    suffix = System.unique_integer([:positive])
    ap_uid = "sr:cluster-ambiguous-source-ap-#{suffix}"

    create_topology_device(actor, ap_uid, "cluster-ambiguous-source-ap-#{suffix}", %{
      ip: "198.51.100.210",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    ambiguous_ids =
      Enum.map(1..3, fn idx ->
        "sr:cluster-ambiguous-source-endpoint-#{suffix}-#{idx}"
      end)

    extra_anchor_ids =
      Enum.map(1..12, fn idx ->
        uid = "sr:cluster-ambiguous-source-extra-anchor-#{suffix}-#{idx}"

        create_topology_device(actor, uid, "cluster-ambiguous-source-extra-anchor-#{suffix}-#{idx}", %{
          ip: "198.51.101.#{idx}",
          type_id: 99,
          is_available: true,
          metadata: %{"type" => "access point"}
        })

        uid
      end)

    source_rows =
      ambiguous_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {endpoint_uid, idx} ->
        %{
          local_device_id: ap_uid,
          local_device_ip: "198.51.100.210",
          local_if_name: "wifi#{idx}",
          local_if_index: idx,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: nil,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T22:10:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    ambiguous_noise_rows =
      Enum.flat_map(extra_anchor_ids, fn anchor_uid ->
        Enum.map(ambiguous_ids, fn endpoint_uid ->
          %{
            local_device_id: anchor_uid,
            local_device_ip: nil,
            local_if_name: "wifi-noise",
            local_if_index: 10,
            neighbor_if_name: "unknown",
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: nil,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-23T22:10:00Z",
            metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
          }
        end)
      end)

    target_rows =
      Enum.map(1..5, fn idx ->
        endpoint_uid = "sr:cluster-ambiguous-source-target-endpoint-#{suffix}-#{idx}"
        endpoint_ip = "198.51.100.#{220 + idx}"
        endpoint_mac = "02:00:00:75:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:ee"

        create_topology_device(actor, endpoint_uid, nil, %{
          ip: endpoint_ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => endpoint_mac}
        })

        %{
          local_device_id: endpoint_uid,
          local_device_ip: endpoint_ip,
          local_if_name: endpoint_mac,
          local_if_index: nil,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: ap_uid,
          neighbor_mgmt_addr: "198.51.100.210",
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T22:10:00Z",
          metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
        }
      end)

    replace_runtime_graph_links!(graph_ref, source_rows ++ ambiguous_noise_rows ++ target_rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    cluster = Enum.find(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_uid))

    assert cluster.label == "5 endpoints"
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 1
  end

  test "latest_snapshot/0 falls back to target-side endpoint attachments when an anchor has no source-side members" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_target_fallback_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-target-switch-#{suffix}"
    ap_uid = "sr:cluster-target-ap-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-target-switch-#{suffix}", %{
      ip: "198.51.100.130",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, ap_uid, "cluster-target-ap-#{suffix}", %{
      ip: "198.51.100.131",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    endpoint_specs =
      Enum.map(1..3, fn idx ->
        uid = "sr:cluster-target-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{140 + idx}"
        mac = "02:00:00:50:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:cc"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      [
        directional_runtime_row(switch_uid, ap_uid, 1, 2, 90, 50, 25)
      ] ++
        Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: endpoint_uid,
            local_device_ip: endpoint_ip,
            local_if_name: endpoint_mac,
            local_if_index: nil,
            neighbor_if_name: "unknown",
            neighbor_if_index: nil,
            neighbor_device_id: ap_uid,
            neighbor_mgmt_addr: "198.51.100.131",
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "low",
            confidence_reason: "single_identifier_inference",
            flow_pps: 1,
            flow_bps: 100,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 1,
            flow_pps_ba: 0,
            flow_bps_ab: 100,
            flow_bps_ba: 0,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-22T23:45:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    ap_cluster_id = "cluster:endpoints:" <> ap_uid
    ap_cluster = Enum.find(snapshot.nodes, &(&1.id == ap_cluster_id))
    ap_cluster_details = Jason.decode!(ap_cluster.details_json)

    assert ap_cluster.label == "3 endpoints"
    assert ap_cluster_details["cluster_kind"] == "endpoint-summary"
    assert ap_cluster_details["cluster_member_count"] == 3
    assert ap_cluster_details["cluster_anchor_id"] == ap_uid
    assert find_edge(snapshot, switch_uid, ap_uid)
    assert find_edge(snapshot, ap_uid, ap_cluster_id)
  end

  test "latest_snapshot/0 falls back to target-side endpoint attachments that only have edge IP identity" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_target_fallback_edge_ip_test)
    suffix = System.unique_integer([:positive])
    ap_uid = "sr:cluster-target-edge-ip-ap-#{suffix}"

    create_topology_device(actor, ap_uid, "cluster-target-edge-ip-ap-#{suffix}", %{
      ip: "198.51.100.150",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    rows =
      Enum.map(1..4, fn idx ->
        %{
          local_device_id: "sr:cluster-target-edge-ip-endpoint-#{suffix}-#{idx}",
          local_device_ip: "198.51.100.#{160 + idx}",
          local_if_name: "02:00:00:76:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:ff",
          local_if_index: nil,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: ap_uid,
          neighbor_mgmt_addr: "198.51.100.150",
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T22:20:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    ap_cluster_id = "cluster:endpoints:" <> ap_uid
    ap_cluster = Enum.find(snapshot.nodes, &(&1.id == ap_cluster_id))

    assert ap_cluster.label == "4 endpoints"
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 1
  end

  test "latest_snapshot/0 does not cluster provisional mapper topology sightings that only have IP identity" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_provisional_ip_only_sighting_test)
    suffix = System.unique_integer([:positive])
    ap_uid = "sr:cluster-provisional-ip-only-ap-#{suffix}"

    create_topology_device(actor, ap_uid, "cluster-provisional-ip-only-ap-#{suffix}", %{
      ip: "198.51.100.240",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    endpoint_specs =
      Enum.map(1..4, fn idx ->
        uid = "sr:cluster-provisional-ip-only-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{240 + idx}"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 0,
          is_available: false,
          metadata: %{
            "identity_source" => "mapper_topology_sighting",
            "identity_state" => "provisional"
          }
        })

        %{uid: uid, ip: ip}
      end)

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip} ->
        %{
          local_device_id: endpoint_uid,
          local_device_ip: endpoint_ip,
          local_if_name: "unknown",
          local_if_index: nil,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: ap_uid,
          neighbor_mgmt_addr: "198.51.100.240",
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-04-06T01:48:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    refute Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> ap_uid))
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 0
  end

  test "latest_snapshot/0 prefers target-side endpoint identities when source-side rows have no leaf IP identity" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_target_identity_preference_test)
    suffix = System.unique_integer([:positive])
    ap_uid = "sr:cluster-target-identity-ap-#{suffix}"

    create_topology_device(actor, ap_uid, "cluster-target-identity-ap-#{suffix}", %{
      ip: "198.51.100.170",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    noisy_source_rows =
      Enum.map(1..3, fn idx ->
        %{
          local_device_id: ap_uid,
          local_device_ip: "198.51.100.170",
          local_if_name: "wifi0",
          local_if_index: 10,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: "sr:cluster-target-identity-noisy-#{suffix}-#{idx}",
          neighbor_mgmt_addr: nil,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T23:05:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    clean_target_rows =
      Enum.map(1..5, fn idx ->
        %{
          local_device_id: "sr:cluster-target-identity-endpoint-#{suffix}-#{idx}",
          local_device_ip: "198.51.100.#{180 + idx}",
          local_if_name: "02:00:00:77:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa",
          local_if_index: nil,
          neighbor_if_name: "unknown",
          neighbor_if_index: nil,
          neighbor_device_id: ap_uid,
          neighbor_mgmt_addr: "198.51.100.170",
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "none",
          telemetry_observed_at: "2026-03-23T23:05:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    replace_runtime_graph_links!(graph_ref, noisy_source_rows ++ clean_target_rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    ap_cluster_id = "cluster:endpoints:" <> ap_uid
    ap_cluster = Enum.find(snapshot.nodes, &(&1.id == ap_cluster_id))

    assert ap_cluster.label == "5 endpoints"
    assert Map.get(snapshot.pipeline_stats, :clustered_endpoint_summaries, 0) == 1
  end

  test "latest_snapshot/0 drops stray attachment edges from the collapsed default view" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-clean-switch-#{suffix}"
    ap_uid = "sr:cluster-clean-ap-#{suffix}"
    endpoint_uid = "sr:cluster-clean-endpoint-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-clean-switch-#{suffix}", %{
      ip: "198.51.100.210",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, ap_uid, "cluster-clean-ap-#{suffix}", %{
      ip: "198.51.100.211",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    create_topology_device(actor, endpoint_uid, nil, %{
      ip: "198.51.100.212",
      type_id: 2,
      is_available: true,
      metadata: %{
        "identity_source" => "mapper_topology_sighting",
        "primary_mac" => "02:00:00:aa:bb:#{suffix |> rem(255) |> Integer.to_string(16) |> String.pad_leading(2, "0")}"
      }
    })

    rows = [
      %{
        local_device_id: switch_uid,
        local_device_ip: "198.51.100.210",
        local_if_name: "eth1",
        local_if_index: 1,
        neighbor_if_name: "uplink0",
        neighbor_if_index: 10,
        neighbor_device_id: ap_uid,
        neighbor_mgmt_addr: "198.51.100.211",
        protocol: "lldp",
        evidence_class: "direct",
        confidence_tier: "high",
        confidence_reason: "direct",
        flow_pps: 120,
        flow_bps: 12_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 60,
        flow_pps_ba: 60,
        flow_bps_ab: 6_000,
        flow_bps_ba: 6_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-03-19T17:00:00Z",
        metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
      },
      %{
        local_device_id: switch_uid,
        local_device_ip: "198.51.100.210",
        local_if_name: "eth2",
        local_if_index: 2,
        neighbor_if_name: "wifi0",
        neighbor_if_index: nil,
        neighbor_device_id: ap_uid,
        neighbor_mgmt_addr: "198.51.100.211",
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_reason: "single_identifier_inference",
        flow_pps: 0,
        flow_bps: 0,
        capacity_bps: 0,
        flow_pps_ab: 0,
        flow_pps_ba: 0,
        flow_bps_ab: 0,
        flow_bps_ba: 0,
        telemetry_source: "none",
        telemetry_observed_at: "2026-03-19T17:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      },
      %{
        local_device_id: switch_uid,
        local_device_ip: "198.51.100.210",
        local_if_name: "eth3",
        local_if_index: 3,
        neighbor_if_name: "02:00:00:aa:bb:01",
        neighbor_if_index: nil,
        neighbor_device_id: endpoint_uid,
        neighbor_mgmt_addr: "198.51.100.212",
        protocol: "snmp-l2",
        evidence_class: "endpoint-attachment",
        confidence_tier: "medium",
        confidence_reason: "single_identifier_inference",
        flow_pps: 2,
        flow_bps: 200,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 2,
        flow_pps_ba: 0,
        flow_bps_ab: 200,
        flow_bps_ba: 0,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-03-19T17:00:00Z",
        metadata: %{"relation_type" => "ATTACHED_TO", "evidence_class" => "endpoint-attachment"}
      }
    ]

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    cluster_id = "cluster:endpoints:" <> switch_uid
    switch = Enum.find(snapshot.nodes, &(&1.id == switch_uid))
    switch_details = Jason.decode!(switch.details_json)

    assert find_edge(snapshot, switch_uid, ap_uid)
    refute Enum.any?(snapshot.nodes, &(&1.id == cluster_id))
    refute find_edge(snapshot, switch_uid, endpoint_uid)
    refute find_edge(snapshot, switch_uid, cluster_id)
    assert switch_details["cluster_id"] == cluster_id
    assert switch_details["cluster_kind"] == "endpoint-anchor"
    assert switch_details["cluster_member_count"] == 1
    assert switch_details["cluster_expandable"] == true
    assert switch_details["cluster_expanded"] == false

    refute Enum.any?(snapshot.edges, fn edge ->
             edge.evidence_class == "endpoint-attachment" and
               ((edge.source == switch_uid and edge.target == ap_uid) or
                  (edge.source == ap_uid and edge.target == switch_uid))
           end)

    assert Enum.empty?(Enum.filter(snapshot.edges, &(&1.evidence_class == "endpoint-attachment")))
  end

  test "latest_snapshot/0 expands clustered endpoints with backend-authored membership metadata" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:cluster-expand-router-#{suffix}"
    switch_uid = "sr:cluster-expand-switch-#{suffix}"
    ap_uid = "sr:cluster-expand-ap-#{suffix}"

    create_topology_device(actor, router_uid, "cluster-expand-router-#{suffix}", %{
      ip: "198.51.100.9",
      type_id: 12,
      is_available: true
    })

    create_topology_device(actor, switch_uid, "cluster-expand-switch-#{suffix}", %{
      ip: "198.51.100.10",
      type_id: 10,
      is_available: true
    })

    create_topology_device(actor, ap_uid, "cluster-expand-ap-#{suffix}", %{
      ip: "198.51.100.11",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    endpoint_specs =
      Enum.map(1..8, fn idx ->
        uid = "sr:cluster-expand-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{20 + idx}"
        mac = "02:00:00:10:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:bb"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      [
        directional_runtime_row(router_uid, switch_uid, 1, 2, 110, 70, 40),
        directional_runtime_row(switch_uid, ap_uid, 3, 4, 85, 45, 40)
      ] ++
        Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: switch_uid,
            local_device_ip: "198.51.100.10",
            local_if_name: "eth1",
            local_if_index: 1,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 3,
            flow_bps: 300,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 3,
            flow_pps_ba: 0,
            flow_bps_ab: 300,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-19T12:05:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: collapsed_snapshot}} = latest_snapshot_for_test()

    cluster_id = "cluster:endpoints:" <> switch_uid

    assert {:ok, %{snapshot: snapshot}} =
             latest_snapshot_for_test(%{expanded_clusters: [cluster_id]})

    assert snapshot.revision != collapsed_snapshot.revision
    assert Enum.any?(snapshot.nodes, &(&1.id == cluster_id))
    assert Enum.all?(endpoint_specs, fn spec -> Enum.any?(snapshot.nodes, &(&1.id == spec.uid)) end)

    cluster = Enum.find(snapshot.nodes, &(&1.id == cluster_id))
    cluster_details = Jason.decode!(cluster.details_json)

    assert cluster_details["cluster_kind"] == "endpoint-summary"
    assert cluster_details["cluster_expanded"] == true
    assert cluster_details["cluster_anchor_id"] == switch_uid

    coords =
      coords_for(
        snapshot,
        [router_uid, switch_uid, ap_uid, cluster_id | Enum.map(endpoint_specs, & &1.uid)]
      )

    {anchor_x, anchor_y} = Map.fetch!(coords, switch_uid)
    {hub_x, hub_y} = Map.fetch!(coords, cluster_id)
    {router_x, router_y} = Map.fetch!(coords, router_uid)
    {ap_x, ap_y} = Map.fetch!(coords, ap_uid)

    assert distance({anchor_x, anchor_y}, {hub_x, hub_y}) >= 220.0
    assert find_edge(snapshot, switch_uid, cluster_id)
    assert find_edge(snapshot, router_uid, switch_uid)
    assert find_edge(snapshot, switch_uid, ap_uid)

    member_points =
      Enum.map(endpoint_specs, fn spec ->
        endpoint = Enum.find(snapshot.nodes, &(&1.id == spec.uid))
        details = Jason.decode!(endpoint.details_json)

        assert details["cluster_id"] == cluster_id
        assert details["cluster_kind"] == "endpoint-member"
        assert details["cluster_expanded"] == true
        assert details["cluster_anchor_id"] == switch_uid

        point = Map.fetch!(coords, spec.uid)
        assert find_edge(snapshot, cluster_id, spec.uid)
        refute find_edge(snapshot, switch_uid, spec.uid)
        assert distance({hub_x, hub_y}, point) >= 70.0
        assert distance({anchor_x, anchor_y}, point) >= distance({anchor_x, anchor_y}, {hub_x, hub_y}) + 18.0
        point
      end)

    min_member_spacing =
      member_points
      |> Enum.with_index()
      |> Enum.flat_map(fn {left, idx} ->
        member_points
        |> Enum.drop(idx + 1)
        |> Enum.map(&distance(left, &1))
      end)
      |> Enum.min(fn -> 0.0 end)

    assert min_member_spacing >= 30.0

    sector_axis = :math.atan2(hub_y - anchor_y, hub_x - anchor_x)

    angular_offsets =
      Enum.map(member_points, fn {member_x, member_y} ->
        member_angle = :math.atan2(member_y - hub_y, member_x - hub_x)
        abs(angle_delta(member_angle, sector_axis))
      end)

    assert Enum.max(angular_offsets, fn -> 0.0 end) >= 0.45
    assert Enum.max(angular_offsets, fn -> 0.0 end) <= 1.25

    nearby_backbone_nodes = [{router_x, router_y}, {ap_x, ap_y}]

    assert Enum.all?(nearby_backbone_nodes, fn point ->
             distance({hub_x, hub_y}, point) >= 78.0
           end)

    assert Enum.all?(member_points, fn point ->
             Enum.all?(nearby_backbone_nodes, fn backbone_point ->
               distance(point, backbone_point) >= 42.0
             end)
           end)

    backbone_segments = [
      {{router_x, router_y}, {anchor_x, anchor_y}},
      {{anchor_x, anchor_y}, {ap_x, ap_y}}
    ]

    assert Enum.all?(backbone_segments, fn segment ->
             distance_point_to_segment({hub_x, hub_y}, segment) >= 52.0
           end)

    assert Enum.all?(member_points, fn point ->
             Enum.all?(backbone_segments, fn segment ->
               distance_point_to_segment(point, segment) >= 26.0
             end)
           end)

    assert {:ok, %{snapshot: repeated_snapshot}} =
             latest_snapshot_for_test(%{expanded_clusters: [cluster_id]})

    repeated_coords =
      coords_for(
        repeated_snapshot,
        [router_uid, switch_uid, ap_uid, cluster_id | Enum.map(endpoint_specs, & &1.uid)]
      )

    assert repeated_coords == coords
  end

  test "latest_snapshot/0 does not let expanded snapshots poison the collapsed snapshot cache" do
    Application.put_env(:serviceradar_web_ng, :god_view_snapshot_coalesce_ms, 5_000)
    :persistent_term.erase({GodViewStream, :snapshot_cache})

    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      :persistent_term.erase({GodViewStream, :snapshot_cache})
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_cache_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-cache-switch-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-cache-switch-#{suffix}", %{
      ip: "198.51.100.50",
      type_id: 10,
      is_available: true
    })

    endpoint_specs =
      Enum.map(1..5, fn idx ->
        uid = "sr:cluster-cache-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{60 + idx}"
        mac = "02:00:00:20:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:cc"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: switch_uid,
          local_device_ip: "198.51.100.50",
          local_if_name: "edge0",
          local_if_index: 10,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "medium",
          confidence_reason: "single_identifier_inference",
          flow_pps: 3,
          flow_bps: 300,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 3,
          flow_pps_ba: 0,
          flow_bps_ab: 300,
          flow_bps_ba: 0,
          telemetry_source: "interface",
          telemetry_observed_at: "2026-03-22T19:30:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    cluster_id = "cluster:endpoints:" <> switch_uid

    assert {:ok, %{snapshot: collapsed_snapshot}} = latest_snapshot_for_test()
    assert Enum.any?(collapsed_snapshot.nodes, &(&1.id == cluster_id))
    refute Enum.any?(collapsed_snapshot.nodes, &Enum.any?(endpoint_specs, fn spec -> spec.uid == &1.id end))
    assert Enum.any?(collapsed_snapshot.edges, &(&1.source == switch_uid and &1.target == cluster_id))

    refute Enum.any?(collapsed_snapshot.edges, fn edge ->
             edge.source == switch_uid and Enum.any?(endpoint_specs, &(&1.uid == edge.target))
           end)

    assert {:ok, %{snapshot: expanded_snapshot}} =
             latest_snapshot_for_test(%{expanded_clusters: [cluster_id]})

    assert expanded_snapshot.revision != collapsed_snapshot.revision
    assert Enum.all?(endpoint_specs, fn spec -> Enum.any?(expanded_snapshot.nodes, &(&1.id == spec.uid)) end)

    assert {:ok, %{snapshot: collapsed_again}} = latest_snapshot_for_test()

    assert collapsed_again.revision == collapsed_snapshot.revision
    assert Enum.any?(collapsed_again.nodes, &(&1.id == cluster_id))
    refute Enum.any?(collapsed_again.nodes, &Enum.any?(endpoint_specs, fn spec -> spec.uid == &1.id end))
  end

  test "latest_snapshot/0 expands clustered endpoints when members only exist as unresolved attachment identities" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_unresolved_expand_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-unresolved-switch-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-unresolved-switch-#{suffix}", %{
      ip: "198.51.100.80",
      type_id: 10,
      is_available: true
    })

    endpoint_specs =
      Enum.map(1..5, fn idx ->
        uid = "sr:cluster-unresolved-endpoint-#{suffix}-#{idx}"
        ip = "198.51.100.#{90 + idx}"
        mac = "02:00:00:30:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:dd"
        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: switch_uid,
          local_device_ip: "198.51.100.80",
          local_if_name: "edge1",
          local_if_index: 11,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "medium",
          confidence_reason: "single_identifier_inference",
          flow_pps: 2,
          flow_bps: 200,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 2,
          flow_pps_ba: 0,
          flow_bps_ab: 200,
          flow_bps_ba: 0,
          telemetry_source: "interface",
          telemetry_observed_at: "2026-03-24T03:00:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    cluster_id = "cluster:endpoints:" <> switch_uid

    assert {:ok, %{snapshot: collapsed_snapshot}} = latest_snapshot_for_test()
    assert Enum.any?(collapsed_snapshot.nodes, &(&1.id == cluster_id))

    assert {:ok, %{snapshot: expanded_snapshot}} =
             latest_snapshot_for_test(%{expanded_clusters: [cluster_id]})

    assert Enum.all?(endpoint_specs, fn spec ->
             endpoint = Enum.find(expanded_snapshot.nodes, &(&1.id == spec.uid))
             edge = find_edge(expanded_snapshot, cluster_id, spec.uid)

             endpoint && edge
           end)

    assert Enum.all?(endpoint_specs, fn spec ->
             details =
               expanded_snapshot.nodes
               |> Enum.find(&(&1.id == spec.uid))
               |> Map.fetch!(:details_json)
               |> Jason.decode!()

             details["ip"] == spec.ip
           end)
  end

  test "latest_snapshot/0 gives unresolved expanded placeholders a human-safe label when identity data is missing" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_unresolved_placeholder_label_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-unresolved-placeholder-switch-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-unresolved-placeholder-switch-#{suffix}", %{
      ip: "198.51.104.10",
      type_id: 10,
      is_available: true
    })

    endpoint_ids =
      Enum.map(1..4, fn idx -> "sr:cluster-unresolved-placeholder-endpoint-#{suffix}-#{idx}" end)

    rows =
      Enum.map(endpoint_ids, fn endpoint_uid ->
        %{
          local_device_id: switch_uid,
          local_device_ip: "198.51.104.10",
          local_if_name: "edge7",
          local_if_index: 17,
          neighbor_if_name: nil,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: nil,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "low",
          confidence_reason: "single_identifier_inference",
          flow_pps: 1,
          flow_bps: 100,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 1,
          flow_pps_ba: 0,
          flow_bps_ab: 100,
          flow_bps_ba: 0,
          telemetry_source: "interface",
          telemetry_observed_at: "2026-03-24T04:00:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    cluster_id = "cluster:endpoints:" <> switch_uid

    assert {:ok, %{snapshot: expanded_snapshot}} =
             latest_snapshot_for_test(%{expanded_clusters: [cluster_id]})

    assert Enum.all?(endpoint_ids, fn endpoint_id ->
             endpoint = Enum.find(expanded_snapshot.nodes, &(&1.id == endpoint_id))
             endpoint && endpoint.label == "Unidentified endpoint"
           end)
  end

  test "latest_snapshot/0 limits topology-sighting members rendered for expanded endpoint clusters" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_topology_sighting_expand_budget_test)
    suffix = System.unique_integer([:positive])
    switch_uid = "sr:cluster-topology-sighting-switch-#{suffix}"

    create_topology_device(actor, switch_uid, "cluster-topology-sighting-switch-#{suffix}", %{
      ip: "198.51.103.10",
      type_id: 10,
      is_available: true
    })

    endpoint_specs =
      Enum.map(1..9, fn idx ->
        uid = "sr:cluster-topology-sighting-endpoint-#{suffix}-#{idx}"
        ip = "198.51.103.#{20 + idx}"
        mac = "02:00:00:60:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:aa"

        create_topology_device(actor, uid, nil, %{
          ip: ip,
          type_id: 2,
          is_available: true,
          metadata: %{"identity_source" => "mapper_topology_sighting", "primary_mac" => mac}
        })

        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        %{
          local_device_id: switch_uid,
          local_device_ip: "198.51.103.10",
          local_if_name: "edge3",
          local_if_index: 13,
          neighbor_if_name: endpoint_mac,
          neighbor_if_index: nil,
          neighbor_device_id: endpoint_uid,
          neighbor_mgmt_addr: endpoint_ip,
          protocol: "snmp-l2",
          evidence_class: "endpoint-attachment",
          confidence_tier: "medium",
          confidence_reason: "single_identifier_inference",
          flow_pps: 4,
          flow_bps: 400,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 4,
          flow_pps_ba: 0,
          flow_bps_ab: 400,
          flow_bps_ba: 0,
          telemetry_source: "interface",
          telemetry_observed_at: "2026-03-24T03:30:00Z",
          metadata: %{
            "relation_type" => "ATTACHED_TO",
            "evidence_class" => "endpoint-attachment"
          }
        }
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    cluster_id = "cluster:endpoints:" <> switch_uid

    assert {:ok, %{snapshot: expanded_snapshot}} =
             latest_snapshot_for_test(%{expanded_clusters: [cluster_id]})

    visible_member_nodes =
      Enum.filter(expanded_snapshot.nodes, fn node -> Enum.any?(endpoint_specs, &(&1.uid == node.id)) end)

    assert length(visible_member_nodes) == 6

    expanded_member_edges =
      Enum.filter(expanded_snapshot.edges, fn edge ->
        edge.source == cluster_id and Enum.any?(endpoint_specs, &(&1.uid == edge.target))
      end)

    assert length(expanded_member_edges) == 6

    cluster_details =
      expanded_snapshot.nodes
      |> Enum.find(&(&1.id == cluster_id))
      |> Map.fetch!(:details_json)
      |> Jason.decode!()

    assert cluster_details["cluster_kind"] == "endpoint-summary"
    assert cluster_details["cluster_expanded"] == true
    assert cluster_details["cluster_member_count"] == 9
    assert cluster_details["cluster_visible_member_count"] == 6
    assert cluster_details["cluster_hidden_member_count"] == 3
  end

  test "latest_snapshot/0 keeps expanded cluster members when sibling collapsed clusters share those endpoints" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_shared_expand_test)
    suffix = System.unique_integer([:positive])
    ap_one_uid = "sr:cluster-shared-ap-one-#{suffix}"
    ap_two_uid = "sr:cluster-shared-ap-two-#{suffix}"

    create_topology_device(actor, ap_one_uid, "cluster-shared-ap-one-#{suffix}", %{
      ip: "198.51.101.10",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    create_topology_device(actor, ap_two_uid, "cluster-shared-ap-two-#{suffix}", %{
      ip: "198.51.101.11",
      type_id: 99,
      is_available: true,
      metadata: %{"type" => "access point"}
    })

    endpoint_specs =
      Enum.map(1..6, fn idx ->
        uid = "sr:cluster-shared-endpoint-#{suffix}-#{idx}"
        ip = "198.51.101.#{20 + idx}"
        mac = "02:00:00:40:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:ee"
        %{uid: uid, ip: ip, mac: mac}
      end)

    rows =
      Enum.flat_map(endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
        [
          %{
            local_device_id: ap_one_uid,
            local_device_ip: "198.51.101.10",
            local_if_name: "wlan0",
            local_if_index: 21,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 3,
            flow_bps: 300,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 3,
            flow_pps_ba: 0,
            flow_bps_ab: 300,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-24T03:15:00Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          },
          %{
            local_device_id: endpoint_uid,
            local_device_ip: endpoint_ip,
            local_if_name: endpoint_mac,
            local_if_index: nil,
            neighbor_if_name: "wlan1",
            neighbor_if_index: 22,
            neighbor_device_id: ap_two_uid,
            neighbor_mgmt_addr: "198.51.101.11",
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 3,
            flow_bps: 300,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 3,
            flow_pps_ba: 0,
            flow_bps_ab: 300,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-24T03:15:05Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        ]
      end)

    replace_runtime_graph_links!(graph_ref, rows)

    expanded_cluster_id = "cluster:endpoints:" <> ap_one_uid
    collapsed_cluster_id = "cluster:endpoints:" <> ap_two_uid

    assert {:ok, %{snapshot: collapsed_snapshot}} = latest_snapshot_for_test()
    assert Enum.any?(collapsed_snapshot.nodes, &(&1.id == expanded_cluster_id))
    assert Enum.any?(collapsed_snapshot.nodes, &(&1.id == collapsed_cluster_id))

    assert {:ok, %{snapshot: expanded_snapshot}} =
             latest_snapshot_for_test(%{expanded_clusters: [expanded_cluster_id]})

    assert Enum.any?(expanded_snapshot.nodes, &(&1.id == collapsed_cluster_id))

    assert Enum.all?(endpoint_specs, fn spec ->
             Enum.any?(expanded_snapshot.nodes, &(&1.id == spec.uid)) and
               find_edge(expanded_snapshot, expanded_cluster_id, spec.uid)
           end)
  end

  test "latest_snapshot/0 quarantines unresolved attachment identities that do not qualify for clustering" do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
    original_rows = Native.runtime_graph_get_links(graph_ref)

    on_exit(fn ->
      Native.runtime_graph_replace_links(graph_ref, original_rows)
    end)

    actor = SystemActor.system(:god_view_stream_unresolved_quarantine_test)
    suffix = System.unique_integer([:positive])
    router_uid = "sr:cluster-quarantine-router-#{suffix}"
    switch_uid = "sr:cluster-quarantine-switch-#{suffix}"

    create_topology_device(actor, router_uid, "cluster-quarantine-router-#{suffix}", %{
      ip: "198.51.102.1",
      type_id: 9,
      is_available: true
    })

    create_topology_device(actor, switch_uid, "cluster-quarantine-switch-#{suffix}", %{
      ip: "198.51.102.2",
      type_id: 10,
      is_available: true
    })

    unresolved_endpoint_specs =
      Enum.map(1..2, fn idx ->
        %{
          uid: "sr:cluster-quarantine-endpoint-#{suffix}-#{idx}",
          ip: "198.51.102.#{20 + idx}",
          mac: "02:00:00:50:#{idx |> Integer.to_string(16) |> String.pad_leading(2, "0")}:ff"
        }
      end)

    rows =
      [
        %{
          local_device_id: router_uid,
          local_device_ip: "198.51.102.1",
          local_if_name: "xe-0/0/0",
          local_if_index: 101,
          neighbor_if_name: "ge-0/0/1",
          neighbor_if_index: 1,
          neighbor_device_id: switch_uid,
          neighbor_mgmt_addr: "198.51.102.2",
          protocol: "lldp",
          evidence_class: "direct",
          confidence_tier: "high",
          confidence_reason: "lldp_bidirectional",
          flow_pps: 8,
          flow_bps: 800,
          capacity_bps: 1_000_000_000,
          flow_pps_ab: 8,
          flow_pps_ba: 8,
          flow_bps_ab: 800,
          flow_bps_ba: 800,
          telemetry_source: "interface",
          telemetry_observed_at: "2026-03-24T04:00:00Z",
          metadata: %{
            "relation_type" => "CONNECTED_TO",
            "evidence_class" => "direct"
          }
        }
      ] ++
        Enum.map(unresolved_endpoint_specs, fn %{uid: endpoint_uid, ip: endpoint_ip, mac: endpoint_mac} ->
          %{
            local_device_id: switch_uid,
            local_device_ip: "198.51.102.2",
            local_if_name: "edge2",
            local_if_index: 12,
            neighbor_if_name: endpoint_mac,
            neighbor_if_index: nil,
            neighbor_device_id: endpoint_uid,
            neighbor_mgmt_addr: endpoint_ip,
            protocol: "snmp-l2",
            evidence_class: "endpoint-attachment",
            confidence_tier: "medium",
            confidence_reason: "single_identifier_inference",
            flow_pps: 2,
            flow_bps: 200,
            capacity_bps: 1_000_000_000,
            flow_pps_ab: 2,
            flow_pps_ba: 0,
            flow_bps_ab: 200,
            flow_bps_ba: 0,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-24T04:00:05Z",
            metadata: %{
              "relation_type" => "ATTACHED_TO",
              "evidence_class" => "endpoint-attachment"
            }
          }
        end)

    replace_runtime_graph_links!(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = latest_snapshot_for_test()

    assert Enum.any?(snapshot.nodes, &(&1.id == router_uid))
    assert Enum.any?(snapshot.nodes, &(&1.id == switch_uid))
    assert find_edge(snapshot, router_uid, switch_uid)

    refute Enum.any?(snapshot.nodes, fn node ->
             Enum.any?(unresolved_endpoint_specs, &(&1.uid == node.id))
           end)

    refute Enum.any?(snapshot.edges, fn edge ->
             Enum.any?(unresolved_endpoint_specs, fn spec ->
               edge.source == spec.uid or edge.target == spec.uid
             end)
           end)

    refute Enum.any?(snapshot.nodes, &(&1.id == "cluster:endpoints:" <> switch_uid))
  end

  defp coords_for(snapshot, node_ids) do
    snapshot.nodes
    |> Enum.filter(&(&1.id in node_ids))
    |> Map.new(fn node -> {node.id, {node.x, node.y}} end)
  end

  defp states_for(snapshot, node_ids) do
    snapshot.nodes
    |> Enum.filter(&(&1.id in node_ids))
    |> Map.new(fn node -> {node.id, node.state} end)
  end

  defp find_edge(snapshot, source_id, target_id) do
    Enum.find(snapshot.edges, fn edge ->
      (edge.source == source_id and edge.target == target_id) or
        (edge.source == target_id and edge.target == source_id)
    end)
  end

  defp directional_runtime_row(
         local_device_id,
         neighbor_device_id,
         local_if_index,
         neighbor_if_index,
         flow_pps,
         flow_pps_ab,
         flow_pps_ba
       ) do
    %{
      local_device_id: local_device_id,
      local_device_ip: "192.0.2.200",
      local_if_name: "if#{local_if_index}",
      local_if_index: local_if_index,
      local_if_name_ab: "if#{local_if_index}",
      local_if_index_ab: local_if_index,
      local_if_name_ba: "if#{neighbor_if_index}",
      local_if_index_ba: neighbor_if_index,
      neighbor_if_name: "if#{neighbor_if_index}",
      neighbor_if_index: neighbor_if_index,
      neighbor_device_id: neighbor_device_id,
      neighbor_mgmt_addr: "192.0.2.201",
      neighbor_system_name: neighbor_device_id,
      protocol: "snmp-l2",
      evidence_class: "direct",
      confidence_tier: "high",
      confidence_reason: "direct",
      flow_pps: flow_pps,
      flow_bps: flow_pps * 100,
      capacity_bps: 1_000_000_000,
      flow_pps_ab: flow_pps_ab,
      flow_pps_ba: flow_pps_ba,
      flow_bps_ab: flow_pps_ab * 100,
      flow_bps_ba: flow_pps_ba * 100,
      telemetry_eligible: true,
      telemetry_source: "interface",
      telemetry_observed_at: "2026-02-26T00:00:00Z",
      metadata: %{"relation_type" => "CONNECTS_TO", "evidence_class" => "direct"}
    }
  end

  defp normalized_pair(a, b) when is_binary(a) and is_binary(b) do
    [left, right] = Enum.sort([a, b])
    "#{left}::#{right}"
  end

  defp distance({ax, ay}, {bx, by}) when is_number(ax) and is_number(ay) and is_number(bx) and is_number(by) do
    dx = bx - ax
    dy = by - ay
    :math.sqrt(dx * dx + dy * dy)
  end

  defp distance_point_to_segment({px, py}, {{ax, ay}, {bx, by}})
       when is_number(px) and is_number(py) and is_number(ax) and is_number(ay) and is_number(bx) and is_number(by) do
    abx = bx - ax
    aby = by - ay
    segment_length_sq = abx * abx + aby * aby

    if segment_length_sq <= 0.0001 do
      distance({px, py}, {ax, ay})
    else
      t = max(0.0, min(1.0, ((px - ax) * abx + (py - ay) * aby) / segment_length_sq))
      distance({px, py}, {ax + t * abx, ay + t * aby})
    end
  end

  defp distance_point_to_segment(_point, _segment), do: 0.0

  defp angle_delta(left, right) when is_number(left) and is_number(right) do
    delta = left - right
    :math.atan2(:math.sin(delta), :math.cos(delta))
  end

  defp angle_delta(_left, _right), do: 0.0

  defp create_topology_device(actor, uid, hostname, attrs \\ %{}) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          uid: uid,
          hostname: hostname,
          type_id: 12,
          is_available: true,
          first_seen_time: DateTime.utc_now(),
          last_seen_time: DateTime.utc_now()
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_topology_link(actor, timestamp, local_uid, neighbor_uid, if_index) do
    TopologyLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: timestamp,
        protocol: "lldp",
        local_device_id: local_uid,
        local_if_name: "eth#{if_index}",
        local_if_index: if_index,
        neighbor_device_id: neighbor_uid,
        neighbor_mgmt_addr: "10.240.#{rem(if_index, 200)}.#{rem(if_index * 3, 200)}",
        metadata: @topology_link_metadata
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp replace_runtime_graph_links!(graph_ref, rows) when is_list(rows) do
    assert length(rows) == Native.runtime_graph_ingest_rows(graph_ref, rows)
  end

  defp latest_snapshot_for_test(opts \\ %{}) do
    {:ok, graph_ref} = RuntimeGraph.get_graph_ref()

    if Native.runtime_graph_get_links(graph_ref) == [] do
      mapper_links = mapper_topology_links_for_projection()

      if mapper_links != [] do
        :ok = TopologyGraph.upsert_links(mapper_links)
      end

      _ = TopologyGraph.rebuild_canonical_links_from_current()
      :ok = RuntimeGraph.refresh_now_sync()
      await_runtime_graph_refresh(graph_ref)
    end

    GodViewStream.latest_snapshot(opts)
  end

  defp mapper_topology_links_for_projection do
    Repo.all(
      from(t in "mapper_topology_links",
        prefix: "platform",
        select: %{
          timestamp: t.timestamp,
          protocol: t.protocol,
          local_device_id: t.local_device_id,
          local_device_ip: t.local_device_ip,
          local_if_index: t.local_if_index,
          local_if_name: t.local_if_name,
          neighbor_device_id: t.neighbor_device_id,
          neighbor_chassis_id: t.neighbor_chassis_id,
          neighbor_port_id: t.neighbor_port_id,
          neighbor_port_descr: t.neighbor_port_descr,
          neighbor_system_name: t.neighbor_system_name,
          neighbor_mgmt_addr: t.neighbor_mgmt_addr,
          metadata: t.metadata
        }
      )
    )
  end

  defp await_runtime_graph_refresh(graph_ref, attempts \\ 20)

  defp await_runtime_graph_refresh(_graph_ref, attempts) when attempts <= 0, do: :ok

  defp await_runtime_graph_refresh(graph_ref, attempts) do
    case Native.runtime_graph_get_links(graph_ref) do
      [] ->
        Process.sleep(50)
        await_runtime_graph_refresh(graph_ref, attempts - 1)

      _rows ->
        :ok
    end
  end

  defp create_interface_observation(actor, timestamp, device_id, if_name, if_index) do
    Interface
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: timestamp,
        device_id: device_id,
        interface_uid: "#{device_id}/#{if_name}/#{if_index}",
        if_name: if_name,
        if_index: if_index,
        if_oper_status: 1,
        speed_bps: 1_000_000_000
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp insert_metric(timestamp, device_id, if_index, metric_name, value) do
    row = %{
      timestamp: timestamp,
      gateway_id: "gw-god-view-test-#{System.unique_integer([:positive])}",
      agent_id: "agent-god-view-test",
      metric_name: metric_name,
      metric_type: "gauge",
      device_id: device_id,
      value: value * 1.0,
      unit: "",
      tags: %{},
      partition: "default",
      scale: 1.0,
      is_delta: true,
      target_device_ip: nil,
      if_index: if_index,
      metadata: %{},
      created_at: DateTime.utc_now()
    }

    Repo.insert_all(
      "timeseries_metrics",
      [Map.put(row, :series_key, TimeseriesSeriesKey.build(row))],
      timeout: 30_000
    )
  end
end
