defmodule ServiceRadarWebNG.Edge.GatewayCertificateIssuerTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Edge.GatewayCertificateIssuer
  alias ServiceRadarWebNG.TestSupport.PublishedMessages

  @moduletag :web_ng_shared_fixture_db

  defmodule IssueProbe do
    @moduledoc false
    @table __MODULE__

    def reset do
      ensure_table()
      :ets.delete_all_objects(@table)
    end

    def issue_agent_bundle(component_id, partition_id, :agent, opts) do
      ensure_table()
      :ets.insert(@table, {:last_issue, {component_id, partition_id, opts}})
      {:error, :ca_not_available}
    end

    def last_issue do
      ensure_table()

      case :ets.lookup(@table, :last_issue) do
        [{:last_issue, value}] -> value
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

  # Answers like ServiceRadarAgentGateway.CertIssuer after a successful mint:
  # the bundle carries the issuance audit record for the requesting node.
  defmodule MintProbe do
    @moduledoc false

    def issue_agent_bundle(component_id, partition_id, :agent, opts) do
      cn = "#{component_id}.#{partition_id}.serviceradar"

      {:ok,
       %{
         bundle_pem: "synthetic-bundle",
         cn: cn,
         certificate_fingerprint: "synthetic-fingerprint",
         issuance_audit: [
           action: :agent_certificate_issue,
           resource_type: "agent_certificate",
           resource_id: component_id,
           resource_name: cn,
           actor: Keyword.fetch!(opts, :audit_actor),
           details: %{component_id: component_id, certificate_fingerprint: "synthetic-fingerprint"},
           severity: :informational
         ]
       }}
    end
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
    IssueProbe.reset()
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
               cert_issuer_module: IssueProbe,
               authorized_component_id: "test-agent",
               authorized_partition_id: "default",
               actor: %{id: "operator-1", email: "operator@example.test"}
             )

    assert {"test-agent", "default", opts} = IssueProbe.last_issue()
    assert Keyword.fetch!(opts, :validity_days) == 90
    assert Keyword.fetch!(opts, :authorized_component_id) == "test-agent"
    assert Keyword.fetch!(opts, :authorized_partition_id) == "default"
    assert Keyword.fetch!(opts, :audit_actor) == %{id: "operator-1", email: "operator@example.test"}

    assert {:error, {:invalid_certificate_validity_days, 1}} =
             GatewayCertificateIssuer.issue_agent_bundle(
               gateway_id,
               "test-agent",
               "default",
               validity_days: 1,
               cert_issuer_module: IssueProbe
             )

    assert {:error, :ca_not_available} =
             GatewayCertificateIssuer.issue_agent_bundle(
               gateway_id,
               "test-agent",
               "default",
               cert_validity_days: 1,
               allow_short_test_lifetime: true,
               cert_issuer_module: IssueProbe
             )

    assert {"test-agent", "default", short_opts} = IssueProbe.last_issue()
    assert Keyword.fetch!(short_opts, :validity_days) == 1
    assert Keyword.fetch!(short_opts, :allow_short_test_lifetime)
  end

  test "publishes the audit record of a certificate the gateway minted" do
    gateway_id = "mint-gateway-#{System.unique_integer([:positive])}"
    component_id = "agent-minted-#{System.unique_integer([:positive])}"
    PublishedMessages.capture()

    ServiceRadar.GatewayTracker.register(gateway_id, %{
      node: Node.self(),
      partition: "default",
      domain: "default",
      status: :available
    })

    on_exit(fn ->
      ServiceRadar.GatewayTracker.unregister(gateway_id)
    end)

    assert {:ok, bundle} =
             GatewayCertificateIssuer.issue_agent_bundle(
               gateway_id,
               component_id,
               "default",
               cert_issuer_module: MintProbe,
               actor: %{id: "operator-1", email: "operator@example.test"}
             )

    refute Map.has_key?(bundle, :issuance_audit)

    audit = PublishedMessages.receive_audit_record(component_id)
    assert audit["unmapped"]["action"] == "agent_certificate_issue"
    assert audit["unmapped"]["resource_type"] == "agent_certificate"
    assert audit["unmapped"]["details"]["certificate_fingerprint"] == "synthetic-fingerprint"
    assert audit["actor"]["user"]["email_addr"] == "operator@example.test"
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
