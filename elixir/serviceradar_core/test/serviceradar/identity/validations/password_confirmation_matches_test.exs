defmodule ServiceRadar.Identity.Validations.PasswordConfirmationMatchesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Validations.PasswordConfirmationMatches

  test "accepts matching password arguments" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:password, "averysecurepassword")
      |> Ash.Changeset.set_argument(:password_confirmation, "averysecurepassword")

    assert PasswordConfirmationMatches.validate(changeset, %{}, %{}) == :ok
  end

  test "rejects mismatched password confirmation" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:password, "averysecurepassword")
      |> Ash.Changeset.set_argument(:password_confirmation, "differentpassword")

    assert PasswordConfirmationMatches.validate(changeset, %{}, %{}) ==
             {:error, field: :password_confirmation, message: "does not match password"}
  end
end
