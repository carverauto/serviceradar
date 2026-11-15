defmodule ServiceRadarAgentGateway.CredentialGrantResponseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Logging.ConsoleFormatter
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

  test "formats binding-mode denial warning with failure_code, failure_kind, assignment_id, and binding_id" do
    log =
      capture_log(
        [
          level: :warning,
          format: "$message $metadata\n",
          metadata: ConsoleFormatter.printed_keys()
        ],
        fn ->
          response =
            AgentGatewayServer.credential_grant_response(
              {:ok, {:error, :credential_binding_not_found}},
              "agent-1",
              "",
              assignment_id: "assign-1",
              binding_id: "proxmox-0123456789abcdef0123456789abcdef"
            )

          refute response.success
        end
      )

    assert log =~ "Credential broker grant resolution denied"
    assert log =~ "agent_id=agent-1"
    assert log =~ "assignment_id=assign-1"
    assert log =~ "binding_id=proxmox-0123456789abcdef0123456789abcdef"
    assert log =~ "failure_code=credential_binding_not_found"
    assert log =~ "failure_kind=atom"

    formatted =
      %{
        level: :warning,
        msg: {:string, "Credential broker grant resolution denied"},
        meta: %{
          agent_id: "agent-1",
          assignment_id: "assign-1",
          binding_id: "proxmox-0123456789abcdef0123456789abcdef",
          failure_code: "credential_binding_not_found",
          failure_kind: "atom"
        }
      }
      |> ConsoleFormatter.format(%{})
      |> IO.iodata_to_binary()

    assert formatted =~ "agent_id=agent-1"
    assert formatted =~ "assignment_id=assign-1"
    assert formatted =~ "binding_id=proxmox-0123456789abcdef0123456789abcdef"
    assert formatted =~ "failure_code=credential_binding_not_found"
    assert formatted =~ "failure_kind=atom"
  end
end
