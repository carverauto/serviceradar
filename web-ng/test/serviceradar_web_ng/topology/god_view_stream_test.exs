defmodule ServiceRadarWebNG.Topology.GodViewStreamTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Topology.GodViewStream

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
    expected_bytes = div(node_count + 7, 8)

    root = Map.fetch!(snapshot.causal_bitmaps, :root_cause)
    affected = Map.fetch!(snapshot.causal_bitmaps, :affected)
    healthy = Map.fetch!(snapshot.causal_bitmaps, :healthy)
    unknown = Map.fetch!(snapshot.causal_bitmaps, :unknown)

    assert byte_size(root) == expected_bytes
    assert byte_size(affected) == expected_bytes
    assert byte_size(healthy) == expected_bytes
    assert byte_size(unknown) == expected_bytes

    root_meta = Map.fetch!(snapshot.bitmap_metadata, :root_cause)
    affected_meta = Map.fetch!(snapshot.bitmap_metadata, :affected)
    healthy_meta = Map.fetch!(snapshot.bitmap_metadata, :healthy)
    unknown_meta = Map.fetch!(snapshot.bitmap_metadata, :unknown)

    assert popcount(root) == root_meta.count
    assert popcount(affected) == affected_meta.count
    assert popcount(healthy) == healthy_meta.count
    assert popcount(unknown) == unknown_meta.count

    assert root_meta.count + affected_meta.count + healthy_meta.count + unknown_meta.count ==
             node_count
  end

  defp popcount(binary) do
    for(<<byte::8 <- binary>>, reduce: 0) do
      acc -> acc + bitcount8(byte)
    end
  end

  defp bitcount8(0), do: 0
  defp bitcount8(n) when is_integer(n) and n > 0, do: 1 + bitcount8(Bitwise.band(n - 1, n))
end
