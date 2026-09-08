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

  describe "channel_advisory/2" do
    test "a control-plane channel has no advisory at all" do
      assert EdgeRouteSafety.channel_advisory(channel("cp-1", %{}), %{}) == nil
    end

    test "fail_closed on an edge channel is an error naming the loss" do
      channel =
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fail_closed: true,
          fallback_channel_id: "cp-1"
        })

      advisory = EdgeRouteSafety.channel_advisory(channel, index([channel, channel("cp-1", %{})]))

      assert advisory.level == :error
      assert advisory.badge =~ "Fail closed"
      assert advisory.message =~ "site-a"
      assert advisory.message =~ "dropped"
      assert advisory.remediation =~ "control-plane"
    end

    test "an edge channel with no fallback is warned" do
      channel = channel("edge-1", %{execution_route: :edge_agent, partition_id: "site-a"})

      advisory = EdgeRouteSafety.channel_advisory(channel, index([channel]))

      assert advisory.level == :warning
      assert advisory.badge == "No failover"
      assert advisory.message =~ "site-a"
    end

    test "a control-plane fallback is the documented remediation and reads as ok" do
      channel =
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fallback_channel_id: "cp-1"
        })

      advisory = EdgeRouteSafety.channel_advisory(channel, index([channel, channel("cp-1", %{})]))

      assert advisory.level == :ok
      assert advisory.badge == "Control-plane failover"
      assert advisory.remediation == nil
    end

    test "a fallback in the same site is an error, because both die together" do
      channel =
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fallback_channel_id: "edge-2"
        })

      other = channel("edge-2", %{execution_route: :edge_agent, partition_id: "site-a"})

      advisory = EdgeRouteSafety.channel_advisory(channel, index([channel, other]))

      assert advisory.level == :error
      assert advisory.badge == "Failover in the same site"
      assert advisory.message =~ "same instant"
    end

    test "a fallback at a different site is a warning, not an error" do
      channel =
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fallback_channel_id: "edge-2"
        })

      other = channel("edge-2", %{execution_route: :edge_agent, partition_id: "site-b"})

      advisory = EdgeRouteSafety.channel_advisory(channel, index([channel, other]))

      assert advisory.level == :warning
      assert advisory.message =~ "site-a"
      assert advisory.message =~ "site-b"
    end

    test "an unreadable fallback is reported as unverified rather than assumed safe" do
      channel =
        channel("edge-1", %{
          execution_route: :edge_agent,
          partition_id: "site-a",
          fallback_channel_id: "gone"
        })

      advisory = EdgeRouteSafety.channel_advisory(channel, index([channel]))

      assert advisory.level == :warning
      assert advisory.badge == "Failover unverified"
    end

    # The editor holds string keys and has no partition_id yet - it is bound
    # server side from the agent's mTLS session - so an unsaved form and a saved
    # row must still report the same thing.
    test "the editor's string-keyed params produce the same advisory" do
      params = %{
        "id" => "edge-1",
        "execution_route" => "edge_agent",
        "agent_uid" => "agent-a",
        "fail_closed" => "true",
        "fallback_channel_id" => ""
      }

      advisory = EdgeRouteSafety.channel_advisory(params, %{})

      assert advisory.level == :error
      assert advisory.message =~ "agent-a"
    end

    test "an unticked fail_closed checkbox is not truthy" do
      params = %{
        "id" => "edge-1",
        "execution_route" => "edge_agent",
        "agent_uid" => "agent-a",
        "fail_closed" => "false",
        "fallback_channel_id" => ""
      }

      assert %{badge: "No failover"} = EdgeRouteSafety.channel_advisory(params, %{})
    end

    test "a same-site comparison never matches on two unlabelled sites" do
      channel = channel("edge-1", %{execution_route: :edge_agent, fallback_channel_id: "edge-2"})
      other = channel("edge-2", %{execution_route: :edge_agent})

      advisory = EdgeRouteSafety.channel_advisory(channel, index([channel, other]))

      assert advisory.level == :warning
      assert advisory.badge == "Failover is another site"
    end
  end
end
