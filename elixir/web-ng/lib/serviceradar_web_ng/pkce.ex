defmodule ServiceRadarWebNG.Pkce do
  @moduledoc """
  RFC 7636 PKCE helpers shared by the upstream OIDC client and MCP OAuth.

  Only S256 is implemented. `plain` is intentionally unsupported.
  """

  @verifier_bytes 32

  @doc """
  Generates a 32-byte CSPRNG verifier encoded as base64url without padding
  (43 characters, unreserved alphabet).
  """
  @spec generate_verifier() :: String.t()
  def generate_verifier do
    @verifier_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  BASE64URL(SHA256(verifier)) without padding, per RFC 7636 section 4.2.
  """
  @spec challenge_s256(String.t()) :: String.t()
  def challenge_s256(verifier) when is_binary(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end
end
