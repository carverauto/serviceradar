defmodule ServiceRadar.Credentials.ProxmoxApiToken do
  @moduledoc """
  The one place that knows the shape of a Proxmox VE API token.

  Proxmox authenticates `Authorization: PVEAPIToken=<user>@<realm>!<token>=<secret>`.
  A stored credential reaches that shape two ways: a package-manifest secret
  renders the whole `user@realm!token=secret` string as its payload, while an
  older secret stores only the bare secret and keeps `user@realm!token` in
  `metadata.token_id` (or `username`). Every consumer that hands token material
  to the agent or a plugin formats it here, so both shapes reach Proxmox the
  same way. A value is never logged.
  """

  @full_token ~r/\A[^@!=]+@[^@!=]+![^=]+=.+\z/s
  @token_id ~r/\A[^@!=]+@[^@!=]+![^=]+\z/
  @identity_fields ~w(user realm token_id)

  @doc "True when `secret` is a Proxmox API-token credential."
  @spec api_token_secret?(map() | struct() | nil) :: boolean()
  def api_token_secret?(secret) when is_map(secret) do
    Map.get(secret, :provider) == "proxmox" and
      Map.get(secret, :credential_kind) in [:api_token, "api_token"]
  end

  def api_token_secret?(_secret), do: false

  @doc "True for a complete `user@realm!token=secret` value."
  @spec full_token?(term()) :: boolean()
  def full_token?(value) when is_binary(value), do: Regex.match?(@full_token, value)
  def full_token?(_value), do: false

  @doc """
  Returns the `user@realm!token=secret` value for a stored payload.

  A payload that is already a complete token keeps its own token id, so a
  `username` holding only the user field can never replace it. A bare secret
  is joined with the secret's full token id. Anything else is returned
  unchanged rather than guessed at.
  """
  @spec format(map() | struct(), String.t()) :: String.t()
  def format(secret, payload) when is_binary(payload) do
    payload = payload |> String.trim() |> strip_header_prefix()

    cond do
      full_token?(payload) ->
        payload

      payload == "" ->
        payload

      token_id = full_token_id(secret) ->
        token_id <> "=" <> payload

      true ->
        payload
    end
  end

  @doc """
  Rejects manifest form input that cannot render a valid token.

  The `user`, `realm` and `token_id` fields are single segments of
  `user@realm!token`; an `@` or `!` typed into one of them (for example
  `serviceradar@pve` as the user) renders an identity Proxmox does not know.
  """
  @spec validate_form(map(), String.t()) ::
          :ok | {:error, {:invalid_credential_field, String.t()}}
  def validate_form(values, payload) when is_map(values) and is_binary(payload) do
    case Enum.find(@identity_fields, &segment_invalid?(Map.get(values, &1))) do
      nil ->
        if full_token?(payload), do: :ok, else: {:error, {:invalid_credential_field, "token_id"}}

      field ->
        {:error, {:invalid_credential_field, field}}
    end
  end

  defp segment_invalid?(value) when is_binary(value), do: String.contains?(value, ["@", "!", "="])
  defp segment_invalid?(_value), do: false

  defp strip_header_prefix("PVEAPIToken=" <> rest), do: rest
  defp strip_header_prefix(payload), do: payload

  defp full_token_id(secret) when is_map(secret) do
    metadata = Map.get(secret, :metadata) || %{}

    Enum.find_value(
      [Map.get(metadata, "token_id"), Map.get(metadata, :token_id), Map.get(secret, :username)],
      fn
        value when is_binary(value) ->
          value = String.trim(value)
          if Regex.match?(@token_id, value), do: value

        _value ->
          nil
      end
    )
  end

  defp full_token_id(_secret), do: nil
end
