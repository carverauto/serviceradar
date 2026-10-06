defmodule ServiceRadarWebNG.SigningSecretTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SigningSecret

  @moduletag :db_free

  test "rejects the placeholder the package used to ship, in any case" do
    for value <- ["changeme", "CHANGEME", " ChangeMe "] do
      assert_raise ArgumentError, ~r/SECRET_KEY_BASE is a placeholder or shorter than 64 bytes/, fn ->
        SigningSecret.validate!("SECRET_KEY_BASE", value)
      end
    end
  end

  test "rejects values shorter than 64 bytes" do
    assert_raise ArgumentError, ~r/TOKEN_SIGNING_SECRET/, fn ->
      SigningSecret.validate!("TOKEN_SIGNING_SECRET", String.duplicate("a", 63))
    end
  end

  test "does not count surrounding whitespace toward the length" do
    padded = "  " <> String.duplicate("a", 62) <> "  "

    assert_raise ArgumentError, fn -> SigningSecret.validate!("SECRET_KEY_BASE", padded) end
  end

  test "accepts a generated secret unchanged" do
    secret = 64 |> :crypto.strong_rand_bytes() |> Base.encode64()
    assert SigningSecret.validate!("SECRET_KEY_BASE", secret) == secret
  end
end
