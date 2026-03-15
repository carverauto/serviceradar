defmodule ServiceRadar.Identity.Changes.HashPasswordTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.Changes.HashPassword
  alias ServiceRadar.Identity.User

  test "hashes a password onto the changeset" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:password, "averysecurepassword")

    updated = HashPassword.change(changeset, %{force?: false}, %{})

    assert is_binary(updated.attributes.hashed_password)
    assert updated.attributes.hashed_password != "averysecurepassword"
    assert Bcrypt.verify_pass("averysecurepassword", updated.attributes.hashed_password)
  end

  test "uses force_change_attribute when configured" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:password, "anothersecurepassword")

    updated = HashPassword.change(changeset, %{force?: true}, %{})

    assert is_binary(updated.attributes.hashed_password)
    assert Bcrypt.verify_pass("anothersecurepassword", updated.attributes.hashed_password)
  end
end
