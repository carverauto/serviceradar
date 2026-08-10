defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.EdgeRouteSafetyTest do
  @moduledoc """
  The edge-only escalation warning (design D3).

  The configuration under test is the one that silently guarantees no page
  exactly when one is owed: an escalation policy whose only reachable channels
  egress from the site agent that just went dark.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.EdgeRouteSafety

  @moduletag :db_free

  defp channel(id, attrs) do
    Map.merge(
      %{
        id: id,
        name: "channel-#{id}",
        enabled: true,
        execution_route: :control_plane,
        partition_id: nil,
        agent_uid: nil,
        fail_closed: false,
        fallback_channel_id: nil
      },
      attrs
    )
  end

  defp index(channels), do: Map.new(channels, &{&1.id, &1})

  test "an edge-only policy with no fallback is warned, naming the partition" do
    channels = index([channel("edge-1", %{execution_route: :edge_agent, partition_id: "site-a"})])

    assert %{kind: :edge_only} = warning = EdgeRouteSafety.evaluate([["edge-1"]], channels)

    assert warning.partitions == ["site-a"]
    assert warning.message =~ "site-a"
    assert warning.message =~ "cannot deliver a site-down page"
    assert warning.remediation =~ "control-plane"
    refute warning.fail_closed?
  end

  test "a control-plane channel anywhere in the ladder clears the warning" do
    channels =
      index([
        channel("edge-1", %{execution_route: :edge_agent, partition_id: "site-a"}),
        channel("cp-1", %{})
      ])

    refute EdgeRouteSafety.warns?([["edge-1"], ["cp-1"]], channels)
    refute EdgeRouteSafety.warns?([["edge-1", "cp-1"]], channels)
  end

  test "a control-plane fallback one hop away clears the warning" do
    channels =
      index([
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fallback_channel_id: "cp-1"
        }),
        channel("cp-1", %{})
      ])

    refute EdgeRouteSafety.warns?([["edge-1"]], channels)

    reachable = EdgeRouteSafety.reachable_channels([["edge-1"]], channels)
    assert Enum.map(reachable, & &1.id) == ["edge-1", "cp-1"]
  end

  test "an edge fallback for an edge channel does not clear the warning" do
    channels =
      index([
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fallback_channel_id: "edge-2"
        }),
        channel("edge-2", %{execution_route: :edge_agent, partition_id: "site-a"})
      ])

    assert EdgeRouteSafety.warns?([["edge-1"]], channels)
  end

  test "fail_closed makes the fallback unreachable, and the warning says so" do
    channels =
      index([
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fail_closed: true,
          fallback_channel_id: "cp-1"
        }),
        channel("cp-1", %{})
      ])

    assert %{fail_closed?: true} = warning = EdgeRouteSafety.evaluate([["edge-1"]], channels)
    assert warning.message =~ "fail_closed"
    assert warning.message =~ "lost outright"

    # The configured fallback is inert, so it is not part of the reachable set.
    reachable = EdgeRouteSafety.reachable_channels([["edge-1"]], channels)
    assert Enum.map(reachable, & &1.id) == ["edge-1"]
  end

  test "a second failover hop is not reachable, because the engine takes one" do
    channels =
      index([
        channel("edge-1", %{execution_route: :edge_agent, fallback_channel_id: "edge-2"}),
        channel("edge-2", %{execution_route: :edge_agent, fallback_channel_id: "cp-1"}),
        channel("cp-1", %{})
      ])

    assert EdgeRouteSafety.warns?([["edge-1"]], channels)
  end

  test "an unknown channel id is not evidence of a safe route" do
    channels = index([channel("edge-1", %{execution_route: :edge_agent, partition_id: "site-a"})])

    assert EdgeRouteSafety.warns?([["edge-1", "missing-id"]], channels)
  end

  test "a policy with no channels at all is not warned by this rule" do
    assert EdgeRouteSafety.evaluate([[]], %{}) == nil
    assert EdgeRouteSafety.evaluate([], %{}) == nil
  end

  test "the agent uid stands in when a partition has not been bound yet" do
    channels =
      index([channel("edge-1", %{execution_route: :edge_agent, agent_uid: "agent-hq"})])

    assert %{partitions: ["agent-hq"]} = EdgeRouteSafety.evaluate([["edge-1"]], channels)
  end

  test "string execution routes are recognised as edge" do
    channels = index([channel("edge-1", %{execution_route: "edge_agent", partition_id: "site-a"})])

    assert EdgeRouteSafety.warns?([["edge-1"]], channels)
  end
end
