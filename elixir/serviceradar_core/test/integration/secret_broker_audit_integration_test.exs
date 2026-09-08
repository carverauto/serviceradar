defmodule ServiceRadar.Credentials.SecretBrokerAuditIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker

  @moduletag :integration

  test "failure audits keep loaded provider and effective resolution location" do
    actor = SystemActor.system(:secret_broker_audit_integration_test)
    unique = System.unique_integer([:positive])

    {:ok, provider} =
      CredentialSecretProvider.create_provider(
        %{
          name: "broker-audit-provider-#{unique}",
          provider_type: :stub,
          resolution_locations: [:control_plane]
        },
        actor: actor
      )

    {:ok, provider} =
      provider
      |> Ash.Changeset.for_update(:enable, %{}, actor: actor)
      |> Ash.update(actor: actor)

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "broker-audit-secret-#{unique}",
          provider: "stub",
          credential_kind: :api_token,
          source_type: :external_reference,
          secret_provider_id: provider.id,
          external_secret_ref: "secret/data/broker-audit/#{unique}",
          resolution_location: :agent
        },
        actor: actor
      )

    assert {:error, {:resolution_location_not_allowed, :agent}} =
             SecretBroker.resolve_network_credential_secret(secret.id,
               audit?: true,
               grant: %{
                 id: "grant-#{unique}",
                 secret_id: to_string(secret.id),
                 status: :active,
                 resolution_location: :agent,
                 expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
               },
               consumer_kind: :plugin,
               consumer_id: "plugin-#{unique}"
             )

    assert {:ok, [audit | _]} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: actor)

    assert audit.secret_provider_id == provider.id
    assert audit.resolution_location == :agent
    assert audit.outcome == :failed
    assert audit.error_class == :provider_policy_denied
  end
end
