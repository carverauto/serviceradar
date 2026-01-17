defmodule ServiceRadar.IdentityPoliciesTest do
  @moduledoc """
  Tests for Identity domain authorization policies.

  Verifies that:
  - Role-based permissions are correctly enforced
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers
  use ServiceRadarWebNG.PolicyTestHelpers

  alias ServiceRadar.Identity.User

  describe "User read policies" do
    setup do
      admin = admin_user_fixture()
      operator = operator_user_fixture()
      viewer = user_fixture()

      {:ok, admin: admin, operator: operator, viewer: viewer}
    end

    test "admin can read users in their tenant", %{admin: admin} do
      actor = actor_for_user(admin)

      {:ok, users} = Ash.read(User, actor: actor)
      refute Enum.empty?(users)
    end

    test "operator can read users in their tenant", %{operator: operator} do
      actor = actor_for_user(operator)

      {:ok, users} = Ash.read(User, actor: actor)
      refute Enum.empty?(users)
    end

    test "viewer can read users in their tenant", %{viewer: viewer} do
      actor = actor_for_user(viewer)

      {:ok, users} = Ash.read(User, actor: actor)
      refute Enum.empty?(users)
    end
  end

  describe "User update policies" do
    setup do
      admin = admin_user_fixture()
      target_user = user_fixture(%{email: "target@example.com"})

      {:ok, admin: admin, target_user: target_user}
    end

    test "admin can update role of users in their tenant", %{
      admin: admin,
      target_user: target
    } do
      actor = actor_for_user(admin)

      result =
        target
        |> Ash.Changeset.for_update(:update_role, %{role: :operator}, actor: actor)
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.role == :operator
    end

    test "users can update their own display_name", %{target_user: user} do
      actor = actor_for_user(user)

      result =
        user
        |> Ash.Changeset.for_update(:update, %{display_name: "My New Name"}, actor: actor)
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.display_name == "My New Name"
    end

    test "users cannot update other users display_name", %{target_user: target} do
      other_user = user_fixture(%{email: "other@example.com"})
      actor = actor_for_user(other_user)

      result =
        target
        |> Ash.Changeset.for_update(:update, %{display_name: "Hacked Name"}, actor: actor)
        |> Ash.update()

      # Should fail - users can only update themselves
      assert {:error, _} = result
    end

    test "non-admin cannot change user roles", %{target_user: target} do
      regular_user = user_fixture(%{email: "regular@example.com"})
      actor = actor_for_user(regular_user)

      result =
        target
        |> Ash.Changeset.for_update(:update_role, %{role: :admin}, actor: actor)
        |> Ash.update()

      # Should fail - only admins can change roles
      assert {:error, _} = result
    end
  end

  describe "API Token policies" do
    alias ServiceRadar.Identity.ApiToken

    setup do
      admin = admin_user_fixture()
      viewer = user_fixture()

      {:ok, admin: admin, viewer: viewer}
    end

    test "admin can create API tokens", %{admin: admin} do
      actor = actor_for_user(admin)
      raw_token = "srk_" <> Base.encode64(:crypto.strong_rand_bytes(32))

      result =
        ApiToken
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Token",
            scope: :full_access,
            user_id: admin.id,
            token: raw_token
          },
          actor: actor
        )
        |> Ash.create()

      assert {:ok, token} = result
      assert token.name == "Test Token"
    end

    test "users can create tokens for themselves", %{viewer: viewer} do
      actor = actor_for_user(viewer)
      raw_token = "srk_" <> Base.encode64(:crypto.strong_rand_bytes(32))

      result =
        ApiToken
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "My Token",
            scope: :read_only,
            user_id: viewer.id,
            token: raw_token
          },
          actor: actor
        )
        |> Ash.create()

      assert {:ok, token} = result
      assert token.user_id == viewer.id
    end

    test "users can read their own tokens", %{viewer: viewer} do
      actor = actor_for_user(viewer)
      raw_token = "srk_" <> Base.encode64(:crypto.strong_rand_bytes(32))

      # Create a token first
      {:ok, _token} =
        ApiToken
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "My Token",
            scope: :read_only,
            user_id: viewer.id,
            token: raw_token
          },
          actor: actor
        )
        |> Ash.create()

      # Read tokens
      {:ok, tokens} = Ash.read(ApiToken, actor: actor)
      refute Enum.empty?(tokens)
    end
  end
end
