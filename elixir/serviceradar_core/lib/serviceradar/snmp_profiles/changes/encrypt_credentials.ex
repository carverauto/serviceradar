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
    case build_encrypted_payload(changeset) do
      {:ok, payload} ->
        Enum.reduce(payload, changeset, fn {field, value}, acc ->
          Ash.Changeset.change_attribute(acc, field, value)
        end)

      {:error, {field, message}} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case build_encrypted_payload(changeset) do
      {:ok, payload} ->
        {:atomic, payload}

      {:error, {field, message}} ->
        {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
    end
  end

  defp build_encrypted_payload(changeset) do
    with {:ok, payload} <- encrypt_field(changeset, :community, :community_encrypted, %{}),
         {:ok, payload} <-
           encrypt_field(changeset, :auth_password, :auth_password_encrypted, payload),
         {:ok, payload} <-
           encrypt_field(changeset, :priv_password, :priv_password_encrypted, payload) do
      {:ok, payload}
    end
  end

  defp encrypt_field(changeset, plaintext_field, encrypted_field, payload) do
    case Ash.Changeset.get_argument(changeset, plaintext_field) do
      nil ->
        {:ok, payload}

      "" ->
        {:ok, Map.put(payload, encrypted_field, nil)}

      credential when is_binary(credential) ->
        case Vault.encrypt(credential) do
          {:ok, encrypted} ->
            {:ok, Map.put(payload, encrypted_field, encrypted)}

          {:error, _reason} ->
            {:error, {plaintext_field, "Failed to encrypt credential"}}
        end
    end
  end
end
