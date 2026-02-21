defmodule ServiceRadar.Identity.PolicyTest do
  @moduledoc """
  Policy test suite for authorization and role-based access control.

  NOTE: Identity resources are policy-protected. Test fixtures must be created
  using a system actor (see `ServiceRadarWebNG.AshTestHelpers`).
  """

  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Identity.User

  import ServiceRadarWebNG.AshTestHelpers,
    only: [
      admin_user_fixture: 1,
      operator_user_fixture: 1,
      viewer_user_fixture: 1,
      actor_for_user: 1
    ]

  defp unwrap_results({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_results({:ok, results}) when is_list(results), do: results
  defp unwrap_results(_), do: []

  describe "role-based access control" do
    setup do
      viewer = viewer_user_fixture(%{email: "viewer@example.com"})
      operator = operator_user_fixture(%{email: "operator@example.com"})
      admin = admin_user_fixture(%{email: "admin@example.com"})

      %{viewer: viewer, operator: operator, admin: admin}
    end

    test "viewer can read users (self only)", %{viewer: viewer, admin: admin} do
      actor = actor_for_user(viewer)

      users = unwrap_results(Ash.read(User, actor: actor))
      user_ids = Enum.map(users, & &1.id)

      assert viewer.id in user_ids
      refute admin.id in user_ids
    end

    test "viewer can update own profile", %{viewer: viewer} do
      actor = actor_for_user(viewer)

      {:ok, updated} =
        viewer
        |> Ash.Changeset.for_update(:update, %{display_name: "Updated Viewer"})
        |> Ash.update(actor: actor)

      assert updated.display_name == "Updated Viewer"
    end

    test "viewer CANNOT update other user's profile", %{viewer: viewer, operator: operator} do
      actor = actor_for_user(viewer)

      result =
        operator
        |> Ash.Changeset.for_update(:update, %{display_name: "Hacked"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "viewer CANNOT change roles", %{viewer: viewer, operator: operator} do
      actor = actor_for_user(viewer)

      result =
        operator
        |> Ash.Changeset.for_update(:update_role, %{role: :admin})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "admin can change user roles", %{admin: admin, viewer: viewer} do
      actor = actor_for_user(admin)

      {:ok, updated} =
        viewer
        |> Ash.Changeset.for_update(:update_role, %{role: :operator})
        |> Ash.update(actor: actor)

      assert updated.role == :operator
    end
  end
end
