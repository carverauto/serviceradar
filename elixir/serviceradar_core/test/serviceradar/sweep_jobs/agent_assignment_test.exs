defmodule ServiceRadar.SweepJobs.AgentAssignmentTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.AgentAssignment

  @moduletag :db_free

  test "normalizes form assignment values into a sorted unique UID list" do
    assert AgentAssignment.normalize(nil) == []
    assert AgentAssignment.normalize("  agent-b  ") == ["agent-b"]

    assert AgentAssignment.normalize([
             " agent-b ",
             "",
             "agent-a",
             "agent-b",
             "   "
           ]) == ["agent-a", "agent-b"]
  end

  test "rejects maps and nested collections instead of serializing them" do
    assert AgentAssignment.normalize(%{"agent" => "agent-a"}) == []
    assert AgentAssignment.normalize(["agent-a", ["agent-b"]]) == []
  end

  test "membership is exact and a nil requester is never selected" do
    assert AgentAssignment.member?([], "agent-a")
    assert AgentAssignment.member?(["agent-a", "agent-b"], "agent-b")
    refute AgentAssignment.member?(["agent-a", "agent-b"], "agent-c")
    refute AgentAssignment.member?(["agent-a"], nil)
  end

  test "newly_added returns only normalized IDs absent from the stored assignment" do
    assert AgentAssignment.newly_added([" agent-b ", "agent-c", "agent-b"], ["agent-a", "agent-b"]) ==
             ["agent-c"]
  end

  test "scalar mirror retains the first selected agent during rolling upgrades" do
    assert AgentAssignment.scalar_mirror([]) == nil
    assert AgentAssignment.scalar_mirror(["agent-a"]) == "agent-a"
    assert AgentAssignment.scalar_mirror(["agent-a", "agent-b"]) == "agent-a"
  end
end
