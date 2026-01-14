defmodule ServiceRadar.SNMPProfiles.Changes.EncryptPasswords do
  @moduledoc """
  Encrypts SNMP authentication and privacy passwords before storage.

  This change intercepts the plaintext `auth_password` and `priv_password` virtual
  attributes, encrypts them using Cloak, and stores them in the `_encrypted` fields.

  Passwords are write-only - they cannot be read back in plaintext form.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Vault

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> encrypt_if_present(:auth_password, :auth_password_encrypted)
    |> encrypt_if_present(:priv_password, :priv_password_encrypted)
  end

  defp encrypt_if_present(changeset, plaintext_field, encrypted_field) do
    # Check if the plaintext password was provided in the input
    # Note: we need to check the arguments since passwords are virtual
    case Ash.Changeset.get_argument(changeset, plaintext_field) do
      nil ->
        changeset

      "" ->
        # Empty password - clear the encrypted field
        Ash.Changeset.change_attribute(changeset, encrypted_field, nil)

      password when is_binary(password) ->
        # Encrypt and store
        case Vault.encrypt(password) do
          {:ok, encrypted} ->
            Ash.Changeset.change_attribute(changeset, encrypted_field, encrypted)

          {:error, _reason} ->
            Ash.Changeset.add_error(changeset,
              field: plaintext_field,
              message: "Failed to encrypt password"
            )
        end
    end
  end
end
