defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.SweepContextTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  # Pure functions over plain maps: no repo, no Ash, no fixture. Without this tag
  # the file still LOADS in the db-free lane and then contributes zero tests,
  # which the shard-level guard in test_helper.exs cannot catch in an otherwise
  # populated shard.
  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Components
  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.SweepContext

  @moduletag :db_free

  defp entry(agent_id, intervals) do
    %{
      key: agent_id,
      label: agent_id,
      agent_id: agent_id,
      partition: "default",
      groups:
        Enum.with_index(intervals, fn interval, index ->
          %{
            id: "group-#{agent_id}-#{index}",
            name: "group-#{index}",
            assigned?: false,
            ports: [],
            modes: ["icmp"],
            interval: interval,
            interval_seconds: nil,
            profile_name: nil
          }
        end)
    }
  end

  # coverage_intervals/1 reads interval_seconds, which for_inputs/3 populates
  # from the group's operator-facing duration string. These fixtures set it
  # explicitly so the parsing and the aggregation are tested separately.
  defp with_seconds(entry, seconds_list) do
    groups =
      entry.groups
      |> Enum.zip(seconds_list)
      |> Enum.map(fn {group, seconds} -> %{group | interval_seconds: seconds} end)

    %{entry | groups: groups}
  end

  describe "interval_seconds/1" do
    test "parses the duration units sweep groups actually use" do
      assert SweepContext.interval_seconds("30s") == 30
      assert SweepContext.interval_seconds("5m") == 300
      assert SweepContext.interval_seconds("1h") == 3600
      assert SweepContext.interval_seconds("2d") == 172_800
    end

    test "treats a bare number as seconds" do
      assert SweepContext.interval_seconds("45") == 45
    end

    test "tolerates surrounding whitespace" do
      assert SweepContext.interval_seconds("  1h  ") == 3600
    end

    test "returns nil rather than guessing on anything unrecognised" do
      # A wrong guess here produces a staleness warning about a mismatch that may
      # not exist, which is worse than staying quiet.
      assert SweepContext.interval_seconds("1 fortnight") == nil
      assert SweepContext.interval_seconds("hourly") == nil
      assert SweepContext.interval_seconds("") == nil
      assert SweepContext.interval_seconds(nil) == nil
      assert SweepContext.interval_seconds(3600) == nil
    end

    test "rejects non-positive intervals" do
      assert SweepContext.interval_seconds("0m") == nil
      assert SweepContext.interval_seconds("-5m") == nil
    end
  end

  describe "coverage_intervals/1" do
    test "reports the SLOWEST covering group per agent" do
      # The slowest group is what bounds freshness: a vantage point fed by an
      # hourly sweep and a 5-minute sweep still goes stale on the hourly one.
      entries = [
        with_seconds(entry("agent-a", ["5m", "1h"]), [300, 3600]),
        with_seconds(entry("agent-b", ["30s"]), [30])
      ]

      assert SweepContext.coverage_intervals(entries) == %{
               "agent-a" => 3600,
               "agent-b" => 30
             }
    end

    test "omits an agent with no covering group rather than reporting zero" do
      # Absent and zero mean opposite things: "nothing feeds this vantage point"
      # versus "an instantaneous sweep feeds it". A zero would make the staleness
      # comparison pass for every window.
      entries = [with_seconds(entry("agent-a", []), [])]

      assert SweepContext.coverage_intervals(entries) == %{}
    end

    test "omits an agent whose groups all have unparseable intervals" do
      entries = [with_seconds(entry("agent-a", ["whenever"]), [nil])]

      assert SweepContext.coverage_intervals(entries) == %{}
    end

    test "ignores unparseable groups but keeps the parseable ones" do
      entries = [with_seconds(entry("agent-a", ["1h", "garbage"]), [3600, nil])]

      assert SweepContext.coverage_intervals(entries) == %{"agent-a" => 3600}
    end

    test "skips entries with no agent id" do
      entry = with_seconds(entry("agent-a", ["1h"]), [3600])

      assert SweepContext.coverage_intervals([%{entry | agent_id: nil}]) == %{}
    end

    test "is empty for no entries" do
      assert SweepContext.coverage_intervals([]) == %{}
    end
  end

  test "labels fixed-subset coverage separately from partition-wide coverage" do
    html =
      render_component(&Components.sweep_context/1, %{
        mode: :edit,
        entries: [
          %{
            key: "vantage-a",
            label: "Vantage A",
            agent_id: "agent-a",
            partition: "default",
            groups: [
              %{
                id: "selected-group",
                name: "Fixed subset",
                assigned?: true,
                ports: [],
                modes: ["icmp"],
                interval: "5m",
                interval_seconds: 300,
                profile_name: nil
              },
              %{
                id: "partition-group",
                name: "Partition wide",
                assigned?: false,
                ports: [],
                modes: ["icmp"],
                interval: "5m",
                interval_seconds: 300,
                profile_name: nil
              }
            ]
          }
        ]
      })

    assert html =~ "selected for this agent"
    assert html =~ "all agents in partition"
  end
end
