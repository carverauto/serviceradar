defmodule ServiceRadar.Credentials.SecretBrokerExternalResolutionDbTest.LeasedAdapter do
  @moduledoc false

  def resolve(reference, _provider, opts) do
    {:ok,
     %{
       value: get_in(reference, [:metadata, "stub_secret_value"]) || "leased-secret",
       cache_status: :miss,
       lease_expires_at: Keyword.get(opts, :lease_expires_at)
     }}
  end
end

defmodule ServiceRadar.Credentials.SecretBrokerExternalResolutionDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Credentials.SecretBrokerExternalResolutionDbTest.LeasedAdapter

  @moduletag :integration

  @actor SystemActor.system(:secret_broker_external_resolution_db_test)

  test "resolve_with_grant resolves an external reference through the stub adapter" do
    unique = System.unique_integer([:positive])
    sentinel = "example-db-password-#{unique}"
    provider = enabled_provider!(:stub, [:agent], unique)
    secret = external_secret!(provider, unique, metadata: %{"stub_secret_value" => sentinel})

    assert {:ok, resolved} =
             SecretBroker.resolve_with_grant(active_grant(secret), actor: @actor)

    assert resolved.source_type == :external_reference
    assert resolved.value == sentinel
    assert resolved.provider.id == provider.id
    assert resolved.cache_status == :disabled
    assert resolved.metadata == %{"adapter" => "stub"}
  end

  test "public entry points discard a caller-supplied grant for a stored external secret" do
    unique = System.unique_integer([:positive])
    provider = enabled_provider!(:stub, [:agent], unique)
    secret = external_secret!(provider, unique)
    loaded = load_secret!(secret.id)
    grant = active_grant(secret)

    assert {:error, :external_secret_requires_broker_grant} =
             SecretBroker.resolve_network_credential_secret(secret.id,
               actor: @actor,
               grant: grant,
               resolution_location: :agent
             )

    assert {:error, :external_secret_requires_broker_grant} =
             SecretBroker.resolve_loaded_secret(loaded,
               actor: @actor,
               provider: provider,
               grant: grant,
               resolution_location: :agent
             )
  end

  test "resolve_with_grant fails closed when the provider has no adapter" do
    unique = System.unique_integer([:positive])
    provider = enabled_provider!(:delinea, [:control_plane], unique)

    secret =
      external_secret!(provider, unique, resolution_location: :control_plane)

    assert {:error, :adapter_unavailable} =
             SecretBroker.resolve_with_grant(
               active_grant(secret, resolution_location: :control_plane),
               actor: @actor
             )
  end

  test "resolve_with_grant caps the provider lease at the grant expiry" do
    now = ~U[2026-05-21 12:00:00Z]
    grant_expires_at = ~U[2026-05-21 12:05:00Z]
    unique = System.unique_integer([:positive])
    provider = enabled_provider!(:stub, [:agent], unique)
    secret = external_secret!(provider, unique)

    assert {:ok, resolved} =
             SecretBroker.resolve_with_grant(
               active_grant(secret, expires_at: grant_expires_at),
               actor: @actor,
               adapter: LeasedAdapter,
               now: now,
               lease_expires_at: ~U[2026-05-21 12:10:00Z]
             )

    assert resolved.lease_expires_at == grant_expires_at
  end

  test "resolve_with_grant rejects an expired provider lease" do
    now = ~U[2026-05-21 12:00:00Z]
    unique = System.unique_integer([:positive])
    provider = enabled_provider!(:stub, [:agent], unique)
    secret = external_secret!(provider, unique)

    assert {:error, :provider_lease_expired} =
             SecretBroker.resolve_with_grant(
               active_grant(secret, expires_at: ~U[2026-05-21 12:05:00Z]),
               actor: @actor,
               adapter: LeasedAdapter,
               now: now,
               lease_expires_at: ~U[2026-05-21 11:59:00Z]
             )
  end

  defp enabled_provider!(provider_type, locations, unique) do
    {:ok, provider} =
      CredentialSecretProvider.create_provider(
        %{
          name: "broker-ext-#{provider_type}-#{unique}",
          provider_type: provider_type,
          resolution_locations: locations
        },
        actor: @actor
      )

    {:ok, provider} =
      provider
      |> Ash.Changeset.for_update(:enable, %{}, actor: @actor)
      |> Ash.update(actor: @actor)

    provider
  end

  defp external_secret!(provider, unique, opts \\ []) do
    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "broker-ext-secret-#{unique}",
          provider: "example",
          credential_kind: :api_token,
          source_type: :external_reference,
          secret_provider_id: provider.id,
          external_secret_ref: "secret/data/example/#{unique}",
          resolution_location: Keyword.get(opts, :resolution_location, :agent),
          metadata: Keyword.get(opts, :metadata, %{})
        },
        actor: @actor
      )

    secret
  end

  defp load_secret!(secret_id) do
    {:ok, secret} = NetworkCredentialSecret.get_secret_by_id(secret_id, actor: @actor)
    secret
  end

  defp active_grant(secret, opts \\ []) do
    %{
      id: "grant-#{System.unique_integer([:positive])}",
      secret_id: to_string(secret.id),
      status: :active,
      consumer_kind: :plugin,
      resolution_location: Keyword.get(opts, :resolution_location, :agent),
      expires_at: Keyword.get(opts, :expires_at, DateTime.shift(DateTime.utc_now(), minute: 5))
    }
  end
end
