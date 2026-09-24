defmodule ServiceRadar.Plugins.AssignmentOwnerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AssignmentOwner

  @rule_a "network-credential-rule:00000000-0000-4000-8000-00000000000a"
  @rule_a_drifted "network-credential-rule:00000000-0000-4000-8000-00000000000a:inventory"
  @rule_b "network-credential-rule:00000000-0000-4000-8000-00000000000b"

  test "derives the owner from the policy id" do
    assert AssignmentOwner.owner(nil) == :manual
    assert AssignmentOwner.owner("  ") == :manual
    assert AssignmentOwner.owner(@rule_a) == {:rule, "00000000-0000-4000-8000-00000000000a"}

    assert AssignmentOwner.owner(@rule_a_drifted) ==
             {:rule, "00000000-0000-4000-8000-00000000000a"}

    assert AssignmentOwner.owner("policy-OLD") == {:policy, "policy-OLD"}
  end

  test "assignments of different credential rules may coexist" do
    refute AssignmentOwner.conflict?(@rule_a, @rule_b)
    refute AssignmentOwner.same_owner?(@rule_a, @rule_b)
  end

  test "one rule's drifted policy id still conflicts with its own row" do
    assert AssignmentOwner.conflict?(@rule_a, @rule_a_drifted)
    assert AssignmentOwner.same_owner?(@rule_a_drifted, @rule_a)
  end

  test "manual rows and arbitrary policy ids keep the original one-assignment rule" do
    assert AssignmentOwner.conflict?(nil, @rule_a)
    assert AssignmentOwner.conflict?(@rule_a, nil)
    assert AssignmentOwner.conflict?(nil, nil)
    assert AssignmentOwner.conflict?("policy-OLD", "policy-NEW")
    assert AssignmentOwner.conflict?("policy-OLD", @rule_a)
  end
end
