defmodule ServiceRadar.Integrations.ReassignAgentActionTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Invalid.NoSuchInput
  alias Ash.Notifier.Notification
  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.DependencyCatalog
  alias ServiceRadar.AgentConfig.DependencyDispatcher
  alias ServiceRadar.AgentConfig.DependencyNotifier
  alias ServiceRadar.Events.AuditNotifier
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationSourceNotifier
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.SNMPProfiles.SNMPProfile

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

  defp actor_with_role(role) do
    %{
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      role: role,
      permissions: MapSet.new()
    }
  end

  defp sample_source do
    %IntegrationSource{
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      name: "example-source",
      source_type: :custom,
      endpoint: "https://example.invalid/api",
      agent_id: "agent-old",
      partition: "default"
    }
  end

  describe "IntegrationSource :reassign_agent action" do
    test "changes only agent_id and bypasses agent availability check unlike :update" do
      source = sample_source()

      update_changeset =
        Ash.Changeset.for_update(source, :update, %{agent_id: "agent-replacement"},
          actor: system_actor()
        )

      refute update_changeset.valid?

      assert Enum.any?(
               update_changeset.errors,
               &(Exception.message(&1) =~
                   "install and register an agent before adding integrations")
             )

      reassign_changeset =
        Ash.Changeset.for_update(source, :reassign_agent, %{agent_id: "agent-replacement"},
          actor: system_actor()
        )

      assert reassign_changeset.valid?
      assert Ash.Changeset.get_attribute(reassign_changeset, :agent_id) == "agent-replacement"
      assert Ash.Changeset.get_attribute(reassign_changeset, :endpoint) == source.endpoint
      assert Ash.Changeset.get_attribute(reassign_changeset, :partition) == source.partition
      assert reassign_changeset.data.id == source.id
    end

    test "rejects non-accepted fields such as endpoint and credentials" do
      source = sample_source()

      endpoint_changeset =
        Ash.Changeset.for_update(
          source,
          :reassign_agent,
          %{agent_id: "agent-replacement", endpoint: "https://other.invalid/api"},
          actor: system_actor()
        )

      refute endpoint_changeset.valid?

      assert Enum.any?(
               endpoint_changeset.errors,
               &match?(%NoSuchInput{input: :endpoint}, &1)
             )

      creds_changeset =
        Ash.Changeset.for_update(
          source,
          :reassign_agent,
          %{agent_id: "agent-replacement", credentials: %{"api_key" => "synthetic"}},
          actor: system_actor()
        )

      refute creds_changeset.valid?

      assert Enum.any?(
               creds_changeset.errors,
               &match?(%NoSuchInput{input: :credentials}, &1)
             )
    end

    test "rejects nil and blank agent_id" do
      source = sample_source()

      for invalid_agent_id <- [nil, "", "   "] do
        changeset =
          Ash.Changeset.for_update(
            source,
            :reassign_agent,
            %{agent_id: invalid_agent_id},
            actor: system_actor()
          )

        refute changeset.valid?
      end
    end

    test "authorizes only system actors while keeping admin access to :update" do
      assert Ash.can?({IntegrationSource, :reassign_agent}, system_actor())
      refute Ash.can?({IntegrationSource, :reassign_agent}, actor_with_role(:admin))
      refute Ash.can?({IntegrationSource, :reassign_agent}, actor_with_role(:operator))
      refute Ash.can?({IntegrationSource, :reassign_agent}, actor_with_role(:viewer))
      refute Ash.can?({IntegrationSource, :reassign_agent}, nil)

      assert Ash.can?({IntegrationSource, :update}, actor_with_role(:admin))
    end
  end

  describe "DependencyCatalog, DependencyDispatcher, and audit formatting for supersession handoffs" do
    test "validates catalog and dispatches targeted sync config push on IntegrationSource :reassign_agent" do
      assert :ok = DependencyCatalog.validate()
      assert IntegrationSourceNotifier in Info.notifiers(IntegrationSource)

      action = Info.action(IntegrationSource, :reassign_agent)
      assert action.type == :update
      assert action.name == :reassign_agent

      notification = %Notification{
        resource: IntegrationSource,
        action: action,
        data: %{
          id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          name: "example-source",
          agent_id: "agent-replacement",
          credentials: %{
            "api_key" => "synthetic-api-key",
            "api_secret" => "synthetic-api-secret"
          }
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
      refute_received {:push_config_for_type, :sync}
      refute_received {:invalidate, :sync}

      assert diagnostic.dependency_id == :integration_source_sync_config
      assert diagnostic.config_type == :sync
      assert diagnostic.action_type == :update
      assert diagnostic.affected_agents == ["agent-replacement"]
      assert diagnostic.affected_agent_count == 1
      assert diagnostic.result == :ok
      assert diagnostic.secrets["api_key"] == true
      assert diagnostic.secrets["api_secret"] == true
      refute inspect(diagnostic) =~ "synthetic-api-key"
      refute inspect(diagnostic) =~ "synthetic-api-secret"

      audit_opts =
        AuditNotifier.build_opts(notification,
          resource_type: "integration_source",
          resource_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          resource_name: "example-source"
        )

      assert {:ok, event} = AuditWriter.build_event(audit_opts)
      assert event.activity_name == "Update"
      assert event.unmapped["action"] == "reassign_agent"
    end

    test "SNMPProfile :update invalidates snmp and mapper configs and ServiceCheck :update pushes to replacement agent" do
      assert DependencyNotifier in Info.notifiers(SNMPProfile)
      assert DependencyNotifier in Info.notifiers(ServiceCheck)

      snmp_notification = %Notification{
        resource: SNMPProfile,
        action: Info.action(SNMPProfile, :update),
        data: %SNMPProfile{
          id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          name: "example-snmp-profile",
          agent_ids: ["agent-replacement"]
        }
      }

      assert {:ok, snmp_diagnostics} =
               DependencyDispatcher.dispatch(snmp_notification,
                 command_bus: CommandBus,
                 config_server: ConfigServer,
                 diagnostics: Diagnostics
               )

      assert_received {:invalidate, :snmp}
      assert_received {:invalidate, :mapper}
      assert Enum.sort(Enum.map(snmp_diagnostics, & &1.config_type)) == [:mapper, :snmp]

      check = %ServiceCheck{
        id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        name: "example-check",
        check_type: :ping,
        target: "198.18.0.10",
        agent_uid: "agent-old"
      }

      check_changeset =
        Ash.Changeset.for_update(check, :update, %{agent_uid: "agent-replacement"},
          actor: system_actor()
        )

      assert check_changeset.valid?
      assert Ash.Changeset.get_attribute(check_changeset, :agent_uid) == "agent-replacement"

      check_notification = %Notification{
        resource: ServiceCheck,
        action: Info.action(ServiceCheck, :update),
        data: %{check | agent_uid: "agent-replacement"}
      }

      assert {:ok, [check_diagnostic]} =
               DependencyDispatcher.dispatch(check_notification,
                 command_bus: CommandBus,
                 config_server: ConfigServer,
                 diagnostics: Diagnostics
               )

      assert_received {:push_config, "agent-replacement"}
      refute_received {:push_config, "agent-old"}
      assert check_diagnostic.dependency_id == :service_check_agent_config
      assert check_diagnostic.config_type == :agent
      assert check_diagnostic.affected_agents == ["agent-replacement"]
    end
  end
end
