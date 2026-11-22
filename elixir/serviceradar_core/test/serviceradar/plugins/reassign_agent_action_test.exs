defmodule ServiceRadar.Plugins.ReassignAgentActionTest do
  use ExUnit.Case, async: true

  alias Ash.Notifier.Notification
  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.DependencyCatalog
  alias ServiceRadar.AgentConfig.DependencyDispatcher
  alias ServiceRadar.AgentConfig.DependencyNotifier
  alias ServiceRadar.Plugins.PluginAssignment

  @moduletag :unit

  defmodule CommandBus do
    @moduledoc false

    def push_config(agent_id) do
      send(self(), {:push_config, agent_id})
      :ok
    end

    def push_config_for_type(config_type) do
      send(self(), {:push_config_for_type, config_type})
      :ok
    end
  end

  defmodule ConfigServer do
    @moduledoc false

    def invalidate(config_type) do
      send(self(), {:invalidate, config_type})
      :ok
    end

    def invalidate(config_type, agents) do
      send(self(), {:invalidate, config_type, agents})
      :ok
    end
  end

  defmodule Diagnostics do
    @moduledoc false

    def record(diagnostic) do
      send(self(), {:diagnostic, diagnostic})
      :ok
    end
  end

  defp system_actor do
    SystemActor.system(:agent_supersession)
  end

  defp viewer_actor do
    %{
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      role: :viewer,
      permissions: MapSet.new()
    }
  end

  describe "PluginAssignment :reassign_agent action" do
    test "changes only agent_uid while preserving id and partition_id" do
      assignment = %PluginAssignment{
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        agent_uid: "agent-old",
        partition_id: "default",
        source: :manual,
        enabled: false
      }

      changeset =
        Ash.Changeset.for_update(
          assignment,
          :reassign_agent,
          %{agent_uid: "agent-replacement"},
          actor: system_actor()
        )

      assert changeset.valid?
      assert Ash.Changeset.get_attribute(changeset, :agent_uid) == "agent-replacement"
      assert Ash.Changeset.get_attribute(changeset, :partition_id) == "default"
      assert changeset.data.id == assignment.id
    end

    test "rejects non-accepted fields such as partition_id" do
      assignment = %PluginAssignment{
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        agent_uid: "agent-old",
        partition_id: "default",
        source: :manual,
        enabled: false
      }

      changeset =
        Ash.Changeset.for_update(
          assignment,
          :reassign_agent,
          %{agent_uid: "agent-replacement", partition_id: "other-partition"},
          actor: system_actor()
        )

      refute changeset.valid?

      assert Enum.any?(
               changeset.errors,
               &match?(%Ash.Error.Invalid.NoSuchInput{input: :partition_id}, &1)
             )
    end

    test "rejects legacy unbound assignments" do
      legacy_unbound = %PluginAssignment{
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        agent_uid: "agent-old",
        partition_id: nil,
        source: :manual,
        enabled: false
      }

      changeset =
        Ash.Changeset.for_update(
          legacy_unbound,
          :reassign_agent,
          %{agent_uid: "agent-replacement"},
          actor: system_actor()
        )

      refute changeset.valid?

      messages = Enum.map_join(changeset.errors, "\n", &Exception.message/1)
      assert messages =~ "legacy unbound assignments"
    end

    test "rejects nil agent_uid" do
      assignment = %PluginAssignment{
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        agent_uid: "agent-old",
        partition_id: "default",
        source: :manual,
        enabled: false
      }

      changeset =
        Ash.Changeset.for_update(
          assignment,
          :reassign_agent,
          %{agent_uid: nil},
          actor: system_actor()
        )

      refute changeset.valid?
    end

    test "authorizes system actor and denies unprivileged viewer" do
      assert Ash.can?({PluginAssignment, :reassign_agent}, system_actor())
      refute Ash.can?({PluginAssignment, :reassign_agent}, viewer_actor())
    end
  end

  describe "DependencyCatalog and DependencyDispatcher for :reassign_agent" do
    test "validates catalog and dispatches targeted push with redacted secrets" do
      assert :ok = DependencyCatalog.validate()
      assert DependencyNotifier in Info.notifiers(PluginAssignment)

      action = Info.action(PluginAssignment, :reassign_agent)
      assert action.type == :update
      assert action.name == :reassign_agent

      notification = %Notification{
        resource: PluginAssignment,
        action: action,
        data: %PluginAssignment{
          id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          agent_uid: "agent-replacement",
          partition_id: "default",
          params: %{"api_token" => "synthetic-secret-value"}
        }
      }

      assert {:ok, [diagnostic]} =
               DependencyDispatcher.dispatch(notification,
                 command_bus: CommandBus,
                 config_server: ConfigServer,
                 diagnostics: Diagnostics
               )

      assert_received {:push_config, "agent-replacement"}
      assert_received {:diagnostic, ^diagnostic}
      refute_received {:push_config, "agent-old"}
      refute_received {:push_config_for_type, :agent}
      refute_received {:invalidate, :agent}

      assert diagnostic.dependency_id == :plugin_assignment_agent_config
      assert diagnostic.config_type == :agent
      assert diagnostic.action_type == :update
      assert diagnostic.affected_agents == ["agent-replacement"]
      assert diagnostic.affected_agent_count == 1
      assert diagnostic.result == :ok
      assert Map.has_key?(diagnostic.secrets, "params")
      refute inspect(diagnostic) =~ "synthetic-secret-value"
    end
  end
end
