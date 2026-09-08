defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveFormattingTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Changes.InvalidChanges
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Formatting

  @moduletag :db_free

  describe "format_ports_for_modes/2" do
    test "hides ports for an icmp-only profile" do
      # ICMP has no ports. An icmp-only profile still carries whatever port list
      # it was created with, and showing it claims the sweep probes those ports.
      assert Formatting.format_ports_for_modes([22, 80, 445, 3389, 5985, 5986], ["icmp"]) == "n/a"
      assert Formatting.format_ports_for_modes([22], [:icmp]) == "n/a"
    end

    test "shows ports when any mode uses them" do
      assert Formatting.format_ports_for_modes([22, 80], ["tcp"]) == "22, 80"
      assert Formatting.format_ports_for_modes([3001, 443, 4502], ["icmp", "tcp"]) == "3001, 443, 4502"
      assert Formatting.format_ports_for_modes([22, 80, 445, 3389, 5985, 5986], ["tcp"]) == "6 ports"
    end

    test "falls through to showing ports when modes cannot be read" do
      # Suppressing a real port list because the modes were unreadable would be
      # a worse lie than the one this fixes.
      assert Formatting.format_ports_for_modes([22, 80], nil) == "22, 80"
      assert Formatting.format_ports_for_modes([22, 80], []) == "22, 80"
    end

    test "renders an empty port list as a dash regardless of mode" do
      assert Formatting.format_ports_for_modes([], ["tcp"]) == "—"
      assert Formatting.format_ports_for_modes(nil, ["tcp"]) == "—"
    end
  end

  test "mapper run validation messages are bounded" do
    unbounded_message = String.duplicate("mapper unavailable ", 30)

    error =
      [fields: [:agent_id], message: unbounded_message]
      |> InvalidChanges.exception()
      |> Ash.Error.to_error_class()

    message = Formatting.format_mapper_run_error(error)

    assert String.length(message) == 240
    assert String.ends_with?(message, "…")
  end

  test "expected mapper availability errors stay actionable" do
    assert Formatting.format_mapper_run_error(:agent_offline) =~
             "No online mapper-capable agent"

    assert Formatting.format_mapper_run_error({:agent_offline, "agent-1"}) =~
             "assigned mapper agent is offline"
  end
end
