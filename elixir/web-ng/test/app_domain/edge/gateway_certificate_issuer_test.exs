defmodule ServiceRadarWebNG.Edge.GatewayCertificateIssuerTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Edge.GatewayCertificateIssuer

  defmodule IssueProbe do
    @moduledoc false
    def issue_agent_bundle(_component_id, _partition_id, :agent, _opts), do: {:error, :ca_not_available}
  end

  defmodule RevokeProbe do
    @moduledoc false
    @table __MODULE__

    def reset do
      ensure_table()
      :ets.delete_all_objects(@table)
    end

    def revoke_component_id(component_id, opts) do
      ensure_table()
      :ets.insert(@table, {:last_revoke, {component_id, opts}})
      :ok
    end

    def last_revoke do
      ensure_table()

      case :ets.lookup(@table, :last_revoke) do
        [{:last_revoke, value}] -> value
        [] -> nil
      end
    end

    defp ensure_table do
      case :ets.info(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public])
        _info -> @table
      end
    end
  end

  setup do
    RevokeProbe.reset()
    :ok
  end

  test "falls back to GatewayTracker when GatewayRegistry lookup is empty" do
    gateway_id = "tracker-gateway-#{System.unique_integer([:positive])}"

    ServiceRadar.GatewayTracker.register(gateway_id, %{
      node: Node.self(),
      partition: "default",
      domain: "default",
      status: :available
    })

    on_exit(fn ->
      ServiceRadar.GatewayTracker.unregister(gateway_id)
    end)

    assert {:error, :ca_not_available} =
             GatewayCertificateIssuer.issue_agent_bundle(
               gateway_id,
               "test-agent",
               "default",
               cert_issuer_module: IssueProbe
             )
  end

  test "revokes agent certificates on the selected gateway" do
    gateway_id = "revoke-gateway-#{System.unique_integer([:positive])}"
    component_id = "agent-revoked-#{System.unique_integer([:positive])}"

    ServiceRadar.GatewayTracker.register(gateway_id, %{
      node: Node.self(),
      partition: "default",
      domain: "default",
      status: :available
    })

    on_exit(fn ->
      ServiceRadar.GatewayTracker.unregister(gateway_id)
    end)

    assert {:ok, result} =
             GatewayCertificateIssuer.revoke_agent_certificate(gateway_id, component_id,
               reason: "compromised",
               revocation_module: RevokeProbe
             )

    assert result.revoked
    assert result.gateway_id == gateway_id
    assert result.component_id == component_id
    assert {^component_id, [reason: "compromised"]} = RevokeProbe.last_revoke()
  end
end
