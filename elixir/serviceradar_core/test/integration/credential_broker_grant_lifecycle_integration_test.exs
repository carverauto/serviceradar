defmodule ServiceRadar.Credentials.CredentialBrokerGrantLifecycleIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

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
          inject: %{
            "type" => "http_header",
            "name" => "Authorization",
            "scheme" => "Bearer"
          },
          metadata: %{"controller_id" => "awx-#{unique}"},
          ttl_seconds: 1,
          expires_at: expires_at
        }),
        actor: actor
      )

    assert %{rows: [[action_inputs]]} =
             Repo.query!(
               """
               SELECT version_action_inputs
               FROM platform.credential_broker_grant_versions
               WHERE version_source_id = ($1::text)::uuid
                 AND version_action_name = 'issue'
               ORDER BY version_inserted_at DESC
               LIMIT 1
               """,
               [grant.id]
             )

    assert get_in(action_inputs, ["inject", "scheme"]) == "Bearer"
    assert get_in(action_inputs, ["metadata", "controller_id"]) == "awx-#{unique}"

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

    events = credential_broker_grant_events(actor, grant.id)
    actions = Enum.map(events, &get_in(&1.unmapped || %{}, ["action"]))

    refute "issue" in actions

    assert Enum.any?(events, fn event ->
             event.log_name == "credential.broker_grant.lifecycle" and
               get_in(event.unmapped || %{}, ["event_family"]) ==
                 "credential_broker_grant_lifecycle" and
               get_in(event.unmapped || %{}, ["credential_broker_grant_id"]) ==
                 to_string(grant.id) and
               get_in(event.unmapped || %{}, ["action"]) == "expire" and
               get_in(event.unmapped || %{}, ["status"]) == "expired"
           end)
  end

  test "resolve_with_grant resolves the secret named by a grant that carries only a reference" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])

    secret =
      CredentialIntegrationFixtures.secret!(
        actor: actor,
        secret_payload: "token-from-ref-#{unique}"
      )

    grant = %{
      id: "grant-#{unique}",
      secret_ref: SecretRefs.network_credential_ref(to_string(secret.id)),
      status: :issued,
      resolution_location: :agent,
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    assert {:ok, resolved} = SecretBroker.resolve_with_grant(grant, actor: actor)
    assert resolved.value == "token-from-ref-#{unique}"
  end

  test "resolve_with_grant refuses scope mismatch and inactive grants" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])

    secret =
      CredentialIntegrationFixtures.secret!(
        actor: actor,
        secret_payload: "scoped-token-#{unique}"
      )

    grant = %{
      id: "grant-#{unique}",
      secret_id: to_string(secret.id),
      status: :active,
      consumer_kind: :device_task,
      consumer_id: "task-#{unique}",
      purpose: "device-task-api-call",
      target_kind: "device",
      target_id: "device-#{unique}",
      resolution_location: :agent,
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    assert {:ok, resolved} =
             SecretBroker.resolve_with_grant(grant, actor: actor, target_id: grant.target_id)

    assert resolved.value == "scoped-token-#{unique}"

    assert {:error, {:grant_scope_mismatch, :target_id}} =
             SecretBroker.resolve_with_grant(grant,
               actor: actor,
               target_id: "device-other-#{unique}"
             )

    assert {:error, {:grant_not_active, :revoked}} =
             SecretBroker.resolve_with_grant(%{grant | status: :revoked},
               actor: actor,
               target_id: grant.target_id
             )
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
