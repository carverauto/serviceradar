defmodule ServiceRadar.Edge.AgentConfigGeneratorProtoTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator

  describe "to_proto_response/1" do
    test "includes typed bumblebee config" do
      response =
        AgentConfigGenerator.to_proto_response(%{
          config_version: "v-test",
          config_timestamp: 1_700_000_000,
          heartbeat_interval_sec: 30,
          config_poll_interval_sec: 300,
          checks: [],
          plugins: [],
          plugin_engine_limits: %{},
          config_json: <<>>,
          sysmon_config: nil,
          snmp_config: nil,
          visibility_config: nil,
          bumblebee_config: %Monitoring.BumblebeeConfig{
            enabled: true,
            agent_id: "agent-1",
            root_discovery_mode: "all_users",
            findings_only: true,
            catalog: %Monitoring.BumblebeeCatalogAssignment{
              snapshot_ref: "snapshot-1",
              object_key: "bumblebee/catalogs/snapshot-1/catalog.json",
              sha256: "deadbeef",
              size_bytes: 42
            }
          }
        })

      assert response.bumblebee_config.enabled
      assert response.bumblebee_config.agent_id == "agent-1"
      assert response.bumblebee_config.root_discovery_mode == "all_users"
      assert response.bumblebee_config.findings_only
      assert response.bumblebee_config.catalog.snapshot_ref == "snapshot-1"
      assert response.bumblebee_config.catalog.size_bytes == 42
    end
  end
end
