defmodule ServiceRadar.Identity.PasswordHashTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.PasswordHash

  @password "current-password-123"

  defp hash_with_prefix(prefix) do
    "$2b$" <> rest = Bcrypt.hash_pwd_salt(@password)
    prefix <> rest
  end

  describe "verify/2" do
    test "accepts the correct password for a $2b$ hash" do
      assert PasswordHash.verify(@password, hash_with_prefix("$2b$"))
    end

    test "accepts the correct password for a $2a$ hash" do
      assert PasswordHash.verify(@password, hash_with_prefix("$2a$"))
    end

    test "accepts the correct password for a $2y$ hash (PHP/htpasswd variant)" do
      # Regression: bcrypt_elixir rejects $2y$ outright, reporting the correct
      # password as incorrect. Normalising the prefix must let it verify.
      assert PasswordHash.verify(@password, hash_with_prefix("$2y$"))
    end

    test "still rejects a wrong password for a $2y$ hash" do
      refute PasswordHash.verify("wrong-password", hash_with_prefix("$2y$"))
    end

    test "returns false (does not raise) for blank or nil inputs" do
      refute PasswordHash.verify(nil, hash_with_prefix("$2b$"))
      refute PasswordHash.verify(@password, nil)
      refute PasswordHash.verify(@password, "")
      refute PasswordHash.verify("", hash_with_prefix("$2b$"))
    end
  end

  describe "normalize/1" do
    test "rewrites $2y$ to $2b$ and leaves other prefixes untouched" do
      assert "$2b$rest" == PasswordHash.normalize("$2y$rest")
      assert "$2b$rest" == PasswordHash.normalize("$2b$rest")
      assert "$2a$rest" == PasswordHash.normalize("$2a$rest")
    end
  end
end
