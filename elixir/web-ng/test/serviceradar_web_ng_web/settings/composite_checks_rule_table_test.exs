defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.RuleTableTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.RuleTable

  defp input(key, kind, position) do
    %{key: key, label: key, kind: kind, position: position}
  end

  defp rule(id, position, catch_all \\ false) do
    %{id: id, position: position, catch_all: catch_all}
  end

  describe "columns/1" do
    test "orders columns by input position, not by map order" do
      columns =
        RuleTable.columns([
          input("agent-b", :vantage_point, 1),
          input("agent-a", :vantage_point, 0)
        ])

      assert Enum.map(columns, & &1.key) == ["agent-a", "agent-b"]
    end

    test "a vantage point offers the reachability values, a fact offers booleans" do
      [vantage, fact] =
        RuleTable.columns([
          input("agent-a", :vantage_point, 0),
          input("acl_enforced", :device_metadata, 1)
        ])

      assert Enum.map(vantage.options, &elem(&1, 0)) == ["any", "available", "blocked"]
      assert Enum.map(fact.options, &elem(&1, 0)) == ["any", "true", "false"]
    end
  end

  describe "cell_value/2" do
    setup do
      %{columns: RuleTable.columns([input("agent-a", :vantage_point, 0)])}
    end

    test "an absent key reads as any", %{columns: [column]} do
      assert RuleTable.cell_value(%{}, column) == "any"
    end

    test "the explicit wildcard also reads as any", %{columns: [column]} do
      assert RuleTable.cell_value(%{"agent-a" => "*"}, column) == "any"
    end

    test "a literal reads as itself", %{columns: [column]} do
      assert RuleTable.cell_value(%{"agent-a" => "blocked"}, column) == "blocked"
    end

    test "a boolean renders as a string so the select can match it" do
      [column] = RuleTable.columns([input("acl", :device_metadata, 0)])

      assert RuleTable.cell_value(%{"acl" => true}, column) == "true"
    end
  end

  describe "match_from_params/3" do
    setup do
      %{
        columns:
          RuleTable.columns([
            input("agent-a", :vantage_point, 0),
            input("acl", :device_metadata, 1)
          ])
      }
    end

    test "any is stored as an absent key rather than a wildcard", %{columns: columns} do
      params = %{"match" => %{"agent-a" => "blocked", "acl" => "any"}}

      assert RuleTable.match_from_params(columns, params, %{}) == %{"agent-a" => "blocked"}
    end

    test "a metadata cell casts to a boolean", %{columns: columns} do
      params = %{"match" => %{"agent-a" => "any", "acl" => "false"}}

      # Stored as a boolean, not the string "false": the resolver produces
      # booleans, and a string would never compare equal.
      assert RuleTable.match_from_params(columns, params, %{}) == %{"acl" => false}
    end

    test "a list-valued cell the select cannot represent survives an unrelated edit", %{
      columns: columns
    } do
      existing = %{"agent-a" => ["blocked", "unknown"]}
      params = %{"match" => %{"agent-a" => "any", "acl" => "true"}}

      # The select rendered "any" because it has no option for a list. Treating
      # that as an edit would silently widen a hand-written rule to match
      # everything for that input.
      assert RuleTable.match_from_params(columns, params, existing) == %{
               "agent-a" => ["blocked", "unknown"],
               "acl" => true
             }
    end

    test "an explicit choice overrides a list value", %{columns: columns} do
      existing = %{"agent-a" => ["blocked", "unknown"]}
      params = %{"match" => %{"agent-a" => "available", "acl" => "any"}}

      assert RuleTable.match_from_params(columns, params, existing) == %{"agent-a" => "available"}
    end

    test "every cell set to any yields an empty match", %{columns: columns} do
      params = %{"match" => %{"agent-a" => "any", "acl" => "any"}}

      # Deliberately not prevented here. The database check constraint rejects
      # it with the message the operator needs to read, and duplicating that
      # rule in the form would let the two drift.
      assert RuleTable.match_from_params(columns, params, %{}) == %{}
    end
  end

  describe "move/3" do
    test "moves a rule up" do
      rules = [rule("a", 0), rule("b", 1), rule("c", 2)]

      assert rules |> RuleTable.move("c", :up) |> Enum.map(& &1.id) == ["a", "c", "b"]
    end

    test "moves a rule down" do
      rules = [rule("a", 0), rule("b", 1), rule("c", 2)]

      assert rules |> RuleTable.move("a", :down) |> Enum.map(& &1.id) == ["b", "a", "c"]
    end

    test "moving the first rule up is a no-op" do
      rules = [rule("a", 0), rule("b", 1)]

      assert rules |> RuleTable.move("a", :up) |> Enum.map(& &1.id) == ["a", "b"]
    end

    test "moving the last rule down is a no-op" do
      rules = [rule("a", 0), rule("b", 1)]

      assert rules |> RuleTable.move("b", :down) |> Enum.map(& &1.id) == ["a", "b"]
    end

    test "the catch-all is never part of the ordering" do
      rules = [rule("a", 0), rule("b", 1), rule("catch", 1_000_000, true)]

      # The resource forbids updating the catch-all at all, so handing it to a
      # renumbering pass would fail the whole reorder.
      assert rules |> RuleTable.move("b", :up) |> Enum.map(& &1.id) == ["b", "a"]
    end

    test "an unknown id leaves the authored order alone" do
      rules = [rule("a", 0), rule("b", 1), rule("catch", 1_000_000, true)]

      assert rules |> RuleTable.move("gone", :up) |> Enum.map(& &1.id) == ["a", "b"]
    end
  end

  describe "repositions/1" do
    test "returns only the rules whose stored position changed" do
      ordered = [rule("a", 1), rule("b", 0), rule("c", 2)]

      assert RuleTable.repositions(ordered) == [{rule("a", 1), 0}, {rule("b", 0), 1}]
    end

    test "returns nothing when the order already matches" do
      assert RuleTable.repositions([rule("a", 0), rule("b", 1)]) == []
    end
  end
end
