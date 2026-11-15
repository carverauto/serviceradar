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
  different non-nil value) clears all three. `CredentialResolver` takes the
  broker path whenever a credential is bound and never reads inline material,
  so keeping it would leave a secret nothing uses, which unbinding would
  silently put back into service. Re-sending the id already stored is not a
  bind and clears nothing; use `clear_credentials` for an already-bound record.

  A call that supplies a non-nil `credential_secret_id`, changed or re-sent,
  cannot also supply an inline value, for the same reason.

  On the atomic path the stored id is not known up front, so the bind clear is
  an expression that compares the supplied id with the stored column.
  """

  use Ash.Resource.Change

  import Ash.Expr

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
        payload
        |> merge_bind_clears(binds_reusable_credential?(changeset), fn _encrypted_field -> nil end)
        |> Enum.reduce(changeset, fn {field, value}, acc ->
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
        secret_id = supplied_secret_id(changeset)

        {:atomic,
         merge_bind_clears(payload, not is_nil(secret_id), fn encrypted_field ->
           expr(
             if is_nil(credential_secret_id) or credential_secret_id != ^secret_id do
               nil
             else
               ^ref(encrypted_field)
             end
           )
         end)}

      {:error, {field, message}} ->
        {:ok, Ash.Changeset.add_error(changeset, field: field, message: message)}
    end
  end

  defp build_payload(changeset) do
    cleared = MapSet.new(Ash.Changeset.get_argument(changeset, :clear_credentials) || [])
    supplies_secret? = not is_nil(supplied_secret_id(changeset))

    Enum.reduce_while(@fields, {:ok, %{}}, fn {field, encrypted_field}, {:ok, payload} ->
      value = Ash.Changeset.get_argument(changeset, field)

      case field_payload(value, MapSet.member?(cleared, field), supplies_secret?) do
        :keep -> {:cont, {:ok, payload}}
        {:ok, stored} -> {:cont, {:ok, Map.put(payload, encrypted_field, stored)}}
        {:error, message} -> {:halt, {:error, {field, message}}}
      end
    end)
  end

  defp field_payload(nil, false = _clear?, _supplies_secret?), do: :keep
  defp field_payload(nil, true = _clear?, _supplies_secret?), do: {:ok, nil}

  defp field_payload(_value, true = _clear?, _supplies_secret?),
    do: {:error, "cannot be both set and listed in clear_credentials"}

  defp field_payload(_value, false = _clear?, true = _supplies_secret?),
    do: {:error, "cannot be stored on this record while a reusable credential is selected"}

  defp field_payload(value, false = _clear?, false = _supplies_secret?) when is_binary(value) do
    case Vault.encrypt(value) do
      {:ok, encrypted} -> {:ok, encrypted}
      {:error, _reason} -> {:error, "Failed to encrypt credential"}
    end
  end

  defp merge_bind_clears(payload, false = _binding?, _clear_value), do: payload

  defp merge_bind_clears(payload, true = _binding?, clear_value) do
    @fields
    |> Map.new(fn {_field, encrypted_field} ->
      {encrypted_field, clear_value.(encrypted_field)}
    end)
    |> Map.merge(payload)
  end

  # Ash drops an unchanged attribute from the changes on the non-atomic path,
  # so a re-sent id is not a bind.
  defp binds_reusable_credential?(changeset) do
    case Ash.Changeset.fetch_change(changeset, :credential_secret_id) do
      {:ok, secret_id} -> not is_nil(secret_id)
      :error -> false
    end
  end

  # The id this call supplies, whether or not it differs from the stored one.
  # The atomic rebuild carries accepted inputs as literal atomics.
  defp supplied_secret_id(changeset) do
    with :error <- Ash.Changeset.fetch_change(changeset, :credential_secret_id),
         :error <- Map.fetch(changeset.casted_attributes, :credential_secret_id),
         :error <- Keyword.fetch(changeset.atomics, :credential_secret_id) do
      nil
    else
      {:ok, secret_id} when is_binary(secret_id) -> secret_id
      {:ok, _not_a_literal_id} -> nil
    end
  end
end
