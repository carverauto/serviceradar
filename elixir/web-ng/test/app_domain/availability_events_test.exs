defmodule ServiceRadarWebNG.AvailabilityEventsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.AvailabilityEvents

  @moduletag :unit
  @moduletag :db_free

  test "detects down and recovery flips from update returning rows" do
    rows = [
      ["sr:down", true, false, "edge-1", "192.168.2.10"],
      ["sr:up", false, true, "edge-2", "192.168.2.11"],
      ["sr:same", true, true, "edge-3", "192.168.2.12"],
      ["sr:still-down", false, false, "edge-4", "192.168.2.13"]
    ]

    assert [
             {:unavailable, %{uid: "sr:down", hostname: "edge-1", ip: "192.168.2.10"}},
             {:available, %{uid: "sr:up", hostname: "edge-2", ip: "192.168.2.11"}}
           ] = AvailabilityEvents.transitions_from_rows(rows)
  end

  test "publishes unavailable and available payloads" do
    parent = self()

    publisher = fn subject, payload ->
      send(parent, {:published, subject, payload})
      :ok
    end

    transitions = [
      {:unavailable, %{uid: "sr:1", hostname: "farm01", ip: "192.168.2.1"}}
    ]

    assert :ok =
             AvailabilityEvents.emit(transitions, %{
               publisher: publisher,
               sweep_group_id: "group-1",
               sweep_group_name: "LAN ICMP",
               agent_id: "k8s-agent",
               execution_id: "exec-1"
             })

    assert_receive {:published, "sweep", payload}
    assert payload["event_type"] == "device.unavailable"
    assert payload["attributes"]["event_type"] == "device.unavailable"
    assert payload["attributes"]["device"]["uid"] == "sr:1"
    assert payload["message"] =~ "farm01"
    assert payload["attributes"]["sweep_group_name"] == "LAN ICMP"
  end

  test "skips empty transition lists" do
    assert :ok = AvailabilityEvents.emit([], %{publisher: fn _, _ -> flunk("published") end})
  end
end
