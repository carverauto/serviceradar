defmodule ServiceRadar.Credentials.StubProviderGateDbTest do
  # The gate is process-wide application config. This file stays serial so
  # turning it off cannot race another integration test that resolves :stub.
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Credentials.SecretProviderAdapters.Stub

  @moduletag :integration

  @gate :stub_secret_provider_enabled
  @actor SystemActor.system(:stub_provider_gate_db_test)

  setup do
    previous = Application.fetch_env(:serviceradar_core, @gate)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:serviceradar_core, @gate, value)
        :error -> Application.delete_env(:serviceradar_core, @gate)
      end
    end)
  end

  test "a stored :stub provider does not resolve while the gate is off" do
    unique = System.unique_integer([:positive])
    sentinel = "gate-sentinel-#{unique}"
    Application.put_env(:serviceradar_core, @gate, true)
    provider = enabled_stub_provider!(unique)
    secret = external_secret!(provider, unique, sentinel)
    grant = active_grant(secret)

    Application.put_env(:serviceradar_core, @gate, false)

    assert {:error, :adapter_unavailable} =
             SecretBroker.resolve_with_grant(grant, actor: @actor)

    assert {:ok, [denied | _]} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: @actor)

    assert denied.outcome == :failed
    assert denied.error_class == :adapter_unavailable

    # Naming the adapter explicitly does not get around the gate.
    assert {:error, :adapter_unavailable} =
             SecretBroker.resolve_with_grant(grant, actor: @actor, adapter: Stub)

    Application.put_env(:serviceradar_core, @gate, true)

    assert {:ok, %{value: ^sentinel}} =
             SecretBroker.resolve_with_grant(grant, actor: @actor)
  end

  defp enabled_stub_provider!(unique) do
    {:ok, provider} =
      CredentialSecretProvider.create_provider(
        %{
          name: "broker-stub-gate-#{unique}",
          provider_type: :stub,
          resolution_locations: [:control_plane]
        },
        actor: @actor
      )

    {:ok, provider} =
      provider
      |> Ash.Changeset.for_update(:enable, %{}, actor: @actor)
      |> Ash.update(actor: @actor)

    provider
  end

  defp external_secret!(provider, unique, sentinel) do
    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "broker-stub-gate-secret-#{unique}",
          provider: "example",
          credential_kind: :api_token,
          source_type: :external_reference,
          secret_provider_id: provider.id,
          external_secret_ref: "secret/data/example/gate/#{unique}",
          resolution_location: :control_plane,
          metadata: %{"stub_secret_value" => sentinel}
        },
        actor: @actor
      )

    secret
  end

  defp active_grant(secret) do
    %{
      id: "grant-#{System.unique_integer([:positive])}",
      secret_id: to_string(secret.id),
      status: :active,
      consumer_kind: :plugin,
      resolution_location: :control_plane,
      expires_at: DateTime.shift(DateTime.utc_now(), minute: 5)
    }
  end
end
