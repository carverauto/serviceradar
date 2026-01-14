defmodule ServiceRadar.SNMPProfiles.Changes.EncryptCredentials do
  @moduledoc """
  Encrypts SNMP credentials before storage using Cloak/AES-256-GCM.

  This change intercepts plaintext credential arguments and encrypts them:
  - `community` → `community_encrypted` (SNMPv1/v2c)
  - `auth_password` → `auth_password_encrypted` (SNMPv3)
  - `priv_password` → `priv_password_encrypted` (SNMPv3)

  All credentials are write-only - they cannot be read back in plaintext form.
  The UI should show masked placeholders for existing credentials.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Vault

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> encrypt_if_present(:community, :community_encrypted)
    |> encrypt_if_present(:auth_password, :auth_password_encrypted)
    |> encrypt_if_present(:priv_password, :priv_password_encrypted)
  end

  defp encrypt_if_present(changeset, plaintext_field, encrypted_field) do
    # Check if the plaintext credential was provided in the input arguments
    case Ash.Changeset.get_argument(changeset, plaintext_field) do
      nil ->
        # No change to this credential
        changeset

      "" ->
        # Empty value - clear the encrypted field
        Ash.Changeset.change_attribute(changeset, encrypted_field, nil)

      credential when is_binary(credential) ->
        # Encrypt and store
        case Vault.encrypt(credential) do
          {:ok, encrypted} ->
            Ash.Changeset.change_attribute(changeset, encrypted_field, encrypted)

          {:error, _reason} ->
            Ash.Changeset.add_error(changeset,
              field: plaintext_field,
              message: "Failed to encrypt credential"
            )
        end
    end
  end
end
