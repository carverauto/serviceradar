defmodule ServiceRadarWebNG.AccountsTest do
  use ServiceRadarWebNG.DataCase

  alias ServiceRadarWebNG.Accounts

  import Ecto.Query, only: [from: 2]
  import ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.Accounts.UserToken

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      # Use a valid UUID format that doesn't exist in the database
      non_existent_id = Ecto.UUID.generate()

      assert_raise RuntimeError, fn ->
        Accounts.get_user!(non_existent_id)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, error} = Accounts.register_user(%{tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()})

      # Ash returns Ash.Error, not Ecto.Changeset
      assert has_error?(error, :email)
    end

    test "validates email when given" do
      {:error, error} = Accounts.register_user(%{email: "not valid", tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()})

      assert has_error?(error, :email)
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, error} = Accounts.register_user(%{email: email, tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()})
      # Per-tenant uniqueness constraint reports field as :tenant_id, global reports :email
      assert has_error?(error, :email) or has_error?(error, :tenant_id)

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, error} = Accounts.register_user(%{email: String.upcase(to_string(email)), tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()})
      assert has_error?(error, :email) or has_error?(error, :tenant_id)
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert to_string(user.email) == email
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%{email: nil})
      assert :email in changeset.required
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert to_string(user_token.sent_to) == to_string(user.email)
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, to_string(user.email), url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, updated_user} = Accounts.update_user_email(user, token)
      assert to_string(updated_user.email) == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {count, nil} =
        Repo.update_all(
          from(ut in UserToken, where: ut.user_id == ^user.id),
          set: [inserted_at: ~N[2020-01-01 00:00:00]]
        )

      assert count >= 1

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture() |> set_password()}
    end

    test "validates password", %{user: user} do
      {:error, error} =
        Accounts.update_user_password(user, %{
          current_password: valid_user_password(),
          password: "not valid",
          password_confirmation: "another"
        })

      # Ash error format
      assert has_error?(error, :password) or has_error?(error, :password_confirmation)
    end

    test "updates the password", %{user: user} do
      {:ok, {updated_user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          current_password: valid_user_password(),
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      assert expired_tokens == []
      assert Accounts.get_user_by_email_and_password(updated_user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          current_password: valid_user_password(),
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{user: user, token: token} do
      dt = ~N[2020-01-01 00:00:00]

      {count, nil} =
        Repo.update_all(from(ut in UserToken, where: ut.user_id == ^user.id),
          set: [inserted_at: dt, authenticated_at: dt]
        )

      assert count >= 1
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{user: user, token: token} do
      {count, nil} =
        Repo.update_all(from(ut in UserToken, where: ut.user_id == ^user.id),
          set: [inserted_at: ~N[2020-01-01 00:00:00]]
        )

      assert count >= 1
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {confirmed_user, expired_tokens}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert confirmed_user.confirmed_at
      assert Enum.any?(expired_tokens, fn t -> t.token == hashed_token end)
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {returned_user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      assert returned_user.id == user.id
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()

      {count, nil} =
        Repo.update_all(from(u in "ng_users", where: u.id == type(^user.id, Ecto.UUID)),
          set: [hashed_password: "hashed"]
        )

      assert count == 1
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert to_string(user_token.sent_to) == to_string(user.email)
      assert user_token.context == "login"
    end
  end

  # Helper to check for Ash errors
  defp has_error?(%Ash.Error.Invalid{errors: errors}, field) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: ^field} -> true
      %Ash.Error.Changes.Required{field: ^field} -> true
      _ -> false
    end)
  end

  defp has_error?(_, _), do: false
end
