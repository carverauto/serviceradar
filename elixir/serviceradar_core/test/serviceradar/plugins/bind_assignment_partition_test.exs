defmodule ServiceRadar.Plugins.Changes.BindAssignmentPartitionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.Changes.BindAssignmentPartition
  alias ServiceRadar.Plugins.PluginAssignment

  @moduletag :unit

  test "names the agent when no authenticated partition can be resolved" do
    changeset =
      PluginAssignment
      |> Ash.Changeset.new()
      |> Ash.Changeset.change_attribute(:agent_uid, "k8s-agent")
      |> BindAssignmentPartition.change(%{}, %{})

    messages = Enum.map_join(changeset.errors, "\n", &Exception.message/1)

    assert messages =~ "k8s-agent"
    assert messages =~ "unavailable" or messages =~ "no live authenticated control session"
  end
end
