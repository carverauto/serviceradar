defmodule ServiceRadarWebNG.Plugins.AddonFleetTest do
  @moduledoc """
  Pure unit tests for the add-on fleet query/transform layer.

  These exercise the in-memory matrix transforms (`filter/2`, `summary/1`,
  `addon_ids/1`, `agents/1`) with hand-built rows, so they need no database.
  The DB-backed read path (`rows/1`) is covered by the DB-gated LiveView tests
  and is not exercised here.
  """
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.AddonFleet

  # A row shaped like AddonFleet.row(); only the keys the transforms read are
  # load-bearing, but we keep the full shape so the test fixtures stay honest.
  defp row(overrides) do
    base = %{
      agent_uid: "agent-1",
      agent_label: "alpha (agent-1)",
      addon_id: "endpoint-inventory",
      addon_name: "Endpoint Inventory",
      assigned_version: "1.0.0",
      content_hash: "sha256:abc",
      package_status: :approved,
      verification_status: "verified",
      approved?: true,
      assigned?: true,
      enabled?: true,
      running_state: "running",
      running_version: "1.0.0",
      active?: true,
      degradation_reason: nil,
      reported_at: ~U[2026-06-15 00:00:00Z],
      last_scan_at: ~U[2026-06-15 00:00:00Z],
      collector?: true,
      attention: [],
      attention?: false
    }

    Map.merge(base, Map.new(overrides))
  end

  describe "filter/2" do
    setup do
      rows = [
        row(agent_uid: "agent-1", addon_id: "endpoint-inventory", attention: [], attention?: false),
        row(
          agent_uid: "agent-1",
          addon_id: "netprobe",
          attention: [:stopped_or_inactive],
          attention?: true
        ),
        row(agent_uid: "agent-2", addon_id: "endpoint-inventory", attention: [], attention?: false),
        row(
          agent_uid: nil,
          addon_id: "scalibr-endpoint-inventory",
          agent_label: "— (catalog only)",
          attention: [:staged_not_approved],
          attention?: true
        )
      ]

      {:ok, rows: rows}
    end

    test "no filters returns all rows", %{rows: rows} do
      assert AddonFleet.filter(rows, %{}) == rows
    end

    test "blank string filters are treated as no filter", %{rows: rows} do
      filters = %{"agent_uid" => "", "addon_id" => "  ", "attention_only" => "false"}
      assert AddonFleet.filter(rows, filters) == rows
    end

    test "filters by agent_uid", %{rows: rows} do
      result = AddonFleet.filter(rows, %{"agent_uid" => "agent-1"})
      assert length(result) == 2
      assert Enum.all?(result, &(&1.agent_uid == "agent-1"))
    end

    test "filters by addon_id", %{rows: rows} do
      result = AddonFleet.filter(rows, %{"addon_id" => "endpoint-inventory"})
      assert length(result) == 2
      assert Enum.all?(result, &(&1.addon_id == "endpoint-inventory"))
    end

    test "attention_only keeps only flagged rows", %{rows: rows} do
      result = AddonFleet.filter(rows, %{"attention_only" => "true"})
      assert length(result) == 2
      assert Enum.all?(result, & &1.attention?)
    end

    test "attention_only accepts boolean true and \"on\"", %{rows: rows} do
      assert AddonFleet.filter(rows, %{"attention_only" => true}) ==
               AddonFleet.filter(rows, %{"attention_only" => "true"})

      assert AddonFleet.filter(rows, %{"attention_only" => "on"}) ==
               AddonFleet.filter(rows, %{"attention_only" => "true"})
    end

    test "combines agent and addon filters", %{rows: rows} do
      result =
        AddonFleet.filter(rows, %{"agent_uid" => "agent-1", "addon_id" => "netprobe"})

      assert [%{agent_uid: "agent-1", addon_id: "netprobe"}] = result
    end

    test "combines an attention filter with an agent filter", %{rows: rows} do
      result =
        AddonFleet.filter(rows, %{"agent_uid" => "agent-1", "attention_only" => "true"})

      assert [%{addon_id: "netprobe"}] = result
    end
  end

  describe "summary/1" do
    test "counts totals, attention, running, and staged packages" do
      rows = [
        row(active?: true, package_status: :approved, attention?: false),
        row(active?: false, package_status: :staged, attention?: true),
        row(active?: true, package_status: :staged, attention?: false),
        row(active?: false, package_status: :approved, attention?: true)
      ]

      assert AddonFleet.summary(rows) == %{
               total: 4,
               attention: 2,
               running: 2,
               staged: 2
             }
    end

    test "is all-zero for an empty fleet" do
      assert AddonFleet.summary([]) == %{total: 0, attention: 0, running: 0, staged: 0}
    end
  end

  describe "addon_ids/1" do
    test "returns the distinct, sorted add-on ids" do
      rows = [
        row(addon_id: "netprobe"),
        row(addon_id: "endpoint-inventory"),
        row(addon_id: "netprobe"),
        row(addon_id: "scalibr-endpoint-inventory")
      ]

      assert AddonFleet.addon_ids(rows) ==
               ["endpoint-inventory", "netprobe", "scalibr-endpoint-inventory"]
    end

    test "is empty for no rows" do
      assert AddonFleet.addon_ids([]) == []
    end
  end

  describe "agents/1" do
    test "returns distinct {label, uid}, case-insensitively sorted by label" do
      rows = [
        row(agent_uid: "agent-2", agent_label: "Bravo (agent-2)"),
        row(agent_uid: "agent-1", agent_label: "alpha (agent-1)"),
        row(agent_uid: "agent-1", agent_label: "alpha (agent-1)")
      ]

      assert AddonFleet.agents(rows) == [
               {"alpha (agent-1)", "agent-1"},
               {"Bravo (agent-2)", "agent-2"}
             ]
    end

    test "excludes catalog-only rows that have no agent" do
      rows = [
        row(agent_uid: "agent-1", agent_label: "alpha (agent-1)"),
        row(agent_uid: nil, agent_label: "— (catalog only)")
      ]

      assert AddonFleet.agents(rows) == [{"alpha (agent-1)", "agent-1"}]
    end

    test "is empty for no rows" do
      assert AddonFleet.agents([]) == []
    end
  end
end
