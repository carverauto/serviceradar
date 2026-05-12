defmodule ServiceRadar.AgentConfig.DependencyCatalogTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentConfig.DependencyCatalog
  alias ServiceRadar.AgentConfig.DependencyCatalog.Entry
  alias ServiceRadar.AgentConfig.DependencyDispatcher
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.SyncConfigGenerator

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
      notification = %Ash.Notifier.Notification{
        resource: IntegrationSource,
        action: %{type: :update},
        data: %{agent_id: "agent-a"}
      }

      assert :ok =
               DependencyDispatcher.dispatch(notification,
                 command_bus: CommandBus,
                 config_server: ConfigServer
               )

      assert_received {:push_config, "agent-a"}
      refute_received {:push_config, "agent-b"}
      refute_received {:push_config_for_type, :sync}
      refute_received {:invalidate, :sync}
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
end
