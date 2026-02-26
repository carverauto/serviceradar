defmodule ServiceRadarWebNG.Topology.GodViewStreamTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.NetworkDiscovery.TopologyLink
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

    Application.put_env(:serviceradar_web_ng, :god_view_snapshot_coalesce_ms, 0)

    on_exit(fn ->
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
    assert {:ok, %{snapshot: snapshot, payload: payload}} = GodViewStream.latest_snapshot()

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

    assert {:ok, _result} = GodViewStream.latest_snapshot()

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
    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
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

    assert true = Native.runtime_graph_replace_links(graph_ref, rows)

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
    assert length(snapshot.edges) == length(rows)
    assert Map.get(snapshot.pipeline_stats, :edge_parity_delta) == 0
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
             GodViewStream.latest_snapshot()

    assert is_integer(build_ms)
    assert build_ms >= 0
  end

  test "latest_snapshot/0 returns causal bitmaps with consistent counts and widths" do
    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()

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
    left_uid = "coord-left-#{suffix}"
    right_uid = "coord-right-#{suffix}"
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

    assert {:ok, %{snapshot: first}} = GodViewStream.latest_snapshot()

    first_coords = coords_for(first, [left_uid, right_uid])
    first_states = states_for(first, [left_uid, right_uid])

    assert map_size(first_coords) == 2
    assert map_size(first_states) == 2

    left
    |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, actor: actor)
    |> Ash.update!()

    assert {:ok, %{snapshot: second}} = GodViewStream.latest_snapshot()

    second_coords = coords_for(second, [left_uid, right_uid])
    second_states = states_for(second, [left_uid, right_uid])

    assert second_coords == first_coords
    assert second.revision != first.revision
    assert second_states != first_states
  end

  test "latest_snapshot/0 keeps coordinates stable for high-fanout overlay-only updates" do
    actor = SystemActor.system(:god_view_stream_fanout_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    core_uid = "core-#{suffix}"
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
        uid = "ep-#{suffix}-#{idx}"

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

    assert {:ok, %{snapshot: first}} = GodViewStream.latest_snapshot()

    tracked_ids = [core_uid | endpoint_uids]
    first_coords = coords_for(first, tracked_ids)
    first_states = states_for(first, tracked_ids)

    assert map_size(first_coords) == endpoint_count + 1
    assert map_size(first_states) == endpoint_count + 1

    # Overlay-only change: availability flip for one endpoint, no topology edits.
    endpoint_to_flip = List.first(endpoint_uids)

    endpoint =
      Device
      |> Ash.Query.for_read(:by_uid, %{uid: endpoint_to_flip, include_deleted: false},
        actor: actor
      )
      |> Ash.read_one!()

    endpoint
    |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, actor: actor)
    |> Ash.update!()

    # Keep compiler happy about the seeded core record.
    assert core.uid == core_uid

    assert {:ok, %{snapshot: second}} = GodViewStream.latest_snapshot()

    second_coords = coords_for(second, tracked_ids)
    second_states = states_for(second, tracked_ids)

    assert second_coords == first_coords
    assert second_states != first_states
    assert second.revision != first.revision
  end

  test "latest_snapshot/0 preserves unresolved endpoint IDs without resolver fusion" do
    actor = SystemActor.system(:god_view_stream_unresolved_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    local_uid = "strict-local-#{suffix}"
    existing_uid = "existing-device-#{suffix}"
    unresolved_id = "mystery-uplink-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()

    assert Enum.any?(snapshot.nodes, &(&1.id == unresolved_id))
    assert Enum.any?(snapshot.edges, &(&1.source == local_uid and &1.target == unresolved_id))
    refute Enum.any?(snapshot.edges, &(&1.source == local_uid and &1.target == existing_uid))
  end

  test "latest_snapshot/0 prefers SNMP-attributed topology evidence over UniFi-only evidence" do
    actor = SystemActor.system(:god_view_stream_snmp_precedence_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "snmp-left-#{suffix}"
    right_uid = "snmp-right-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()

    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert String.downcase(to_string(edge.protocol || "")) == "lldp"
    assert edge.local_if_index == 7
  end

  test "latest_snapshot/0 marks UniFi-only edges without interface attribution as telemetry-ineligible" do
    actor = SystemActor.system(:god_view_stream_unifi_telemetry_eligibility_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "unifi-left-#{suffix}"
    right_uid = "unifi-right-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()

    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert String.downcase(to_string(edge.protocol || "")) == "unifi-api"
    assert Map.get(edge, :telemetry_eligible) == false
  end

  test "latest_snapshot/0 prefers attributed SNMP-L2 over unattributed UniFi on infra links" do
    actor = SystemActor.system(:god_view_stream_snmp_l2_preference_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "snmp-pref-left-#{suffix}"
    right_uid = "snmp-pref-right-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert String.downcase(to_string(edge.protocol || "")) == "snmp-l2"
    assert edge.flow_pps > 0
    assert edge.flow_bps > 0
  end

  test "latest_snapshot/0 canonicalizes mac-* topology endpoint ids to device uid aliases" do
    actor = SystemActor.system(:god_view_stream_mac_alias_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "alias-left-#{suffix}"
    right_uid = "alias-right-#{suffix}"
    mac_alias = "mac-aabbccddeeff"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge

    refute Enum.any?(snapshot.edges, fn e ->
             e.source == mac_alias or e.target == mac_alias
           end)
  end

  test "latest_snapshot/0 applies BMP routing causal overlays without coordinate churn" do
    actor = SystemActor.system(:god_view_stream_bmp_overlay_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    router_uid = "router-causal-#{suffix}"
    peer_uid = "peer-causal-#{suffix}"
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

    assert {:ok, %{snapshot: first}} = GodViewStream.latest_snapshot()

    tracked = [router_uid, peer_uid]
    first_coords = coords_for(first, tracked)
    first_states = states_for(first, tracked)

    Repo.insert_all("ocsf_events", [
      %{
        id: Ecto.UUID.generate(),
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

    assert {:ok, %{snapshot: second}} = GodViewStream.latest_snapshot()

    second_coords = coords_for(second, tracked)
    second_states = states_for(second, tracked)

    assert second_coords == first_coords
    assert second_states != first_states
    assert second_states[router_uid] in [0, 1]
  end

  test "latest_snapshot/0 applies BMP routing overlays from bmp_routing_events table" do
    actor = SystemActor.system(:god_view_stream_bmp_table_overlay_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    router_uid = "router-bmp-table-#{suffix}"
    peer_uid = "peer-bmp-table-#{suffix}"
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

    assert {:ok, %{snapshot: first}} = GodViewStream.latest_snapshot()

    tracked = [router_uid, peer_uid]
    first_coords = coords_for(first, tracked)
    first_states = states_for(first, tracked)

    Repo.insert_all("bmp_routing_events", [
      %{
        id: Ecto.UUID.generate(),
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

    assert {:ok, %{snapshot: second}} = GodViewStream.latest_snapshot()

    second_coords = coords_for(second, tracked)
    second_states = states_for(second, tracked)

    assert second_coords == first_coords
    assert second_states != first_states
    assert second_states[router_uid] in [0, 1]
  end

  test "latest_snapshot/0 publishes directional edge telemetry from interface in/out counters" do
    actor = SystemActor.system(:god_view_stream_directional_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "dir-left-#{suffix}"
    right_uid = "dir-right-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
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

    assert true = Native.runtime_graph_replace_links(graph_ref, [row])

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
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
    left_uid = "zzz-left-#{suffix}"
    right_uid = "aaa-right-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
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
    left_uid = "dir-one-left-#{suffix}"
    right_uid = "dir-one-right-#{suffix}"
    now = DateTime.utc_now()

    create_topology_device(actor, left_uid, "left-one-dir-#{suffix}.local")
    create_topology_device(actor, right_uid, "right-one-dir-#{suffix}.local")

    create_topology_link(actor, now, left_uid, right_uid, 8)
    create_interface_observation(actor, now, left_uid, "eth8", 8)

    insert_metric(now, left_uid, 8, "ifOutUcastPkts", 222)
    insert_metric(now, left_uid, 8, "ifOutOctets", 2_000)

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
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
    left_uid = "dir-edge-key-left-#{suffix}"
    right_uid = "dir-edge-key-right-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0
    assert edge.flow_bps_ab > 0
    assert edge.flow_bps_ba > 0
    assert edge.telemetry_source == "interface"
  end

  test "latest_snapshot/0 uses neighbor-only attribution to keep direct edge telemetry visible" do
    actor = SystemActor.system(:god_view_stream_neighbor_only_directional_test)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    left_uid = "dir-neighbor-left-#{suffix}"
    right_uid = "dir-neighbor-right-#{suffix}"
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

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
    edge = find_edge(snapshot, left_uid, right_uid)
    assert edge
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0
    assert edge.flow_bps_ab > 0
    assert edge.flow_bps_ba > 0
    assert edge.telemetry_source == "interface"
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

    assert true = Native.runtime_graph_replace_links(graph_ref, [row])

    # Metric on selected AB index (14)
    insert_metric(now, left_uid, 14, "ifOutUcastPkts", 400)
    insert_metric(now, left_uid, 14, "ifOutOctets", 4_000)
    # Conflicting metric on same-name interface index (32) must not be used.
    insert_metric(now, left_uid, 32, "ifOutUcastPkts", 3)
    insert_metric(now, left_uid, 32, "ifOutOctets", 30)
    # BA metric from right side.
    insert_metric(now, right_uid, 9, "ifOutUcastPkts", 100)
    insert_metric(now, right_uid, 9, "ifOutOctets", 1_000)

    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()
    assert [edge] = snapshot.edges
    assert edge.flow_pps_ab == 400
    assert edge.flow_pps_ba == 100
    assert edge.flow_bps_ab == 32_000
    assert edge.flow_bps_ba == 8_000
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

    assert true = Native.runtime_graph_replace_links(graph_ref, critical_rows)
    assert {:ok, %{snapshot: snapshot}} = GodViewStream.latest_snapshot()

    assert edge = find_edge(snapshot, "sr:tonka01", "sr:aruba-24g-02")
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0

    assert edge = find_edge(snapshot, "sr:farm01", "sr:uswaggregation")
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0

    assert edge = find_edge(snapshot, "sr:uswlite8poe", "sr:u6mesh")
    assert edge.flow_pps_ab > 0
    assert edge.flow_pps_ba > 0
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

  defp create_topology_device(actor, uid, hostname) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: hostname,
        type_id: 12,
        is_available: true,
        first_seen_time: DateTime.utc_now(),
        last_seen_time: DateTime.utc_now()
      },
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

  defp create_interface_observation(actor, timestamp, device_id, if_name, if_index) do
    Interface
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: timestamp,
        device_id: device_id,
        interface_uid: "#{device_id}/#{if_name}",
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
    Repo.insert_all("timeseries_metrics", [
      %{
        timestamp: timestamp,
        gateway_id: "gw-god-view-test",
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
    ])
  end
end
