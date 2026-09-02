defmodule ServiceRadar.Credentials.CredentialRedactor do
  @moduledoc """
  Redacts credential material before values are logged, returned, or cached.

  Secret references are intentionally preserved because agents need them to
  resolve scoped material through the authenticated secret path. Plaintext
  tokens, passwords, passphrases, private keys, and encrypted payload fields are
  replaced with a stable redaction marker.
  """

  @redacted "REDACTED"
  @version "serviceradar_credential_redactor_v1"

  @spec version() :: String.t()
  def version, do: @version

  @spec redact(term()) :: term()
  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact(nested)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_binary(value) do
    cond do
      secret_ref?(value) -> value
      contains_secret_material?(value) -> @redacted
      true -> value
    end
  end

  def redact(value), do: value

  @spec redacted?(term()) :: boolean()
  def redacted?(value), do: redact(value) == @redacted

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.trim()

    cond do
      normalized == "external_secret_ref" ->
        true

      String.ends_with?(normalized, "_secret_ref") ->
        false

      normalized in ["credential_secret_ref", "api_token_secret_ref"] ->
        false

      # OAuth inject metadata: which form field names to fill, not secret values.
      # "field_password" contains "password" and would otherwise trip the
      # substring check and deny producer-schedule command transmit.
      String.starts_with?(normalized, "field_") ->
        false

      true ->
        Enum.any?(
          [
            "password",
            "passwd",
            "passphrase",
            "secret_payload",
            "encrypted_secret_payload",
            "provider_bootstrap",
            "provider_auth",
            "external_secret_ref",
            "api_token",
            "private_key",
            "credential_material"
          ],
          &String.contains?(normalized, &1)
        )
    end
  end

  defp contains_secret_material?(value) do
    String.contains?(value, "PVEAPIToken=") or ssh_private_key?(value)
  end

  defp ssh_private_key?(value) do
    String.contains?(value, "-----BEGIN ") and String.contains?(value, " PRIVATE KEY-----")
  end

  defp secret_ref?(value) do
    String.starts_with?(value, "secretref:") or
      String.starts_with?(value, "credentialref:network-credential-secret:") or
      String.starts_with?(value, "credentialref:network-credential-grant:")
  end
end
