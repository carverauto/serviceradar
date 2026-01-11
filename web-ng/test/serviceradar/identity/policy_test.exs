defmodule ServiceRadar.Identity.PolicyTest do
  @moduledoc """
  Comprehensive policy test suite for multi-tenant security.

  These tests verify:
  1. Tenant isolation - users can only access resources in their tenant
  2. tenant_id immutability - tenant assignment cannot be changed
  3. Role-based access control - viewer/operator/admin/super_admin permissions
  4. Cross-tenant protection - no data leakage between tenants

  SECURITY: These tests are CRITICAL for multi-tenancy. Any failures here
  indicate potential security vulnerabilities.
  """

  use ServiceRadarWebNG.DataCase, async: false

  require Ash.Query

  alias ServiceRadar.Identity.{User, Tenant}

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defp create_tenant(name \\ nil) do
    name = name || "Test Tenant #{System.unique_integer([:positive])}"

    {:ok, tenant} =
      Ash.Changeset.for_create(Tenant, :create, %{
        name: name,
        slug: Slug.slugify(name),
        contact_email: "admin@#{Slug.slugify(name)}.example.com",
        contact_name: "Admin"
      })
      |> Ash.create(authorize?: false)

    tenant
  end

  defp create_user(tenant, attrs \\ %{}) do
    email = attrs[:email] || "user#{System.unique_integer([:positive])}@example.com"
    role = attrs[:role] || :viewer

    {:ok, user} =
      Ash.Changeset.for_create(User, :create, %{
        email: email,
        tenant_id: tenant.id,
        role: role
      })
      |> Ash.create(authorize?: false)

    user
  end

  defp actor_for(user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      role: user.role,
      email: user.email
    }
  end

  # ============================================================================
  # Tenant Isolation Tests
  # ============================================================================

  describe "tenant isolation" do
    setup do
      tenant_a = create_tenant("Tenant A")
      tenant_b = create_tenant("Tenant B")

      user_a = create_user(tenant_a, %{role: :viewer})
      user_b = create_user(tenant_b, %{role: :viewer})

      admin_a = create_user(tenant_a, %{role: :admin})

      %{
        tenant_a: tenant_a,
        tenant_b: tenant_b,
        user_a: user_a,
        user_b: user_b,
        admin_a: admin_a
      }
    end

    test "users can read themselves", %{user_a: user_a} do
      actor = actor_for(user_a)

      {:ok, [found]} =
        User
        |> Ash.Query.filter(id == ^user_a.id)
        |> Ash.read(actor: actor)

      assert found.id == user_a.id
    end

    test "users can read other users in same tenant", %{user_a: user_a, admin_a: admin_a} do
      actor = actor_for(user_a)

      {:ok, users} =
        User
        |> Ash.Query.filter(tenant_id == ^user_a.tenant_id)
        |> Ash.read(actor: actor)

      user_ids = Enum.map(users, & &1.id)
      assert user_a.id in user_ids
      assert admin_a.id in user_ids
    end

    test "users CANNOT read users from other tenants", %{user_a: user_a, user_b: user_b} do
      actor = actor_for(user_a)

      {:ok, users} =
        User
        |> Ash.Query.filter(id == ^user_b.id)
        |> Ash.read(actor: actor)

      # Should return empty - user_b is in a different tenant
      assert users == []
    end

    test "users CANNOT read all users across tenants", %{user_a: user_a, user_b: user_b} do
      actor = actor_for(user_a)

      {:ok, users} = Ash.read(User, actor: actor)

      user_ids = Enum.map(users, & &1.id)

      # Should only see users from tenant_a
      assert user_a.id in user_ids
      refute user_b.id in user_ids
    end
  end

  # ============================================================================
  # tenant_id Immutability Tests
  # ============================================================================

  describe "tenant_id immutability" do
    setup do
      tenant_a = create_tenant("Tenant A")
      tenant_b = create_tenant("Tenant B")
      user = create_user(tenant_a, %{role: :admin})

      %{tenant_a: tenant_a, tenant_b: tenant_b, user: user}
    end

    test "tenant_id is set correctly on creation", %{tenant_a: tenant_a, user: user} do
      assert user.tenant_id == tenant_a.id
    end

    test "update action does NOT accept tenant_id", %{user: user} do
      actor = actor_for(user)

      # The :update action only accepts [:display_name]
      # Attempting to include tenant_id should have no effect
      {:ok, updated} =
        user
        |> Ash.Changeset.for_update(:update, %{display_name: "New Name"})
        |> Ash.update(actor: actor)

      assert updated.display_name == "New Name"
      assert updated.tenant_id == user.tenant_id
    end

    test "CANNOT change tenant_id via force_change_attribute", %{
      user: user,
      tenant_b: tenant_b
    } do
      # This tests the defense-in-depth validation
      # Even if code tries to force a tenant_id change, it should fail

      result =
        user
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_b.id)
        |> Ash.update(authorize?: false)

      # Should fail due to the validation we added
      assert {:error, error} = result
      assert error_has_field?(error, :tenant_id)
    end

    test "tenant_id cannot be changed even by admin of same tenant", %{
      user: user,
      tenant_b: tenant_b
    } do
      actor = actor_for(user)

      result =
        user
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_b.id)
        |> Ash.update(actor: actor)

      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Role-Based Access Control Tests
  # ============================================================================

  describe "role-based access control" do
    setup do
      tenant = create_tenant("RBAC Tenant")

      viewer = create_user(tenant, %{role: :viewer, email: "viewer@example.com"})
      operator = create_user(tenant, %{role: :operator, email: "operator@example.com"})
      admin = create_user(tenant, %{role: :admin, email: "admin@example.com"})

      %{tenant: tenant, viewer: viewer, operator: operator, admin: admin}
    end

    test "viewer can read users in tenant", %{viewer: viewer, admin: admin} do
      actor = actor_for(viewer)

      {:ok, users} = Ash.read(User, actor: actor)
      user_ids = Enum.map(users, & &1.id)

      assert viewer.id in user_ids
      assert admin.id in user_ids
    end

    test "viewer can update own profile", %{viewer: viewer} do
      actor = actor_for(viewer)

      {:ok, updated} =
        viewer
        |> Ash.Changeset.for_update(:update, %{display_name: "Updated Viewer"})
        |> Ash.update(actor: actor)

      assert updated.display_name == "Updated Viewer"
    end

    test "viewer CANNOT update other user's profile", %{viewer: viewer, operator: operator} do
      actor = actor_for(viewer)

      result =
        operator
        |> Ash.Changeset.for_update(:update, %{display_name: "Hacked"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "viewer CANNOT change roles", %{viewer: viewer, operator: operator} do
      actor = actor_for(viewer)

      result =
        operator
        |> Ash.Changeset.for_update(:update_role, %{role: :admin})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "admin CAN change roles within same tenant", %{admin: admin, viewer: viewer} do
      actor = actor_for(admin)

      {:ok, updated} =
        viewer
        |> Ash.Changeset.for_update(:update_role, %{role: :operator})
        |> Ash.update(actor: actor)

      assert updated.role == :operator
    end

    test "admin CANNOT change roles in different tenant", %{admin: admin} do
      other_tenant = create_tenant("Other Tenant")
      other_user = create_user(other_tenant, %{role: :viewer})

      actor = actor_for(admin)

      result =
        other_user
        |> Ash.Changeset.for_update(:update_role, %{role: :admin})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  # ============================================================================
  # Super Admin Tests
  # ============================================================================

  describe "super_admin bypass" do
    setup do
      tenant_a = create_tenant("Tenant A")
      tenant_b = create_tenant("Tenant B")

      super_admin = create_user(tenant_a, %{role: :super_admin, email: "super@example.com"})
      regular_user = create_user(tenant_b, %{role: :viewer, email: "regular@example.com"})

      %{
        tenant_a: tenant_a,
        tenant_b: tenant_b,
        super_admin: super_admin,
        regular_user: regular_user
      }
    end

    test "super_admin can read users across all tenants", %{
      super_admin: super_admin,
      regular_user: regular_user
    } do
      actor = actor_for(super_admin)

      {:ok, users} = Ash.read(User, actor: actor)
      user_ids = Enum.map(users, & &1.id)

      # Super admin sees everyone
      assert super_admin.id in user_ids
      assert regular_user.id in user_ids
    end

    test "super_admin can change roles in any tenant", %{
      super_admin: super_admin,
      regular_user: regular_user
    } do
      actor = actor_for(super_admin)

      {:ok, updated} =
        regular_user
        |> Ash.Changeset.for_update(:update_role, %{role: :admin})
        |> Ash.update(actor: actor)

      assert updated.role == :admin
    end

    test "super_admin still CANNOT change tenant_id (defense in depth)", %{
      super_admin: super_admin,
      regular_user: regular_user,
      tenant_a: tenant_a
    } do
      actor = actor_for(super_admin)

      # Even super_admin cannot move users between tenants
      # This is a critical security control
      result =
        regular_user
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_a.id)
        |> Ash.update(actor: actor)

      assert {:error, error} = result
      assert error_has_field?(error, :tenant_id)
    end
  end

  # ============================================================================
  # Cross-Tenant Attack Prevention Tests
  # ============================================================================

  describe "cross-tenant attack prevention" do
    setup do
      tenant_a = create_tenant("Victim Tenant")
      tenant_b = create_tenant("Attacker Tenant")

      victim = create_user(tenant_a, %{role: :admin, email: "victim@example.com"})
      attacker = create_user(tenant_b, %{role: :admin, email: "attacker@example.com"})

      %{
        tenant_a: tenant_a,
        tenant_b: tenant_b,
        victim: victim,
        attacker: attacker
      }
    end

    test "attacker cannot read victim's data by guessing ID", %{
      attacker: attacker,
      victim: victim
    } do
      actor = actor_for(attacker)

      # Attacker knows victim's user ID somehow
      {:ok, results} =
        User
        |> Ash.Query.filter(id == ^victim.id)
        |> Ash.read(actor: actor)

      # Should return empty - tenant isolation prevents access
      assert results == []
    end

    test "attacker cannot enumerate users by iterating IDs", %{attacker: attacker} do
      actor = actor_for(attacker)

      # Try to read all users without tenant filter
      {:ok, users} = Ash.read(User, actor: actor)

      # Should only see users from attacker's tenant
      tenant_ids = Enum.map(users, & &1.tenant_id) |> Enum.uniq()
      assert tenant_ids == [attacker.tenant_id]
    end

    test "attacker cannot modify victim via update action", %{
      attacker: attacker,
      victim: victim
    } do
      actor = actor_for(attacker)

      result =
        victim
        |> Ash.Changeset.for_update(:update, %{display_name: "Hacked by attacker"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "attacker cannot escalate victim's privileges", %{attacker: attacker, victim: victim} do
      actor = actor_for(attacker)

      result =
        victim
        |> Ash.Changeset.for_update(:update_role, %{role: :super_admin})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "attacker cannot change victim's email (account takeover)", %{
      attacker: attacker,
      victim: victim
    } do
      actor = actor_for(attacker)

      result =
        victim
        |> Ash.Changeset.for_update(:update_email, %{email: "attacker-controlled@evil.com"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp error_has_field?(%Ash.Error.Invalid{errors: errors}, field) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: ^field} -> true
      %{field: ^field} -> true
      _ -> false
    end)
  end

  defp error_has_field?(_, _), do: false
end
