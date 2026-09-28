defmodule ServiceRadar.Credentials.SecretBrokerAuditIntegrationTest do
  use ServiceRadar.DataCase, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker

  @moduletag :integration

  test "grant-driven location denials are audited with provider, grant and effective location" do
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
          external_secret_ref: "secret/data/broker-audit/#{unique}"
        },
        actor: actor
      )

    # The secret sets no resolution location of its own, so the agent location
    # the provider refuses can only come from the grant.
    grant = %{
      id: "grant-#{unique}",
      secret_id: to_string(secret.id),
      status: :active,
      consumer_kind: :plugin,
      consumer_id: "plugin-#{unique}",
      resolution_location: :agent,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    assert {:error, {:resolution_location_not_allowed, :agent}} =
             SecretBroker.resolve_with_grant(grant,
               actor: actor,
               audit?: true,
               consumer_kind: :plugin,
               consumer_id: "plugin-#{unique}"
             )

    assert {:ok, [audit | _]} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: actor)

    assert audit.secret_provider_id == provider.id
    assert audit.grant_id == "grant-#{unique}"
    assert audit.resolution_location == :agent
    assert audit.outcome == :failed
    assert audit.error_class == :provider_policy_denied
  end

  # Availability wins over the audit row (the caller still gets :ok), but a row
  # the resource rejects must leave a redacted warning and a telemetry event.
  test "an audit row the resource rejects is logged, never dropped silently" do
    actor = SystemActor.system(:secret_broker_audit_integration_test)
    unique = System.unique_integer([:positive])
    grant_id = "grant-rejected-audit-#{unique}"
    secret_id = Ecto.UUID.generate()

    log =
      capture_log(fn ->
        assert :ok =
                 SecretBroker.write_audit(%{
                   secret_id: secret_id,
                   grant_id: grant_id,
                   consumer_kind: :plugin,
                   resolution_location: :control_plane,
                   outcome: :denied,
                   error_class: :not_an_audit_error_class,
                   metadata: %{"password" => "sentinel-#{unique}"}
                 })
      end)

    # Logged, not telemetry-attached: an async module may not attach a global
    # handler (build/contracts/ci_heavy_gate_contract_test.py).
    assert log =~ "audit row was not written"
    assert log =~ grant_id
    assert log =~ ~s(rejected_fields=["error_class"])
    refute log =~ "sentinel-#{unique}"

    assert {:ok, []} = CredentialSecretResolutionAudit.list_for_secret(secret_id, actor: actor)
  end
end
