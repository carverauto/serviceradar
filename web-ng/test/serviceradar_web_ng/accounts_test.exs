defmodule ServiceRadarWebNG.AccountsTest do
  use ServiceRadarWebNG.DataCase

  alias ServiceRadarWebNG.Accounts

  import ServiceRadarWebNG.AccountsFixtures

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
      {:error, error} =
        Accounts.register_user(%{tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()})

      # Ash returns Ash.Error, not Ecto.Changeset
      assert has_error?(error, :email)
    end

    test "validates email when given" do
      {:error, error} =
        Accounts.register_user(%{
          email: "not valid",
          tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()
        })

      assert has_error?(error, :email)
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()

      {:error, error} =
        Accounts.register_user(%{
          email: email,
          tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()
        })

      # Per-tenant uniqueness constraint reports field as :tenant_id, global reports :email
      assert has_error?(error, :email) or has_error?(error, :tenant_id)

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, error} =
        Accounts.register_user(%{
          email: String.upcase(to_string(email)),
          tenant_id: ServiceRadarWebNG.DataCase.test_tenant_id()
        })

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
    test "returns true for authenticated users (has id)" do
      # With Ash JWT tokens, sudo mode is always true for authenticated users
      assert Accounts.sudo_mode?(%{id: "some-user-id"})
      assert Accounts.sudo_mode?(%{id: Ecto.UUID.generate()})
    end

    test "returns false for unauthenticated context" do
      refute Accounts.sudo_mode?(%{})
      refute Accounts.sudo_mode?(nil)
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%{email: nil})
      assert :email in changeset.required
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
      {:ok, updated_user} =
        Accounts.update_user_password(user, %{
          current_password: valid_user_password(),
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      assert Accounts.get_user_by_email_and_password(updated_user.email, "new valid password")
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
