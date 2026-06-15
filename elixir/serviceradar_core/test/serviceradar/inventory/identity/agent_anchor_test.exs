defmodule ServiceRadar.Inventory.Identity.AgentAnchorTest do
  @moduledoc """
  Pure, DB-free coverage of the AgentAnchor safety contracts (DIRE).

  The behavioral, DB-backed paths (reciprocal `agent_id` ownership, the
  delegation to `AliasGuard.distinct_agent_identity_conflict?/3`) are
  exercised by the `:integration` suites in
  `agent_link_repair_worker_test.exs` and
  `identity_reconciler_merge_guard_test.exs`.

  These cases pin the "do no harm on ambiguity" defaults that hold WITHOUT
  any database — the guard-clause fall-throughs MUST return safe, non-
  destructive values (empty anchor set, no conflict, no sole anchor) so a
  malformed/empty agent uid can never trigger an auto-repoint. A wrong
  default here corrupts identity worse than the cruft the worker repairs.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.AgentAnchor

  describe "anchored_device_uids/2 safe defaults" do
    test "an empty agent uid yields no anchor (never a confident host)" do
      assert AgentAnchor.anchored_device_uids("", nil) == []
    end

    test "a non-binary agent uid yields no anchor" do
      assert AgentAnchor.anchored_device_uids(nil, nil) == []
    end
  end

  describe "conflicts_with_anchor?/3 do-no-harm defaults" do
    test "non-binary inputs are never treated as a conflict" do
      refute AgentAnchor.conflicts_with_anchor?(nil, "sr:device", nil)
      refute AgentAnchor.conflicts_with_anchor?("agent-1", nil, nil)
      refute AgentAnchor.conflicts_with_anchor?(nil, nil, nil)
    end

    test "an empty agent uid (no derivable anchor) is never a conflict" do
      refute AgentAnchor.conflicts_with_anchor?("", "sr:device", nil)
    end
  end

  describe "sole_anchor_device_uid/2 ambiguity defaults" do
    test "an empty agent uid has no sole anchor (leave + log)" do
      assert AgentAnchor.sole_anchor_device_uid("", nil) == nil
    end

    test "a non-binary agent uid has no sole anchor" do
      assert AgentAnchor.sole_anchor_device_uid(nil, nil) == nil
    end
  end
end
