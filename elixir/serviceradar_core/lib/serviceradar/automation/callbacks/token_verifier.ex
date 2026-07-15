defmodule ServiceRadar.Automation.Callbacks.TokenVerifier do
  @moduledoc """
  Derives non-replayable, pepper-versioned HMAC verifiers for callback bearers.

  The pepper is deployment secret material and is never stored beside the
  verifier. Persisting a plain token or an unkeyed token hash is intentionally
  unsupported.
  """

  @digest :sha256

  @spec derive(binary(), binary(), String.t()) ::
          {:ok, %{verifier: binary(), pepper_version: String.t()}} | {:error, :invalid_input}
  def derive(token, pepper, pepper_version)
      when is_binary(token) and byte_size(token) >= 32 and is_binary(pepper) and
             byte_size(pepper) >= 32 and
             is_binary(pepper_version) and pepper_version != "" do
    {:ok,
     %{
       verifier: :crypto.mac(:hmac, @digest, pepper, token),
       pepper_version: pepper_version
     }}
  end

  def derive(_token, _pepper, _pepper_version), do: {:error, :invalid_input}

  @spec matches?(binary(), binary(), binary()) :: boolean()
  def matches?(token, pepper, expected_verifier)
      when is_binary(token) and is_binary(pepper) and is_binary(expected_verifier) do
    actual = :crypto.mac(:hmac, @digest, pepper, token)

    byte_size(actual) == byte_size(expected_verifier) and
      :crypto.hash_equals(actual, expected_verifier)
  end

  def matches?(_token, _pepper, _expected_verifier), do: false
end
