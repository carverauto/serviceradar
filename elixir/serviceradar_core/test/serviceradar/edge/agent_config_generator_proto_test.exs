defmodule ServiceRadar.Edge.AgentConfigGeneratorProtoTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator

  @base_config %{
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
    visibility_config: nil
  }

  @netprobe_style_schema %{
    "type" => "object",
    "properties" => %{
      "enabled" => %{"type" => "boolean", "default" => false},
      "capture_interfaces" => %{
        "type" => "array",
        "items" => %{"type" => "string", "minLength" => 1}
      },
      "flow_table_max_entries" => %{"type" => "integer", "minimum" => 0, "default" => 0}
    }
  }

  defp addon_config_json(params, config_schema) do
    response =
      AgentConfigGenerator.to_proto_response(
        Map.put(@base_config, :addons, [
          %{
            addon_id: "netprobe",
            version: "0.1.20",
            enabled: true,
            binary_path: "/usr/local/bin/serviceradar-netprobe",
            args: [],
            params: params,
            config_schema: config_schema
          }
        ])
      )

    assert [%Monitoring.AddonAssignmentConfig{} = addon] = response.addons
    addon.config_json
  end

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

  describe "add-on config_json delivery coercion (fj#4381)" do
    test "coerces a scalar-string capture_interfaces to a single-element list" do
      # The demo flow-attribution outage: a corrupt assignment row stored
      # `capture_interfaces` as a scalar string and it shipped verbatim,
      # permanently failing the agent-side []string decode.
      config_json =
        addon_config_json(
          %{"enabled" => true, "capture_interfaces" => " ens18 "},
          @netprobe_style_schema
        )

      assert Jason.decode!(config_json) == %{
               "enabled" => true,
               "capture_interfaces" => ["ens18"]
             }
    end

    test "leaves valid params byte-identical (golden, proxmox-style params)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "endpoint" => %{"type" => "string"},
          "verify_tls" => %{"type" => "boolean", "default" => true},
          "poll_interval_s" => %{"type" => "integer", "minimum" => 10},
          "node_allowlist" => %{"type" => "array", "items" => %{"type" => "string"}},
          "template" => %{
            "type" => "object",
            "properties" => %{
              "host" => %{"type" => "string"},
              "port" => %{"type" => "integer"}
            }
          }
        }
      }

      params = %{
        "endpoint" => "https://pve.example.net:8006",
        "verify_tls" => false,
        "poll_interval_s" => 60,
        "node_allowlist" => ["pve01", "pve02"],
        "template" => %{"host" => "pve.example.net", "port" => 8006}
      }

      assert addon_config_json(params, schema) == Jason.encode!(params)
    end

    test "passes params through unchanged when the package has no config schema" do
      # A package that declares no schema gives delivery nothing to coerce
      # against; the params ship as stored.
      params = %{"capture_interfaces" => "ens18"}

      assert addon_config_json(params, nil) == Jason.encode!(params)
      assert addon_config_json(params, %{}) == Jason.encode!(params)
    end
  end
end
