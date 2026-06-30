defmodule ServiceRadar.Identity.PasswordHash do
  @moduledoc """
  Bcrypt verification helpers that normalise the hash version prefix.

  `bcrypt_elixir` only recognises the `$2a$` and `$2b$` bcrypt version
  prefixes. Valid 60-character bcrypt hashes produced by other
  implementations — PHP `password_hash/2`, Apache `htpasswd -B`, libxcrypt,
  many SSO/IdP user stores — commonly use the `$2y$` prefix. `$2y$` is
  cryptographically identical to `$2b$` (it was introduced by PHP as the
  alias for the fixed algorithm), but `Bcrypt.verify_pass/2` rejects it,
  returning `false` for the *correct* password. That surfaces to the user as
  `current_password: is incorrect` on an otherwise-valid password.

  Normalising the version prefix to `$2b$` before verification restores
  compatibility. It is sound: the salt and checksum bytes are computed
  identically for `$2b$`/`$2y$`, so the correct password still verifies and a
  wrong password still fails.
  """

  @doc """
  Verifies `password` against `hashed_password`, normalising the bcrypt
  version prefix first. Returns `false` (without raising) for blank/`nil`
  inputs so it is safe to call directly in validation flows.
  """
  @spec verify(String.t() | nil, String.t() | nil) :: boolean()
  def verify(password, hashed_password)
      when is_binary(password) and password != "" and is_binary(hashed_password) and
             hashed_password != "" do
    Bcrypt.verify_pass(password, normalize(hashed_password))
  end

  def verify(_password, _hashed_password), do: false

  @doc """
  Rewrites a `$2y$` bcrypt version prefix to the equivalent `$2b$` prefix that
  `bcrypt_elixir` understands. All other values are returned unchanged.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize("$2y$" <> rest), do: "$2b$" <> rest
  def normalize(hashed_password) when is_binary(hashed_password), do: hashed_password
end
