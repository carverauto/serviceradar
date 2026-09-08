defmodule ServiceRadarAgentGateway.CredentialGrantResponseTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.AgentGatewayServer

  test "maps double-wrapped core success into resolved credential response" do
    response =
      AgentGatewayServer.credential_grant_response(
        {:ok,
         {:ok,
          %{
            value: "token-value",
            fields: %{"username" => "svc", "password" => "secret"},
            source_type: "external_reference",
            lease_expires_at_unix: 1_779_225_600,
            cache_status: "miss"
          }}},
        "agent-1",
        "grant-1"
      )

    assert %Monitoring.CredentialBrokerResolveResponse{} = response
    assert response.success
    assert response.value == "token-value"
    assert response.fields == %{"username" => "svc", "password" => "secret"}
    assert response.source_type == "external_reference"
    assert response.lease_expires_at_unix == 1_779_225_600
    assert response.cache_status == "miss"
  end

  test "maps double-wrapped core denial into denied response" do
    response =
      AgentGatewayServer.credential_grant_response(
        {:ok, {:error, :grant_expired}},
        "agent-1",
        "grant-1"
      )

    assert %Monitoring.CredentialBrokerResolveResponse{} = response
    refute response.success
    assert response.message == "credential grant resolution denied"
  end

  test "maps core unavailable into denied response" do
    response =
      AgentGatewayServer.credential_grant_response(
        {:error, :core_unavailable},
        "agent-1",
        "grant-1"
      )

    assert %Monitoring.CredentialBrokerResolveResponse{} = response
    refute response.success
    assert response.message == "credential grant resolution denied"
  end
end
