defmodule ServiceRadar.SNMPProfiles.Changes.EncryptCredentials do
  @moduledoc """
  Writes the inline SNMP credentials of a resource that declares
  `ServiceRadar.SNMPProfiles.CredentialDsl.credential_action_arguments/0`.

  Each credential is write-only and stored encrypted (Cloak/AES-256-GCM):

  - `community` -> `community_encrypted` (SNMPv1/v2c)
  - `auth_password` -> `auth_password_encrypted` (SNMPv3)
  - `priv_password` -> `priv_password_encrypted` (SNMPv3)

  For each of those fields an action call does exactly one of three things:

  - **set**: a non-blank value replaces the stored one.
  - **keep**: no value leaves the stored one alone. A blank string counts as no
    value, because Ash's `:string` type casts `""` to `nil` before any change
    sees it, so blank can never mean "clear".
  - **clear**: naming the field in `clear_credentials` removes the stored value.
    Setting and clearing the same field in one call is rejected.

  A call that binds a reusable credential (changes `credential_secret_id` to a
  non-nil value) clears all three. `CredentialResolver` takes the broker path
  whenever a credential is bound and never reads inline material, so keeping it
  would leave a secret nothing uses, which unbinding would silently put back
  into service. Inline values supplied in that same call are rejected for the
  same reason.

  Only the call's own inputs are read, never the stored row, so the change
  behaves the same whether the update runs atomically or not.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Vault

  @fields [
    community: :community_encrypted,
    auth_password: :auth_password_encrypted,
    priv_password: :priv_password_encrypted
  ]

  @doc "The inline credential fields that `clear_credentials` accepts."
  def clearable_fields, do: Keyword.keys(@fields)

  @impl true
  def change(changeset, _opts, _context) do
    case build_payload(changeset) do
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
    case build_payload(changeset) do
      {:ok, payload} ->
        {:atomic, payload}

      {:error, {field, message}} ->
        {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
    end
  end

  defp build_payload(changeset) do
    cleared = MapSet.new(Ash.Changeset.get_argument(changeset, :clear_credentials) || [])
    binding? = binds_reusable_credential?(changeset)

    Enum.reduce_while(@fields, {:ok, %{}}, fn {field, encrypted_field}, {:ok, payload} ->
      value = Ash.Changeset.get_argument(changeset, field)

      case field_payload(value, MapSet.member?(cleared, field), binding?) do
        :keep -> {:cont, {:ok, payload}}
        {:ok, stored} -> {:cont, {:ok, Map.put(payload, encrypted_field, stored)}}
        {:error, message} -> {:halt, {:error, {field, message}}}
      end
    end)
  end

  defp field_payload(nil, false = _clear?, false = _binding?), do: :keep
  defp field_payload(nil, _clear?, _binding?), do: {:ok, nil}

  defp field_payload(_value, true = _clear?, _binding?),
    do: {:error, "cannot be both set and listed in clear_credentials"}

  defp field_payload(_value, false = _clear?, true = _binding?),
    do: {:error, "cannot be stored on this record while a reusable credential is selected"}

  defp field_payload(value, false = _clear?, false = _binding?) when is_binary(value) do
    case Vault.encrypt(value) do
      {:ok, encrypted} -> {:ok, encrypted}
      {:error, _reason} -> {:error, "Failed to encrypt credential"}
    end
  end

  # A literal input lands in `changeset.attributes` on both the atomic and the
  # non-atomic path. Re-sending the id already stored is not a change, so it
  # does not count as binding.
  defp binds_reusable_credential?(changeset) do
    case Ash.Changeset.fetch_change(changeset, :credential_secret_id) do
      {:ok, secret_id} -> not is_nil(secret_id)
      :error -> false
    end
  end
end
