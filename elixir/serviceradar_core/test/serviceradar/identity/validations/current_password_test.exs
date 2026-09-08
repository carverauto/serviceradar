defmodule ServiceRadar.Identity.Validations.CurrentPasswordTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Validations.CurrentPassword

  test "requires the current password when a password exists" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Map.put(:data, %{hashed_password: Bcrypt.hash_pwd_salt("current-password")})

    assert CurrentPassword.validate(changeset, [required_message: "is required"], %{}) ==
             {:error, field: :current_password, message: "is required"}
  end

  test "accepts a matching current password" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:current_password, "current-password")
      |> Map.put(:data, %{hashed_password: Bcrypt.hash_pwd_salt("current-password")})

    assert CurrentPassword.validate(changeset, [required_message: "is required"], %{}) == :ok
  end

  test "accepts a matching current password stored as a $2y$ bcrypt hash" do
    # Regression: a valid 60-char bcrypt hash written with the `$2y$` version
    # prefix (PHP `password_hash/2`, Apache `htpasswd -B`, libxcrypt) is
    # rejected by `Bcrypt.verify_pass/2`, so the *correct* current password was
    # reported as "is incorrect".
    "$2b$" <> rest = Bcrypt.hash_pwd_salt("current-password")
    two_y_hash = "$2y$" <> rest

    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:current_password, "current-password")
      |> Map.put(:data, %{hashed_password: two_y_hash})

    assert CurrentPassword.validate(changeset, [required_message: "is required"], %{}) == :ok
  end

  test "still rejects a wrong current password stored as a $2y$ bcrypt hash" do
    "$2b$" <> rest = Bcrypt.hash_pwd_salt("current-password")
    two_y_hash = "$2y$" <> rest

    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:current_password, "wrong-password")
      |> Map.put(:data, %{hashed_password: two_y_hash})

    assert CurrentPassword.validate(changeset, [required_message: "is required"], %{}) ==
             {:error, field: :current_password, message: "is incorrect"}
  end

  test "falls back to the default required message when opts omit it" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Map.put(:data, %{hashed_password: Bcrypt.hash_pwd_salt("current-password")})

    assert CurrentPassword.validate(changeset, [], %{}) ==
             {:error, field: :current_password, message: "is required"}
  end

  test "returns the no-password message when provided" do
    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:current_password, "unexpected")
      |> Map.put(:data, %{hashed_password: nil})

    assert CurrentPassword.validate(
             changeset,
             [
               required_message: "is required to change password",
               no_password_message: "you don't have a password set"
             ],
             %{}
           ) ==
             {:error, field: :current_password, message: "you don't have a password set"}
  end
end
