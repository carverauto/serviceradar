defmodule ServiceRadarWebNG.SigningSecret do
  @moduledoc """
  Boot-time check for the secrets web-ng signs sessions and tokens with.

  `SECRET_KEY_BASE` signs and encrypts session cookies, and Guardian signs JWTs
  with `TOKEN_SIGNING_SECRET`, falling back to `SECRET_KEY_BASE`. A short or
  well-known value lets anyone forge a session or token, so `config/runtime.exs`
  refuses to boot with one instead of running.
  """

  @min_bytes 64
  @placeholders ~w(changeme change-me changeit secret placeholder)

  @doc """
  Returns `value` when it is usable as a signing secret, and raises otherwise.
  """
  @spec validate!(String.t(), String.t()) :: String.t()
  def validate!(name, value) when is_binary(name) and is_binary(value) do
    if weak?(value) do
      raise ArgumentError, """
      #{name} is a placeholder or shorter than #{@min_bytes} bytes.
      Generate a random one with `mix phx.gen.secret` or `openssl rand -base64 64`.
      """
    end

    value
  end

  @doc false
  @spec weak?(String.t()) :: boolean()
  def weak?(value) when is_binary(value) do
    trimmed = String.trim(value)
    byte_size(trimmed) < @min_bytes or String.downcase(trimmed) in @placeholders
  end
end
