defmodule ServiceRadar.Credentials.SshPrivateKeyCredential do
  @moduledoc """
  Public fingerprint for SSH private key credential material.

  `CredentialSecretBuilder` stores the fingerprint as the secret's
  `public_fingerprint`, so operators can tell keys apart without the private
  key ever leaving the encrypted payload.
  """

  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(private_key) when is_binary(private_key) do
    private_key
    |> normalize_private_key()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64(padding: false)
    |> then(&"SHA256:#{&1}")
  end

  defp normalize_private_key(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.trim()
  end
end
