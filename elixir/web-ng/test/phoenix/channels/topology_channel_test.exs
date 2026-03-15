defmodule ServiceRadarWebNGWeb.TopologyChannelTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Phoenix.ChannelTest

  alias ServiceRadarWebNG.AccountsFixtures
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
             socket(UserSocket, "user-id", %{current_user: user})
             |> subscribe_and_join(ServiceRadarWebNGWeb.TopologyChannel, @channel, %{})
  end

  test "channel emits binary snapshot frame with expected envelope", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    assert {:ok, _reply, _socket} =
             socket(UserSocket, "user-id", %{current_user: user})
             |> subscribe_and_join(ServiceRadarWebNGWeb.TopologyChannel, @channel, %{})

    assert_push "snapshot", {:binary, frame}, 2_000

    assert <<magic::binary-size(4), schema::unsigned-integer-size(8),
             revision::unsigned-integer-size(64), generated_at_ms::signed-integer-size(64),
             root_bytes::unsigned-integer-size(32), affected_bytes::unsigned-integer-size(32),
             healthy_bytes::unsigned-integer-size(32), unknown_bytes::unsigned-integer-size(32),
             root_count::unsigned-integer-size(32), affected_count::unsigned-integer-size(32),
             healthy_count::unsigned-integer-size(32), unknown_count::unsigned-integer-size(32),
             payload::binary>> = frame

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

  test "channel emits snapshot_error when snapshot build fails budget guard", %{user: user} do
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
             socket(UserSocket, "user-id", %{current_user: user})
             |> subscribe_and_join(ServiceRadarWebNGWeb.TopologyChannel, @channel, %{})

    assert_push "snapshot_error", %{reason: "snapshot_unavailable"}, 2_000
  end
end
