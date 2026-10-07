defmodule ServiceRadar.NATS.AgentFlowCollectorPermissionsTest do
  @moduledoc """
  Permission-shape parity tests for the Elixir mirror of the Go helper
  `GenerateAgentFlowCollectorCreds` in `go/pkg/cli/nats_bootstrap.go`.

  These tests are the Elixir half of the parity contract referenced by
  the B-5 design. If either side drifts (Go or Elixir), the byte-for-byte
  expectations below break and we re-align before the bundle generator
  can ship the wrong ACL.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.AgentFlowCollectorPermissions

  describe "safe_subject_token?/1" do
    test "accepts alnum, dash, and underscore" do
      assert AgentFlowCollectorPermissions.safe_subject_token?("agent-1")
      assert AgentFlowCollectorPermissions.safe_subject_token?("agent_1")
      assert AgentFlowCollectorPermissions.safe_subject_token?("AgentXYZ")
      assert AgentFlowCollectorPermissions.safe_subject_token?("123")
    end

    test "rejects characters that would break a NATS subject token" do
      refute AgentFlowCollectorPermissions.safe_subject_token?("")
      refute AgentFlowCollectorPermissions.safe_subject_token?("agent.with.dots")
      refute AgentFlowCollectorPermissions.safe_subject_token?("agent>")
      refute AgentFlowCollectorPermissions.safe_subject_token?("agent*")
      refute AgentFlowCollectorPermissions.safe_subject_token?("agent space")
      refute AgentFlowCollectorPermissions.safe_subject_token?("agent/slash")
      refute AgentFlowCollectorPermissions.safe_subject_token?(nil)
      refute AgentFlowCollectorPermissions.safe_subject_token?(:agent)
    end
  end

  describe "user_name/1" do
    test "matches the Go helper's flow-collector-<agent_id> shape" do
      assert AgentFlowCollectorPermissions.user_name("agent-42") == "flow-collector-agent-42"
    end
  end

  describe "permissions/1" do
    test "rejects unsafe agent ids before producing a permission map" do
      assert {:error, :invalid_agent_id} =
               AgentFlowCollectorPermissions.permissions("agent.with.dots")

      assert {:error, :invalid_agent_id} = AgentFlowCollectorPermissions.permissions("agent>")
      assert {:error, :invalid_agent_id} = AgentFlowCollectorPermissions.permissions("")
      assert {:error, :invalid_agent_id} = AgentFlowCollectorPermissions.permissions(nil)
    end

    test "publish_allow scopes data and stream management to the agent collector" do
      {:ok, perms} = AgentFlowCollectorPermissions.permissions("agent-42")

      assert perms.publish_allow == [
               "flow.host-slice.agent-42",
               "$JS.API.STREAM.INFO.flows",
               "$JS.API.STREAM.CREATE.flows",
               "$JS.API.STREAM.UPDATE.flows",
               "$JS.API.STREAM.INFO.events",
               "$JS.API.STREAM.UPDATE.events"
             ]

      # The other-agent slice and the publish wildcard for the slice
      # parent must never appear on the allow list.
      refute "flow.host-slice.>" in perms.publish_allow
      refute "flow.host-slice.agent-99" in perms.publish_allow
      refute "flow.attributed.>" in perms.publish_allow
    end

    test "publish_deny carries the wildcard fail-safe for $SYS and attributed flows" do
      {:ok, perms} = AgentFlowCollectorPermissions.permissions("agent-42")

      assert "$SYS.>" in perms.publish_deny
      assert "flow.attributed.>" in perms.publish_deny
    end

    test "subscribe scopes to inbox replies and the agent-specific config channel" do
      {:ok, perms} = AgentFlowCollectorPermissions.permissions("agent-42")

      assert perms.subscribe_allow == [
               "_INBOX.>",
               "config.flow-collector.agent-42.>"
             ]

      # Agents are publish-only on the slice; subscribe must not grant
      # them sight of any other agent's slice or any attributed-flow
      # subject.
      refute "flow.host-slice.>" in perms.subscribe_allow
      refute "flow.host-slice.agent-42" in perms.subscribe_allow
      refute "flow.attributed.>" in perms.subscribe_allow

      assert "$SYS.>" in perms.subscribe_deny
      assert "flow.host-slice.>" in perms.subscribe_deny
      assert "flow.attributed.>" in perms.subscribe_deny
    end

    test "allow_responses + max_responses match the Go helper" do
      {:ok, perms} = AgentFlowCollectorPermissions.permissions("agent-42")

      assert perms.allow_responses == true
      assert perms.max_responses == 16
    end

    test "different agents produce disjoint host-slice publish authority" do
      {:ok, a} = AgentFlowCollectorPermissions.permissions("agent-a")
      {:ok, b} = AgentFlowCollectorPermissions.permissions("agent-b")

      assert "flow.host-slice.agent-a" in a.publish_allow
      refute "flow.host-slice.agent-b" in a.publish_allow

      assert "flow.host-slice.agent-b" in b.publish_allow
      refute "flow.host-slice.agent-a" in b.publish_allow
    end
  end
end
