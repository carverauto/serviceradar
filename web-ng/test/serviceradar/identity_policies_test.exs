defmodule ServiceRadar.IdentityPoliciesTest do
  @moduledoc """
  Tests for Identity domain authorization policies.

  Verifies that:
  - Users can only access resources in their own tenant
  - Role-based permissions are correctly enforced
  - Cross-tenant access is prevented
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers
  use ServiceRadarWebNG.PolicyTestHelpers

  alias ServiceRadar.Identity.User

  describe "User read policies" do
    setup do
      tenant = tenant_fixture()
      admin = admin_user_fixture(tenant)
      operator = operator_user_fixture(tenant)
      viewer = user_fixture(tenant)

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
      tenant = tenant_fixture()
      admin = admin_user_fixture(tenant)
      target_user = user_fixture(tenant, %{email: "target@example.com"})

      {:ok, tenant: tenant, admin: admin, target_user: target_user}
    end

    test "admin can update role of users in their tenant", %{
      admin: admin,
      target_user: target
    } do
      actor = actor_for_user(admin)

      result =
        target
        |> Ash.Changeset.for_update(:update_role, %{role: :operator},
          actor: actor
        )
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.role == :operator
    end

    test "users can update their own display_name", %{target_user: user} do
      actor = actor_for_user(user)

      result =
        user
        |> Ash.Changeset.for_update(:update, %{display_name: "My New Name"},
          actor: actor
        )
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.display_name == "My New Name"
    end

    test "users cannot update other users display_name", %{tenant: tenant, target_user: target} do
      # Create another user to try to update target (tenant needed for fixture)
      other_user = user_fixture(tenant, %{email: "other@example.com"})
      actor = actor_for_user(other_user)

      result =
        target
        |> Ash.Changeset.for_update(:update, %{display_name: "Hacked Name"},
          actor: actor
        )
        |> Ash.update()

      # Should fail - users can only update themselves
      assert {:error, _} = result
    end

    test "non-admin cannot change user roles", %{tenant: tenant, target_user: target} do
      # Create a regular user to try to change roles (tenant needed for fixture)
      regular_user = user_fixture(tenant, %{email: "regular@example.com"})
      actor = actor_for_user(regular_user)

      result =
        target
        |> Ash.Changeset.for_update(:update_role, %{role: :admin},
          actor: actor
        )
        |> Ash.update()

      # Should fail - only admins can change roles
      assert {:error, _} = result
    end
  end

  describe "Cross-tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-policy"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-policy"})

      user_a = admin_user_fixture(tenant_a)
      user_b = admin_user_fixture(tenant_b)

      {:ok, user_a: user_a, user_b: user_b}
    end

    test "user cannot see users from other tenant", %{
      user_a: user_a,
      user_b: user_b
    } do
      actor_a = actor_for_user(user_a)

      # Query with user A's actor context
      {:ok, users} = Ash.read(User, actor: actor_a)
      user_ids = Enum.map(users, & &1.id)

      # Should see user_a but not user_b
      assert user_a.id in user_ids
      refute user_b.id in user_ids
    end

    test "user cannot access other tenant's user by ID", %{
      user_a: user_a,
      user_b: user_b
    } do
      actor_a = actor_for_user(user_a)

      # Try to get user_b using user_a's actor context
      result = Ash.get(User, user_b.id, actor: actor_a)

      # Should fail - user_b doesn't exist in tenant_a's context
      assert {:error, _} = result
    end
  end

  describe "API Token policies" do
    alias ServiceRadar.Identity.ApiToken

    setup do
      tenant = tenant_fixture()
      admin = admin_user_fixture(tenant)
      viewer = user_fixture(tenant)

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
