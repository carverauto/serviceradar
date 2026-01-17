defmodule ServiceRadar.Identity.PolicyTest do
  @moduledoc """
  Policy test suite for authorization and role-based access control.

  ## Tenant Instance Model

  In a tenant-instance model, each tenant has their own deployment with separate
  database schemas. Tenant isolation is enforced at the infrastructure level via
  PostgreSQL search_path set by CNPG credentials.

  These tests verify role-based access control within a single tenant instance:
  - viewer/operator/admin permissions
  - Profile update authorization
  - Role change authorization
  """

  use ServiceRadarWebNG.DataCase, async: false

  require Ash.Query

  alias ServiceRadar.Identity.User

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defp create_user(attrs \\ %{}) do
    email = attrs[:email] || "user#{System.unique_integer([:positive])}@example.com"
    role = attrs[:role] || :viewer

    # In tenant-instance model, users are created in the schema determined by DB connection
    {:ok, user} =
      Ash.Changeset.for_create(User, :create, %{
        email: email,
        role: role
      })
      |> Ash.create()

    user
  end

  defp actor_for(user) do
    %{
      id: user.id,
      role: user.role,
      email: user.email
    }
  end

  # ============================================================================
  # Role-Based Access Control Tests
  # ============================================================================

  describe "role-based access control" do
    setup do
      viewer = create_user(%{role: :viewer, email: "viewer@example.com"})
      operator = create_user(%{role: :operator, email: "operator@example.com"})
      admin = create_user(%{role: :admin, email: "admin@example.com"})

      %{viewer: viewer, operator: operator, admin: admin}
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
  end
end
