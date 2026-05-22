defmodule ServiceRadar.Integrations.Changes.SetOutboundMailSecrets do
  @moduledoc """
  Encrypts outbound mail credentials supplied through action arguments.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> maybe_clear_secret(:password, :encrypted_password)
    |> maybe_clear_secret(:api_key, :encrypted_api_key)
    |> maybe_set_secret(:password)
    |> maybe_set_secret(:api_key)
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    {:atomic,
     %{}
     |> maybe_put_clear(changeset, :password, :encrypted_password)
     |> maybe_put_clear(changeset, :api_key, :encrypted_api_key)
     |> maybe_put_encrypted(changeset, :password, :encrypted_password)
     |> maybe_put_encrypted(changeset, :api_key, :encrypted_api_key)}
  end

  defp maybe_clear_secret(changeset, arg, encrypted_attr) do
    clear_arg = :"clear_#{arg}"

    if Ash.Changeset.get_argument(changeset, clear_arg) do
      Ash.Changeset.force_change_attribute(changeset, encrypted_attr, nil)
    else
      changeset
    end
  end

  defp maybe_set_secret(changeset, arg) do
    case normalized_secret(Ash.Changeset.get_argument(changeset, arg)) do
      nil -> changeset
      value -> AshCloak.encrypt_and_set(changeset, arg, value)
    end
  end

  defp maybe_put_clear(payload, changeset, arg, encrypted_attr) do
    if Ash.Changeset.get_argument(changeset, :"clear_#{arg}") do
      Map.put(payload, encrypted_attr, nil)
    else
      payload
    end
  end

  defp maybe_put_encrypted(payload, changeset, arg, encrypted_attr) do
    case normalized_secret(Ash.Changeset.get_argument(changeset, arg)) do
      nil -> payload
      value -> Map.put(payload, encrypted_attr, AshCloak.do_encrypt(changeset.resource, value))
    end
  end

  defp normalized_secret(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalized_secret(_value), do: nil
end
