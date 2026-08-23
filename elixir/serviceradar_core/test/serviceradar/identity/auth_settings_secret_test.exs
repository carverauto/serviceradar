defmodule ServiceRadar.Identity.AuthSettingsSecretTest do
  @moduledoc """
  Round-trip coverage for AshCloak-encrypted SSO secrets on AuthSettings.

  Regression: `maybe_encrypt_secret/3` previously called
  `Ash.Changeset.change_attribute/3` on `:oidc_client_secret_encrypted`, but
  AshCloak rewrites that attribute into a decrypt calculation backed by the
  `:encrypted_oidc_client_secret_encrypted` storage column, so the call raised
  `Ash.Error.Changes.NoSuchAttribute` and the SSO-config path never worked.
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthSettings

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  defp admin do
    %{id: "user:auth-admin", role: :admin, permissions: ["settings.auth.manage"]}
  end

  defp ensure_settings(actor) do
    case AuthSettings.get_settings(actor: actor) do
      {:ok, %AuthSettings{} = s} ->
        s

      _ ->
        case AuthSettings.create(%{mode: :password_only}, actor: actor) do
          {:ok, %AuthSettings{} = s} -> s
          other -> flunk("failed to create auth settings: #{inspect(other)}")
        end
    end
  end

  test "update encrypts the OIDC client secret and the decrypt calc round-trips it" do
    system = SystemActor.system(:auth_settings_secret_test_seed)
    settings = ensure_settings(system)
    actor = admin()

    secret = "oidc-client-secret-#{System.unique_integer([:positive])}"

    assert {:ok, %AuthSettings{} = updated} =
             AuthSettings.update(
               settings,
               %{
                 mode: :active_sso,
                 provider_type: :oidc,
                 oidc_client_id: "client-123",
                 oidc_client_secret: secret
               },
               actor: actor
             )

    # Ciphertext is persisted in the storage column, not the plaintext.
    assert is_binary(updated.encrypted_oidc_client_secret_encrypted)
    refute updated.encrypted_oidc_client_secret_encrypted == secret

    # The decrypt calculation (exposed as `oidc_client_secret_encrypted`) returns plaintext.
    assert AuthSettings.get_oidc_client_secret(updated) == secret

    # A fresh read (decrypt_by_default) round-trips without raising.
    assert {:ok, %AuthSettings{} = fetched} = AuthSettings.get_settings(actor: actor)
    assert AuthSettings.get_oidc_client_secret(fetched) == secret
  end

  test "empty string clears the encrypted OIDC client secret" do
    system = SystemActor.system(:auth_settings_secret_test_seed)
    _settings = ensure_settings(system)
    actor = admin()

    secret = "oidc-client-secret-#{System.unique_integer([:positive])}"

    {:ok, fetched} = AuthSettings.get_settings(actor: actor)

    assert {:ok, set} =
             AuthSettings.update(fetched, %{oidc_client_secret: secret}, actor: actor)

    assert AuthSettings.get_oidc_client_secret(set) == secret

    assert {:ok, cleared} =
             AuthSettings.update(set, %{oidc_client_secret: ""}, actor: actor)

    assert is_nil(cleared.encrypted_oidc_client_secret_encrypted)
    assert is_nil(AuthSettings.get_oidc_client_secret(cleared))
  end

  test "update encrypts the SAML private key and the decrypt calc round-trips it" do
    system = SystemActor.system(:auth_settings_secret_test_seed)
    settings = ensure_settings(system)
    actor = admin()

    key = "saml-private-key-#{System.unique_integer([:positive])}"

    assert {:ok, %AuthSettings{} = updated} =
             AuthSettings.update(settings, %{saml_private_key: key}, actor: actor)

    assert is_binary(updated.encrypted_saml_private_key_encrypted)
    refute updated.encrypted_saml_private_key_encrypted == key
    assert AuthSettings.get_saml_private_key(updated) == key

    assert {:ok, fetched} = AuthSettings.get_settings(actor: actor)
    assert AuthSettings.get_saml_private_key(fetched) == key
  end
end
