defmodule ServiceRadarWebNG.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `ServiceRadarWebNG.Accounts` context.

  Uses Ash-based user management with JWT tokens.
  """

  import Ecto.Query

  alias ServiceRadarWebNG.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello_world_123!"
  def test_tenant_id, do: ServiceRadarWebNG.DataCase.test_tenant_id()

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      tenant_id: test_tenant_id()
    })
  end

  @doc """
  Creates a user without confirming their email.
  """
  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> ServiceRadar.Identity.Users.register()

    user
  end

  @doc """
  Creates a confirmed user.

  This directly sets confirmed_at via Ash confirm action.
  """
  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    # Confirm the user via Ash
    {:ok, confirmed_user} = ServiceRadar.Identity.Users.confirm(user)
    confirmed_user
  end

  @doc """
  Creates a user with a password set.
  """
  def user_with_password_fixture(attrs \\ %{}) do
    password = Map.get(attrs, :password, valid_user_password())

    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Map.put(:password, password)
      |> Map.put(:password_confirmation, password)
      |> ServiceRadar.Identity.Users.register_with_password()

    # Confirm the user
    {:ok, confirmed_user} = ServiceRadar.Identity.Users.confirm(user)
    confirmed_user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    # For users without a password, we set it directly via database update
    # since the Ash change_password action requires current_password
    hashed = Bcrypt.hash_pwd_salt(valid_user_password())

    {1, nil} =
      ServiceRadarWebNG.Repo.update_all(
        from(u in "ng_users", where: u.id == type(^user.id, Ecto.UUID)),
        set: [hashed_password: hashed]
      )

    # Re-fetch the user from Ash
    {:ok, updated_user} = ServiceRadar.Identity.Users.get(user.id)
    updated_user
  end
end
