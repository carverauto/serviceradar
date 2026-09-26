defmodule ServiceRadar.Credentials.CredentialRedactor do
  @moduledoc """
  Redacts credential material before values are logged, returned, or cached.

  Secret references are intentionally preserved under any sensitive key, except
  `external_secret_ref`, because agents need them to resolve scoped material
  through the authenticated secret path. Plaintext tokens, passwords,
  passphrases, private keys, and encrypted payload fields are replaced with a
  stable redaction marker.

  Bare keys such as `token`, `secret`, `client_secret`, `authorization` and
  `api_key` are redacted only when the value is a binary, map or list, so
  manifest booleans and `nil` placeholders pass through unchanged.

  Callers use `redact(x) == x` as a "safe to transmit or persist" gate, so a key
  added here also starts refusing payloads at those gates.
  """

  @redacted "REDACTED"

  # Matched as whole key names (after downcasing and folding "-" to "_"), never
  # as substrings: "secret" and "token" are fragments of keys that carry no
  # material at all, such as `secret_id`, `secret_ref` and `token_path`.
  @exact_sensitive_keys ~w(
    token access_token refresh_token id_token auth_token bearer bearer_token
    secret client_secret authorization api_key apikey x_api_key
  )
  @version "serviceradar_credential_redactor_v1"

  @spec version() :: String.t()
  def version, do: @version

  @spec redact(term()) :: term()
  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, redact_entry(normalize_key(key), nested)} end)
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

  defp redact_entry("external_secret_ref", _nested), do: @redacted

  defp redact_entry(key, nested) do
    cond do
      # A reference is how material is meant to travel; it is not the material.
      secret_ref_value?(nested) -> nested
      sensitive_key?(key) -> @redacted
      key in @exact_sensitive_keys and material_value?(nested) -> @redacted
      true -> redact(nested)
    end
  end

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.replace("-", "_")
  end

  # A manifest's `secret: true` or a `token: nil` placeholder is not material.
  defp material_value?(value), do: is_binary(value) or is_map(value) or is_list(value)

  defp secret_ref_value?(value) when is_binary(value), do: secret_ref?(value)
  defp secret_ref_value?(_value), do: false

  defp sensitive_key?(normalized) do
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
