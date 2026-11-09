defmodule ServiceRadarAgentGateway.EdgeRecoveryControlTest do
  use ExUnit.Case, async: false

  alias Monitoring.EdgeRecoveryQuery
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.EdgeRecoveryControl
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory

  @recovery_id <<17::48, 7::4, 0::12, 2::2, 17::62>>
  @foreign_scope <<18::48, 7::4, 0::12, 2::2, 18::62>>

  setup do
    keys = Factory.keypair()
    :ok = EdgeRecordTrust.install(Factory.trust_document(keys.public))
    on_exit(&EdgeRecordTrust.clear/0)
    :ok
  end

  test "query cannot substitute a foreign scope or caller-supplied scope membership" do
    query = %EdgeRecoveryQuery{network_scope_id: @foreign_scope, recovery_id: @recovery_id}

    identity = %{
      component_type: :agent,
      component_id: "agent-1",
      network_scope_ids: MapSet.new([@foreign_scope])
    }

    assert {:error, :permission_denied, _} = EdgeRecoveryControl.get(query, identity)
  end

  test "recovery requires an agent principal bound in the installed trust snapshot" do
    query = %EdgeRecoveryQuery{network_scope_id: Factory.network_scope_id(), recovery_id: @recovery_id}

    for identity <- [
          %{component_type: :gateway, component_id: "agent-1"},
          %{component_type: :agent, component_id: "synthetic-unbound-agent"},
          %{}
        ] do
      assert {:error, :permission_denied, _} = EdgeRecoveryControl.get(query, identity)
    end
  end

  test "unavailable trust cannot authorize a recovery query" do
    EdgeRecordTrust.clear()
    query = %EdgeRecoveryQuery{network_scope_id: Factory.network_scope_id(), recovery_id: @recovery_id}

    assert {:error, :unavailable, _} =
             EdgeRecoveryControl.get(query, %{component_type: :agent, component_id: "agent-1"})
  end
end
