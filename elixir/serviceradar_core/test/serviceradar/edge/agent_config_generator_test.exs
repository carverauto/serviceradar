defmodule ServiceRadar.Edge.AgentConfigGeneratorTest do
  @moduledoc """
  Tests for the AgentConfigGenerator module.

  Tests config generation from database, version hashing, and not_modified behavior.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Monitoring.ServiceCheck

  @moduletag :database

  setup do
    unique_id = :erlang.unique_integer([:positive])
    tenant_id = Ash.UUID.generate()

    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :super_admin,
      tenant_id: tenant_id
    }

    agent_uid = "test-agent-#{unique_id}"

    {:ok, tenant_id: tenant_id, actor: actor, agent_uid: agent_uid, unique_id: unique_id}
  end

  describe "generate_config/2" do
    test "returns empty config when no checks exist", %{tenant_id: tenant_id, agent_uid: agent_uid} do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      assert config.checks == []
      assert config.heartbeat_interval_sec == 30
      assert config.config_poll_interval_sec == 300
      assert String.starts_with?(config.config_version, "v")
      assert config.config_timestamp > 0
    end

    test "generates config with checks", %{tenant_id: tenant_id, actor: actor, agent_uid: agent_uid, unique_id: unique_id} do
      # Create a service check for this agent (enabled by default)
      {:ok, _check} =
        ServiceCheck
        |> Ash.Changeset.for_create(:create, %{
          name: "Test HTTP Check #{unique_id}",
          check_type: :http,
          target: "https://example.com",
          port: 443,
          interval_seconds: 60,
          timeout_seconds: 10,
          agent_uid: agent_uid
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      assert length(config.checks) == 1
      [check] = config.checks
      assert check.name == "Test HTTP Check #{unique_id}"
      assert check.check_type == "http"
      assert check.target == "https://example.com"
      assert check.port == 443
      assert check.interval_sec == 60
      assert check.timeout_sec == 10
      assert check.enabled == true
    end

    test "excludes disabled checks", %{tenant_id: tenant_id, actor: actor, agent_uid: agent_uid, unique_id: unique_id} do
      # Create enabled check (enabled by default)
      {:ok, _enabled} =
        ServiceCheck
        |> Ash.Changeset.for_create(:create, %{
          name: "Enabled Check #{unique_id}",
          check_type: :tcp,
          target: "10.0.0.1",
          port: 22,
          agent_uid: agent_uid
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Create check then disable it
      {:ok, disabled_check} =
        ServiceCheck
        |> Ash.Changeset.for_create(:create, %{
          name: "Disabled Check #{unique_id}",
          check_type: :tcp,
          target: "10.0.0.2",
          port: 22,
          agent_uid: agent_uid
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Disable the check
      {:ok, _} =
        disabled_check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      # Only enabled check should be included
      assert length(config.checks) == 1
      assert hd(config.checks).name == "Enabled Check #{unique_id}"
    end
  end

  describe "get_config_if_changed/3" do
    test "returns :not_modified when version matches", %{tenant_id: tenant_id, agent_uid: agent_uid} do
      # First, get the config to obtain the version
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      # Request with the same version
      result = AgentConfigGenerator.get_config_if_changed(agent_uid, tenant_id, config.config_version)

      assert result == :not_modified
    end

    test "returns config when version differs", %{tenant_id: tenant_id, agent_uid: agent_uid} do
      result = AgentConfigGenerator.get_config_if_changed(agent_uid, tenant_id, "v-old-version")

      assert {:ok, config} = result
      assert config.config_version != "v-old-version"
    end

    test "returns config when version is empty", %{tenant_id: tenant_id, agent_uid: agent_uid} do
      result = AgentConfigGenerator.get_config_if_changed(agent_uid, tenant_id, "")

      assert {:ok, _config} = result
    end
  end

  describe "to_proto_checks/1" do
    test "converts check config to proto format" do
      check = %{
        check_id: "123",
        check_type: "http",
        name: "Test Check",
        enabled: true,
        interval_sec: 60,
        timeout_sec: 10,
        target: "https://example.com",
        port: 443,
        path: "/health",
        method: "GET",
        settings: %{"header_Host" => "example.com"}
      }

      [proto_check] = AgentConfigGenerator.to_proto_checks([check])

      assert proto_check.check_id == "123"
      assert proto_check.check_type == "http"
      assert proto_check.name == "Test Check"
      assert proto_check.enabled == true
      assert proto_check.interval_sec == 60
      assert proto_check.timeout_sec == 10
      assert proto_check.target == "https://example.com"
      assert proto_check.port == 443
      assert proto_check.path == "/health"
      assert proto_check.method == "GET"
      assert proto_check.settings == %{"header_Host" => "example.com"}
    end

    test "handles nil values with defaults" do
      check = %{
        check_id: "456",
        check_type: "tcp",
        name: "TCP Check",
        enabled: true,
        interval_sec: 30,
        timeout_sec: 5,
        target: nil,
        port: nil,
        path: nil,
        method: nil,
        settings: nil
      }

      [proto_check] = AgentConfigGenerator.to_proto_checks([check])

      assert proto_check.target == ""
      assert proto_check.port == 0
      assert proto_check.path == ""
      assert proto_check.method == ""
      assert proto_check.settings == %{}
    end
  end

  describe "version hash stability" do
    test "same config produces same version hash", %{tenant_id: tenant_id, agent_uid: agent_uid} do
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      # Version hash should be deterministic
      assert config1.config_version == config2.config_version
    end

    test "different checks produce different version hash", %{tenant_id: tenant_id, actor: actor, agent_uid: agent_uid, unique_id: unique_id} do
      # Get initial config
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      # Add a check (enabled by default)
      {:ok, _check} =
        ServiceCheck
        |> Ash.Changeset.for_create(:create, %{
          name: "New Check #{unique_id}",
          check_type: :ping,
          target: "10.0.0.100",
          agent_uid: agent_uid
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Get config again
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      # Version should be different now
      assert config1.config_version != config2.config_version
    end
  end
end
