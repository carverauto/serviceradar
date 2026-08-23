defmodule ServiceRadar.AgentConfig.DependencyCatalogTest do
  use ExUnit.Case, async: false

  alias Ash.Notifier.Notification
  alias ServiceRadar.AgentConfig.DependencyCatalog
  alias ServiceRadar.AgentConfig.DependencyCatalog.Entry
  alias ServiceRadar.AgentConfig.DependencyDiagnostics
  alias ServiceRadar.AgentConfig.DependencyDispatcher
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.SyncConfigGenerator
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile

  @moduletag :requires_app

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
  end

  defmodule Diagnostics do
    @moduledoc false
    def record(diagnostic) do
      send(self(), {:diagnostic, diagnostic})
      :ok
    end
  end

  describe "catalog validation" do
    test "default catalog is valid" do
      assert :ok = DependencyCatalog.validate()
    end

    test "known generator source resources are represented in the catalog" do
      covered_resources = MapSet.new(DependencyCatalog.entries(), & &1.resource)

      missing =
        Enum.reject(
          DependencyCatalog.required_source_resources(),
          &MapSet.member?(covered_resources, &1)
        )

      assert missing == []
    end

    test "cataloged resources have notifier wiring or an explicit exception" do
      custom_notifier_resources = MapSet.new([IntegrationSource])
      intentionally_unwired_resources = MapSet.new([ServiceRadar.Inventory.Device])

      unwired_entries =
        Enum.reject(DependencyCatalog.entries(), fn entry ->
          notifiers = Ash.Resource.Info.notifiers(entry.resource)

          ServiceRadar.AgentConfig.DependencyNotifier in notifiers or
            entry.resource in custom_notifier_resources or
            entry.resource in intentionally_unwired_resources
        end)

      assert unwired_entries == []
    end

    test "validation rejects duplicate dependency ids" do
      [entry | _] = DependencyCatalog.entries()

      assert {:error, errors} = DependencyCatalog.validate([entry, entry])
      assert Enum.any?(errors, &String.contains?(&1, "duplicate dependency id"))
    end
  end

  describe "integration source dependency" do
    test "declares sync config dependency with scoped affected-agent resolver" do
      [entry] = DependencyCatalog.for_resource(IntegrationSource)

      assert entry.config_type == :sync
      assert entry.generator == SyncConfigGenerator
      assert entry.dispatch == :push_affected_agents
      assert DependencyCatalog.affected_agents(entry, %{agent_id: "agent-a"}) == ["agent-a"]
    end

    test "diagnostics redact secret values while exposing presence" do
      [entry] = DependencyCatalog.for_resource(IntegrationSource)

      diagnostics =
        DependencyCatalog.diagnostics(entry, %{
          agent_id: "agent-a",
          credentials: %{
            "api_key" => "visible-in-config-but-not-diagnostics",
            "api_secret" => "do-not-log"
          }
        })

      assert diagnostics.affected_agents == ["agent-a"]
      assert diagnostics.secrets["api_key"] == true
      assert diagnostics.secrets["api_secret"] == true
      refute inspect(diagnostics) =~ "do-not-log"
      refute inspect(diagnostics) =~ "visible-in-config-but-not-diagnostics"
    end

    test "dispatcher pushes only the affected assigned agent for IntegrationSource updates" do
      notification = %Notification{
        resource: IntegrationSource,
        action: %{type: :update, name: :update},
        data: %{agent_id: "agent-a"}
      }

      assert {:ok, [diagnostic]} =
               DependencyDispatcher.dispatch(notification,
                 command_bus: CommandBus,
                 config_server: ConfigServer,
                 diagnostics: Diagnostics
               )

      assert_received {:push_config, "agent-a"}
      assert_received {:diagnostic, ^diagnostic}
      refute_received {:push_config, "agent-b"}
      refute_received {:push_config_for_type, :sync}
      refute_received {:invalidate, :sync}

      assert diagnostic.config_type == :sync
      assert diagnostic.action_type == :update
      assert diagnostic.affected_agents == ["agent-a"]
      assert diagnostic.affected_agent_count == 1
      assert diagnostic.result == :ok
    end

    test "runtime sync status updates do not trigger config pushes" do
      for action_name <- [
            :sync_start,
            :sync_success,
            :sync_failed,
            :record_sync,
            :northbound_start,
            :northbound_success,
            :northbound_failed
          ] do
        notification = %Notification{
          resource: IntegrationSource,
          action: %{type: :update, name: action_name},
          data: %{agent_id: "agent-a"}
        }

        assert [] = DependencyCatalog.for_notification(notification)
      end
    end
  end

  describe "low-churn resource dependencies" do
    test "service check config dependency matches only config-changing actions" do
      update_notification = %Notification{
        resource: ServiceCheck,
        action: %{type: :update, name: :update},
        data: %{agent_uid: "agent-a"}
      }

      runtime_notification = %Notification{
        resource: ServiceCheck,
        action: %{type: :update, name: :record_result},
        data: %{agent_uid: "agent-a"}
      }

      assert [_entry] = DependencyCatalog.for_notification(update_notification)
      assert [] = DependencyCatalog.for_notification(runtime_notification)
    end

    test "plugin assignment update dispatches only its assigned agent" do
      notification = %Notification{
        resource: PluginAssignment,
        action: %{type: :update, name: :update},
        data: %{agent_uid: "agent-plugin"}
      }

      assert {:ok, [diagnostic]} =
               DependencyDispatcher.dispatch(notification,
                 command_bus: CommandBus,
                 config_server: ConfigServer,
                 diagnostics: Diagnostics
               )

      assert_received {:push_config, "agent-plugin"}
      refute_received {:push_config_for_type, :agent}
      refute_received {:invalidate, :agent}

      assert diagnostic.dependency_id == :plugin_assignment_agent_config
      assert diagnostic.affected_agents == ["agent-plugin"]
      assert diagnostic.affected_agent_count == 1
      assert diagnostic.result == :ok
    end

    test "plugin package review actions dispatch fleet agent config refreshes" do
      approve_notification = %Notification{
        resource: PluginPackage,
        action: %{type: :update, name: :approve},
        data: %{}
      }

      staged_import_notification = %Notification{
        resource: PluginPackage,
        action: %{type: :create, name: :create},
        data: %{}
      }

      assert [entry] = DependencyCatalog.for_notification(approve_notification)
      assert entry.config_type == :agent
      assert [] = DependencyCatalog.for_notification(staged_import_notification)
    end

    test "agent config dependency ignores heartbeat and gateway sync actions" do
      update_notification = %Notification{
        resource: Agent,
        action: %{type: :update, name: :update},
        data: %{uid: "agent-a"}
      }

      heartbeat_notification = %Notification{
        resource: Agent,
        action: %{type: :update, name: :heartbeat},
        data: %{uid: "agent-a"}
      }

      gateway_sync_notification = %Notification{
        resource: Agent,
        action: %{type: :update, name: :gateway_sync},
        data: %{uid: "agent-a"}
      }

      assert [entry] = DependencyCatalog.for_notification(update_notification)
      assert entry.config_type == :agent
      assert DependencyCatalog.affected_agents(entry, update_notification.data) == ["agent-a"]
      assert [] = DependencyCatalog.for_notification(heartbeat_notification)
      assert [] = DependencyCatalog.for_notification(gateway_sync_notification)
    end

    test "sweep and mapper runtime actions are excluded from config invalidation" do
      sweep_runtime_notification = %Notification{
        resource: SweepGroup,
        action: %{type: :update, name: :record_execution},
        data: %{}
      }

      mapper_runtime_notification = %Notification{
        resource: MapperJob,
        action: %{type: :update, name: :record_run},
        data: %{}
      }

      assert [] = DependencyCatalog.for_notification(sweep_runtime_notification)
      assert [] = DependencyCatalog.for_notification(mapper_runtime_notification)
    end

    test "compiled config resources dispatch invalidation through the catalog" do
      notification = %Notification{
        resource: SweepProfile,
        action: %{type: :update, name: :update},
        data: %{}
      }

      assert {:ok, [diagnostic]} =
               DependencyDispatcher.dispatch(notification,
                 command_bus: CommandBus,
                 config_server: ConfigServer,
                 diagnostics: Diagnostics
               )

      assert_received {:invalidate, :sweep}
      assert_received {:diagnostic, ^diagnostic}
      refute_received {:push_config_for_type, :sweep}

      assert diagnostic.dependency_id == :sweep_profile_config
      assert diagnostic.config_type == :sweep
      assert diagnostic.affected_agents == :all_online
      assert diagnostic.affected_agent_count == :all_online
      assert diagnostic.result == :ok
    end

    test "SNMP default profile actions match the catalog" do
      notification = %Notification{
        resource: SNMPProfile,
        action: %{type: :update, name: :set_as_default},
        data: %{}
      }

      assert [entry] = DependencyCatalog.for_notification(notification)
      assert entry.config_type == :snmp
    end
  end

  describe "entry validation" do
    test "validation rejects missing resolver functions" do
      entry = %Entry{
        id: :bad_resolver,
        resource: IntegrationSource,
        config_type: :sync,
        generator: SyncConfigGenerator,
        lifecycle_actions: [:update],
        affected_agents: {__MODULE__, :missing_resolver, []},
        dispatch: :push_affected_agents
      }

      assert {:error, errors} = DependencyCatalog.validate([entry])
      assert Enum.any?(errors, &String.contains?(&1, "invalid affected-agent resolver"))
    end
  end

  describe "dependency diagnostics recorder" do
    test "records recent redacted diagnostics newest first" do
      DependencyDiagnostics.clear()

      assert :ok = DependencyDiagnostics.record(%{dependency_id: :older, secrets: %{}})

      assert :ok =
               DependencyDiagnostics.record(%{
                 dependency_id: :newer,
                 secrets: %{"api_secret" => true}
               })

      assert [
               %{dependency_id: :newer, secrets: %{"api_secret" => true}},
               %{dependency_id: :older}
             ] = DependencyDiagnostics.recent(2)
    end

    test "records default timestamps without microseconds" do
      DependencyDiagnostics.clear()

      assert :ok = DependencyDiagnostics.record(%{dependency_id: :timestamp_check, secrets: %{}})

      assert [%{recorded_at: recorded_at}] = DependencyDiagnostics.recent(1)
      assert recorded_at.microsecond == {0, 0}
    end

    test "truncates supplied recorded_at timestamps" do
      DependencyDiagnostics.clear()

      assert :ok =
               DependencyDiagnostics.record(%{
                 dependency_id: :supplied_timestamp_check,
                 secrets: %{},
                 recorded_at: ~U[2026-05-15 18:00:08.246357Z]
               })

      assert [%{recorded_at: recorded_at}] = DependencyDiagnostics.recent(1)
      assert recorded_at == ~U[2026-05-15 18:00:08Z]
    end
  end
end
