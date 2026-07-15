defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Plugins.SecretRefs

  @controller_id "018f3f56-1111-7222-8333-123456789abc"
  @operation_id "018f3f56-1111-7222-8333-123456789abd"
  @execution_id "018f3f56-1111-7222-8333-123456789abe"
  @execution_secret "018f3f56-2222-7222-8333-123456789abc"
  @sync_secret "018f3f56-3333-7222-8333-123456789abc"

  test "persisted execution command accepts the exact execution secret and verb scope" do
    {attempt, execution, controller, request, payload} = fixture()

    assert Contract.persisted_payload_matches?(
             attempt,
             execution,
             controller,
             request,
             payload
           )

    widened_scope = put_in(payload, ["credential_broker", "allow", "paths"], ["/api/v2/"])

    refute Contract.persisted_payload_matches?(
             attempt,
             execution,
             controller,
             request,
             widened_scope
           )
  end

  test "legacy or sync credentials never satisfy an execution command" do
    {attempt, execution, controller, request, payload} = fixture()

    sync_payload =
      put_in(
        payload,
        ["credential_broker", "credential_secret_ref"],
        SecretRefs.network_credential_ref(@sync_secret)
      )

    refute Contract.persisted_payload_matches?(
             attempt,
             execution,
             controller,
             request,
             sync_payload
           )

    controller =
      controller
      |> Map.delete(:execution_credential_secret_id)
      |> Map.put(:credential_secret_id, @sync_secret)

    refute Contract.persisted_payload_matches?(
             attempt,
             execution,
             controller,
             request,
             payload
           )
  end

  defp fixture do
    controller = %{
      id: @controller_id,
      name: "farm01",
      base_url: "https://AWX.example.test:8443/",
      agent_id: "edge-agent-1",
      credential_secret_id: @sync_secret,
      sync_credential_secret_id: @sync_secret,
      execution_credential_secret_id: @execution_secret,
      callback_credential_secret_id: nil,
      metadata: %{}
    }

    attempt = %{
      operation_id: @operation_id,
      execution_id: @execution_id,
      controller_id: @controller_id,
      dispatch_agent_id: "edge-agent-1",
      stage: :fetch_job,
      purpose: :terminal_poll,
      command_type: "awx.fetch_job"
    }

    execution = %{id: @execution_id}
    request = %{job_id: 42}
    args = %{"job_id" => 42}
    {:ok, scope} = AwxClient.broker_scope(controller.base_url, attempt.command_type, args)

    broker = %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_id" => Ash.UUID.generate(),
      "grant_type" => "awx_oauth2_token",
      "credential_secret_ref" => SecretRefs.network_credential_ref(@execution_secret),
      "consumer" => %{
        "kind" => "ansible",
        "id" => @controller_id,
        "purpose" => attempt.command_type
      },
      "target" => %{
        "kind" => "awx_controller",
        "id" => @controller_id,
        "agent_id" => "edge-agent-1"
      },
      "resolution_location" => "agent",
      "inject" => %{
        "type" => "http_header",
        "name" => "Authorization",
        "scheme" => "Bearer"
      },
      "allow" => scope.allow,
      "ttl_seconds" => 300,
      "expires_at" => DateTime.utc_now() |> DateTime.add(300) |> DateTime.to_iso8601()
    }

    payload = %{
      "schema" => "serviceradar.awx_command.v1",
      "verb" => attempt.command_type,
      "args" => args,
      "base_url" => scope.base_url,
      "controller_id" => @controller_id,
      "controller_name" => controller.name,
      "insecure_skip_verify" => false,
      "credential_broker" => broker
    }

    {attempt, execution, controller, request, payload}
  end
end
