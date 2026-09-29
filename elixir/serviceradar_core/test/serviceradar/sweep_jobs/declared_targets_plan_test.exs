defmodule ServiceRadar.SweepJobs.DeclaredTargetsPlanTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.DeclaredTargets

  test "an unchanged declaration writes nothing" do
    current = [{"198.51.100.10", "sr:dev-0001"}, {"198.51.100.11", nil}]

    assert DeclaredTargets.plan_changes(current, Enum.reverse(current)) ==
             %{upsert: [], delete: []}
  end

  test "new targets are inserted and vanished targets deleted, leaving the rest alone" do
    current = [{"198.51.100.10", "sr:dev-0001"}, {"198.51.100.11", "sr:dev-0002"}]
    declared = [{"198.51.100.11", "sr:dev-0002"}, {"198.51.100.12", "sr:dev-0003"}]

    assert DeclaredTargets.plan_changes(current, declared) ==
             %{upsert: [{"198.51.100.12", "sr:dev-0003"}], delete: ["198.51.100.10"]}
  end

  test "a target whose device changed is rewritten, including to or from no device" do
    current = [
      {"198.51.100.10", "sr:dev-0001"},
      {"198.51.100.11", nil},
      {"198.51.100.12", "sr:dev-0003"}
    ]

    declared = [
      {"198.51.100.10", "sr:dev-0099"},
      {"198.51.100.11", "sr:dev-0002"},
      {"198.51.100.12", nil}
    ]

    assert DeclaredTargets.plan_changes(current, declared) ==
             %{
               upsert: [
                 {"198.51.100.10", "sr:dev-0099"},
                 {"198.51.100.11", "sr:dev-0002"},
                 {"198.51.100.12", nil}
               ],
               delete: []
             }
  end

  test "declaring nothing deletes every recorded target" do
    current = [{"198.51.100.11", nil}, {"198.51.100.10", "sr:dev-0001"}]

    assert DeclaredTargets.plan_changes(current, []) ==
             %{upsert: [], delete: ["198.51.100.10", "198.51.100.11"]}
  end
end
