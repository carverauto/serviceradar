defmodule ServiceRadarWebNG.Mcp.OAuth.Pkce do
  @moduledoc false

  @spec challenge_s256(String.t()) :: String.t()
  def challenge_s256(verifier) when is_binary(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  @spec valid_s256?(String.t(), String.t()) :: boolean()
  def valid_s256?(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    Plug.Crypto.secure_compare(challenge_s256(verifier), challenge)
  end

  def valid_s256?(_, _), do: false
end
