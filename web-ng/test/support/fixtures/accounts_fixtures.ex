defmodule ServiceRadarWebNG.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `ServiceRadarWebNG.Accounts` context.
  """

  import Ecto.Query

  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNG.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"
  def test_tenant_id, do: ServiceRadarWebNG.DataCase.test_tenant_id()

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      tenant_id: test_tenant_id()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
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

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    ServiceRadarWebNG.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    ServiceRadarWebNG.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    ServiceRadarWebNG.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
