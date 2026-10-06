defmodule ServiceRadar.Identity.Changes.RecordRoleChangeTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Identity.Changes.RecordRoleChange
  alias ServiceRadar.Identity.User

  describe "resource action contract" do
    test "RecordRoleChange is wired into user role mutation actions" do
      for action_name <- [
            :create,
            :update_role,
            :update_role_profile,
            :clear_role_profile_for_boundary
          ] do
        action = Info.action(User, action_name)
        assert action != nil, "action #{action_name} should exist on User"

        has_change? =
          Enum.any?(action.changes, fn
            %{change: {RecordRoleChange, _}} -> true
            %{change: RecordRoleChange} -> true
            _ -> false
          end)

        assert has_change?, "action #{action_name} must include RecordRoleChange"
      end
    end
  end

  describe "change/3 and atomic/3 lifecycle" do
    test "registers after_action hook by default" do
      changeset =
        User
        |> Ash.Changeset.new()
        |> RecordRoleChange.change([], %{})

      assert length(changeset.after_action) == 1
    end

    test "skips after_action hook when skip_role_change_audit is true" do
      changeset =
        User
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_context(%{skip_role_change_audit: true})
        |> RecordRoleChange.change([], %{})

      assert changeset.after_action == []
    end

    test "atomic/3 returns {:ok, changeset} with hook" do
      changeset = Ash.Changeset.new(User)
      assert {:ok, updated} = RecordRoleChange.atomic(changeset, [], %{})
      assert length(updated.after_action) == 1
    end
  end
end
