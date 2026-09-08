defmodule ServiceRadar.Edge.AgentConfigVisibilityProtoTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator

  @moduletag :visibility

  test "visibility_config is included in proto responses" do
    visibility = %Monitoring.VisibilityConfig{
      enabled: true,
      capture_interfaces: ["en0"],
      binary_overrides: %Monitoring.VisibilityBinaryOverrides{path: "/tmp/netprobe"},
      default_sample_interval_ms: 250,
      flow_table_max_entries: 262_144,
      dpi: %Monitoring.VisibilityDpiConfig{enabled: true, protocols: ["dns", "tls"]},
      device_bindings: [
        %Monitoring.VisibilityDeviceBinding{
          ip: "192.0.2.10",
          profile_id: "profile-1",
          profile_name: "Linux servers",
          fingerprint: %Monitoring.VisibilityFingerprintConfig{
            tcp: true,
            tls: true,
            http: false
          },
          dpi: %Monitoring.VisibilityDpiConfig{enabled: true, protocols: ["dns"]},
          sample_interval_ms: 500
        }
      ]
    }

    response =
      AgentConfigGenerator.to_proto_response(%{
        config_version: "v-test",
        config_timestamp: 1,
        heartbeat_interval_sec: 30,
        config_poll_interval_sec: 300,
        checks: [],
        plugins: [],
        plugin_engine_limits: %{},
        config_json: <<>>,
        sysmon_config: nil,
        snmp_config: nil,
        visibility_config: visibility
      })

    assert response.visibility_config == visibility
  end
end
