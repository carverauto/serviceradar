defmodule ServiceRadar.Identity.IdpGroupPermissionMappingDbTest do
  @moduledoc """
  Resolution of identity-provider claims into grants, and reconciliation of the
  group memberships those grants imply.

  The two properties worth pinning are the ones the previous implementation got
  wrong by construction: it returned the *first* matching mapping, so a user in
  several mapped groups got whichever happened to be listed first and reordering
  the list silently changed access; and it could only ever grant one of four
  built-in roles, never a permission set.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.IdpGroupMemberships
  alias ServiceRadar.Identity.RoleMapping
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  defp actor, do: SystemActor.system(:idp_group_permission_mapping_test)

  defp settings!(mappings, default_role \\ :viewer) do
    {:ok, settings} =
      AuthorizationSettings.create_settings(
        %{default_role: default_role, role_mappings: mappings},
        actor: actor()
      )

    settings
  end

  defp group!(name) do
    {:ok, group} =
      UserGroup.create_group(
        %{name: "#{name}-#{System.unique_integer([:positive])}"},
        actor: actor()
      )

    group
  end

  defp user! do
    password = "idp_mapping_test_#{System.unique_integer([:positive])}!"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "idp-mapping-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        actor: actor()
      )

    user
  end

  defp claims(groups), do: %{"email" => "user@example.com", "groups" => groups}

  describe "resolution" do
    test "a single matching mapping grants its role" do
      settings!([%{"source" => "groups", "value" => "ops", "role" => "operator"}])

      assert %{role: :operator} = RoleMapping.resolve(claims(["ops"]), actor: actor())
    end

    test "a mapping can grant a role profile instead of a role" do
      profile_id = Ecto.UUID.generate()

      settings!([
        %{"source" => "groups", "value" => "plugin-authors", "role_profile_id" => profile_id}
      ])

      resolution = RoleMapping.resolve(claims(["plugin-authors"]), actor: actor())

      assert resolution.role_profile_ids == [profile_id]
      # No role named, so the configured default applies.
      assert resolution.role == :viewer
    end

    test "every matching mapping contributes, not just the first" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      settings!([
        %{"source" => "groups", "value" => "one", "role_profile_id" => a},
        %{"source" => "groups", "value" => "two", "role_profile_id" => b}
      ])

      resolution = RoleMapping.resolve(claims(["one", "two"]), actor: actor())

      assert Enum.sort(resolution.role_profile_ids) == Enum.sort([a, b])
      assert length(resolution.matched) == 2
    end

    test "the outcome does not depend on mapping order" do
      # The regression this whole change exists to prevent: with find_value, the
      # first listed mapping won, so reordering the list changed who could do
      # what without anyone editing a grant.
      forward = [
        %{"source" => "groups", "value" => "low", "role" => "viewer"},
        %{"source" => "groups", "value" => "high", "role" => "admin"}
      ]

      settings!(forward)
      first = RoleMapping.resolve(claims(["low", "high"]), actor: actor())

      {:ok, _updated} =
        AuthorizationSettings.update_settings(%{role_mappings: Enum.reverse(forward)},
          actor: actor()
        )

      second = RoleMapping.resolve(claims(["low", "high"]), actor: actor())

      assert first.role == second.role
      assert first.role == :admin
    end

    test "the highest matched role wins, not the alphabetically last" do
      # :admin sorts before :helpdesk and :operator as an atom, so comparing
      # atoms would pick the wrong one.
      settings!([
        %{"source" => "groups", "value" => "a", "role" => "operator"},
        %{"source" => "groups", "value" => "b", "role" => "admin"},
        %{"source" => "groups", "value" => "c", "role" => "helpdesk"}
      ])

      assert %{role: :admin} = RoleMapping.resolve(claims(["a", "b", "c"]), actor: actor())
    end

    test "no match falls back to the configured default role" do
      settings!([%{"source" => "groups", "value" => "ops", "role" => "admin"}], :helpdesk)

      resolution = RoleMapping.resolve(claims(["unrelated"]), actor: actor())

      assert resolution.role == :helpdesk
      assert resolution.matched == []
      assert resolution.role_profile_ids == []
    end

    test "resolve_role/2 still returns just the role" do
      settings!([%{"source" => "groups", "value" => "ops", "role" => "operator"}])

      assert RoleMapping.resolve_role(claims(["ops"]), actor: actor()) == :operator
    end

    test "a mapping granting only a user group still matches" do
      group_id = Ecto.UUID.generate()
      settings!([%{"source" => "groups", "value" => "ops", "user_group_id" => group_id}])

      resolution = RoleMapping.resolve(claims(["ops"]), actor: actor())

      assert resolution.user_group_ids == [group_id]
      assert length(resolution.matched) == 1
    end
  end

  describe "group membership reconciliation" do
    setup do
      %{user: user!()}
    end

    test "creates a membership for a mapped group", %{user: user} do
      group = group!("ops")

      result = IdpGroupMemberships.sync(user.id, [group.id], actor: actor())

      assert result.added == [group.id]
      assert [membership] = memberships_for(user.id, group.id)
      assert membership.source == :idp
    end

    test "withdraws a membership it created once the claim stops arriving", %{user: user} do
      group = group!("ops")
      IdpGroupMemberships.sync(user.id, [group.id], actor: actor())

      result = IdpGroupMemberships.sync(user.id, [], actor: actor())

      assert result.withdrawn == [group.id]
      assert memberships_for(user.id, group.id) == []
    end

    test "never withdraws a membership an operator created", %{user: user} do
      # "The claim did not arrive" is not evidence that an operator's decision
      # was wrong, and the IdP knows nothing about this row.
      group = group!("manual")

      {:ok, _membership} =
        UserGroupMembership.create_membership(
          %{user_id: user.id, group_id: group.id, source: :manual},
          actor: actor()
        )

      result = IdpGroupMemberships.sync(user.id, [], actor: actor())

      assert result.withdrawn == []
      assert [membership] = memberships_for(user.id, group.id)
      assert membership.source == :manual
    end

    test "does not convert an operator's membership into an IdP-managed one", %{user: user} do
      # Converting it would quietly make it withdrawable by a later claim change.
      group = group!("manual")

      {:ok, _membership} =
        UserGroupMembership.create_membership(
          %{user_id: user.id, group_id: group.id, source: :manual},
          actor: actor()
        )

      result = IdpGroupMemberships.sync(user.id, [group.id], actor: actor())

      assert result.added == []
      assert result.kept == [group.id]
      assert [membership] = memberships_for(user.id, group.id)
      assert membership.source == :manual
    end

    test "is idempotent across repeated sign-ins", %{user: user} do
      group = group!("ops")

      IdpGroupMemberships.sync(user.id, [group.id], actor: actor())
      second = IdpGroupMemberships.sync(user.id, [group.id], actor: actor())

      assert second.added == []
      assert second.withdrawn == []
      assert length(memberships_for(user.id, group.id)) == 1
    end
  end

  defp memberships_for(user_id, group_id) do
    UserGroupMembership
    |> Ash.Query.for_read(:by_user, %{user_id: user_id})
    |> Ash.read!(actor: actor())
    |> Enum.filter(&(&1.group_id == group_id))
  end
end
