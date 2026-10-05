defmodule ServiceRadar.Plugins.Changes.RejectPolicyOwnedAssignmentDestroyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment

  @moduletag :unit

  defp destroy_changeset(source, actor) do
    # for_destroy runs the destroy action's changes at build time with the
    # given actor, which is the same path Ash.destroy takes.
    Ash.Changeset.for_destroy(%PluginAssignment{source: source}, :destroy, %{}, actor: actor)
  end

  defp plugin_manager do
    %{
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      role: :operator,
      permissions: MapSet.new(["settings.plugins.manage"])
    }
  end

  test "rejects destroy of a policy-owned assignment by a plugin manager" do
    changeset = destroy_changeset(:policy, plugin_manager())

    refute changeset.valid?

    messages = Enum.map_join(changeset.errors, "\n", &Exception.message/1)

    assert messages =~ "trusted system process"
  end

  test "allows a plugin manager to destroy a manual assignment" do
    changeset = destroy_changeset(:manual, plugin_manager())

    assert changeset.valid?
  end

  test "allows a system actor to destroy a policy-owned assignment" do
    changeset =
      destroy_changeset(:policy, SystemActor.system(:reject_policy_owned_assignment_destroy_test))

    assert changeset.valid?
  end
end
