defmodule ServiceRadar.SweepJobs.Changes.ReconcileProducerAssignmentsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.Changes.ReconcileProducerAssignments

  @group %{
    partition: "default",
    agent_ids: [],
    static_targets: ["192.0.2.0/24"],
    target_query: nil,
    ports: [443],
    sweep_modes: ["icmp"],
    overrides: %{},
    profile_id: nil,
    name: "group",
    interval: "15m",
    enabled: true
  }

  describe "plan/2" do
    test "leaves the fence alone when nothing that authorizes a target changed" do
      assert ReconcileProducerAssignments.plan(@group, %{
               @group
               | name: "renamed",
                 interval: "5m",
                 enabled: false
             }) == :none
    end

    for {field, value} <- [
          partition: "edge-2",
          static_targets: ["198.51.100.0/24"],
          target_query: "in:devices",
          ports: [22],
          sweep_modes: ["tcp"],
          overrides: %{"timeout" => "5s"},
          profile_id: "0192a4a0-0000-7000-8000-000000000001"
        ] do
      test "a change of #{field} fences every agent" do
        assert ReconcileProducerAssignments.plan(@group, %{
                 @group
                 | unquote(field) => unquote(Macro.escape(value))
               }) ==
                 {:fence, :all}
      end
    end

    test "selecting exact agents fences them and names who stays" do
      assert ReconcileProducerAssignments.plan(@group, %{
               @group
               | agent_ids: ["agent-a", "agent-b"]
             }) ==
               {:fence, ["agent-a", "agent-b"]}
    end

    test "going back to every agent in the partition revokes nobody" do
      assert ReconcileProducerAssignments.plan(%{@group | agent_ids: ["agent-a"]}, @group) ==
               {:fence, :all}
    end
  end
end
