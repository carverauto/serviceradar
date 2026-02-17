defmodule ServiceRadarWebNG.Topology.GodViewStreamTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadarWebNG.Topology.GodViewStream

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
end
