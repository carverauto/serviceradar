defmodule ServiceRadarWebNGWeb.TopologyChannelTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Phoenix.ChannelTest

  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.TopologyChannel
  alias ServiceRadarWebNGWeb.UserSocket

  @endpoint ServiceRadarWebNGWeb.Endpoint
  @channel "topology:god_view"

  setup do
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    user = AccountsFixtures.user_fixture()

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)
    end)

    {:ok, user: user}
  end

  test "join rejects when god view is disabled", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)

    assert {:error, %{reason: "god_view_disabled"}} =
             UserSocket
             |> socket("user-id", %{current_user: user})
             |> subscribe_and_join(TopologyChannel, @channel, %{})
  end

  test "channel emits binary snapshot frame with expected envelope", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user})
             |> subscribe_and_join(TopologyChannel, @channel, %{})

    assert_push "snapshot", {:binary, frame}, 2_000

    assert <<magic::binary-size(4), schema::unsigned-integer-size(8), revision::unsigned-integer-size(64),
             generated_at_ms::signed-integer-size(64), root_bytes::unsigned-integer-size(32),
             affected_bytes::unsigned-integer-size(32), healthy_bytes::unsigned-integer-size(32),
             unknown_bytes::unsigned-integer-size(32), root_count::unsigned-integer-size(32),
             affected_count::unsigned-integer-size(32), healthy_count::unsigned-integer-size(32),
             unknown_count::unsigned-integer-size(32), payload::binary>> = frame

    assert magic == "GVB1"
    assert schema > 0
    assert revision > 0
    assert generated_at_ms > 0
    assert root_bytes >= 0
    assert affected_bytes >= 0
    assert healthy_bytes >= 0
    assert unknown_bytes >= 0
    assert root_count + affected_count + healthy_count + unknown_count >= 0
    assert binary_part(payload, 0, 6) == "ARROW1"
    assert binary_part(payload, byte_size(payload) - 6, 6) == "ARROW1"
  end

  test "channel snapshot_meta carries per-edge-class counts and backbone_edge_count", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user})
             |> subscribe_and_join(TopologyChannel, @channel, %{})

    assert_push "snapshot_meta", %{pipeline_stats: pipeline_stats}, 2_000

    assert is_integer(Map.get(pipeline_stats, :backbone_edge_count))
    assert is_integer(Map.get(pipeline_stats, :edge_class_backbone))
    assert is_integer(Map.get(pipeline_stats, :edge_class_attachment))
    assert is_integer(Map.get(pipeline_stats, :edge_class_inferred))
    assert is_integer(Map.get(pipeline_stats, :edge_class_hosted))
    assert is_integer(Map.get(pipeline_stats, :edge_class_observed))
    assert Map.get(pipeline_stats, :backbone_edge_count) == Map.get(pipeline_stats, :edge_class_backbone)
  end

  test "channel suppresses duplicate snapshot pushes when revision is unchanged", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user-id", %{current_user: user})
             |> subscribe_and_join(TopologyChannel, @channel, %{})

    assert_push "snapshot", {:binary, _frame}, 2_000
    assert_push "snapshot_meta", _meta, 2_000

    send(socket.channel_pid, :tick)

    refute_push "snapshot", _duplicate_frame, 500
    refute_push "snapshot_meta", _duplicate_meta, 500
  end

  test "channel still emits snapshot when build exceeds real-time budget", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    original_budget = Application.get_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms)
    Application.put_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms, -1)

    on_exit(fn ->
      if is_nil(original_budget) do
        Application.delete_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms)
      else
        Application.put_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms, original_budget)
      end
    end)

    assert {:ok, _reply, _socket} =
             UserSocket
             |> socket("user-id", %{current_user: user})
             |> subscribe_and_join(TopologyChannel, @channel, %{})

    assert_push "snapshot", {:binary, _frame}, 2_000
    assert_push "snapshot_meta", _meta, 2_000
    refute_push "snapshot_error", _payload, 500
  end

  test "next_expanded_clusters allows concurrent expansions without clearing existing ones" do
    assert TopologyChannel.next_expanded_clusters([], "cluster:a", true) == ["cluster:a"]

    assert TopologyChannel.next_expanded_clusters(["cluster:a"], "cluster:b", true) ==
             ["cluster:a", "cluster:b"]

    # re-expanding an already expanded cluster keeps the set stable
    assert TopologyChannel.next_expanded_clusters(["cluster:a", "cluster:b"], "cluster:b", true) ==
             ["cluster:a", "cluster:b"]
  end

  test "next_expanded_clusters never evicts an expansion to make room for another" do
    # There is no cap. A deployment with five endpoint clusters must be able to hold all five
    # open; the previous limit of four silently collapsed the first when the fifth was opened,
    # which reads to the operator as a click closing an unrelated group.
    clusters = for index <- 1..12, do: "cluster:#{index}"

    expanded =
      Enum.reduce(clusters, [], fn cluster, acc ->
        TopologyChannel.next_expanded_clusters(acc, cluster, true)
      end)

    assert expanded == clusters

    # collapsing one leaves every other expansion untouched
    assert TopologyChannel.next_expanded_clusters(expanded, "cluster:5", false) ==
             List.delete(clusters, "cluster:5")
  end
end
