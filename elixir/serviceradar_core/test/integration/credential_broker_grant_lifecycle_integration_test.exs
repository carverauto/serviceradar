defmodule ServiceRadar.Credentials.CredentialBrokerGrantLifecycleIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "agent broker resolution expires stale grants and emits a lifecycle event" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "expired-grant-secret-#{unique}",
          provider: "test",
          credential_kind: :api_token,
          source_type: :internal_encrypted,
          secret_payload: "token-value-#{unique}",
          metadata: %{"test" => "credential_broker_grant_lifecycle"}
        },
        actor: actor
      )

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(-60, :second)
      |> DateTime.truncate(:second)

    {:ok, grant} =
      CredentialBrokerGrant.issue_grant(
        CredentialBrokerGrant.issue_attrs(%{
          secret_id: secret.id,
          grant_type: "integration_test",
          consumer_kind: :device_task,
          consumer_id: "task-#{unique}",
          purpose: "device-task-api-call",
          target_kind: "device",
          target_id: "device-#{unique}",
          agent_id: "agent-#{unique}",
          resolution_location: :agent,
          ttl_seconds: 1,
          expires_at: expires_at
        }),
        actor: actor
      )

    assert {:error, :grant_expired} =
             AgentGatewaySync.resolve_credential_broker_grant(%{
               "agent_id" => grant.agent_id,
               "grant_id" => grant.id,
               "credential_secret_ref" => grant.secret_ref,
               "consumer_kind" => "device_task",
               "consumer_id" => grant.consumer_id,
               "purpose" => grant.purpose
             })

    assert {:ok, expired_grant} = CredentialBrokerGrant.get_by_id(grant.id, actor: actor)
    assert expired_grant.status == :expired

    assert Enum.any?(credential_broker_grant_events(actor, grant.id), fn event ->
             event.log_name == "credential.broker_grant.lifecycle" and
               get_in(event.unmapped || %{}, ["event_family"]) ==
                 "credential_broker_grant_lifecycle" and
               get_in(event.unmapped || %{}, ["credential_broker_grant_id"]) ==
                 to_string(grant.id) and
               get_in(event.unmapped || %{}, ["action"]) == "expire" and
               get_in(event.unmapped || %{}, ["status"]) == "expired"
           end)
  end

  defp credential_broker_grant_events(actor, grant_id) do
    OcsfEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read!(actor: actor)
    |> Enum.filter(fn event ->
      get_in(event.unmapped || %{}, ["credential_broker_grant_id"]) == to_string(grant_id)
    end)
  end
end
