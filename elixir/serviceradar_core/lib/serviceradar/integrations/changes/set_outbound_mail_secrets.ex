defmodule ServiceRadar.Integrations.Changes.SetOutboundMailSecrets do
  @moduledoc """
  Encrypts outbound mail credentials supplied through action arguments.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Vault

  @impl true
  def change(changeset, _opts, _context) do
    case encrypted_payload(changeset) do
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
    case encrypted_payload(changeset) do
      {:ok, payload} ->
        {:atomic, payload}

      {:error, {field, message}} ->
        {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
    end
  end

  defp encrypted_payload(changeset) do
    with {:ok, payload} <- encrypt_secret(changeset, :password, :encrypted_password, %{}) do
      encrypt_secret(changeset, :api_key, :encrypted_api_key, payload)
    end
  end

  defp encrypt_secret(changeset, arg, encrypted_attr, payload) do
    clear_arg = :"clear_#{arg}"

    cond do
      Ash.Changeset.get_argument(changeset, clear_arg) ->
        {:ok, Map.put(payload, encrypted_attr, nil)}

      value = normalized_secret(Ash.Changeset.get_argument(changeset, arg)) ->
        case Vault.encrypt(value) do
          {:ok, encrypted} -> {:ok, Map.put(payload, encrypted_attr, encrypted)}
          {:error, _reason} -> {:error, {arg, "Failed to encrypt credential"}}
        end

      true ->
        {:ok, payload}
    end
  end

  defp normalized_secret(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalized_secret(_value), do: nil
end
