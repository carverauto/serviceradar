defmodule ServiceRadar.Edge.AgentConfigGeneratorProtoTest do
  # async: false — the delivery-resumed test temporarily raises the global
  # Logger level to :info (config/test.exs pins :warning, which silently
  # filters the Logger.info line the test asserts on).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Edge.AgentConfigGenerator

  require Logger

  # Params that stay schema-invalid after coercion: the coercion helpers
  # leave unparseable scalars untouched, so this fails integer validation
  # against @netprobe_style_schema (fj#4383 refusal tests).
  @uncoercible_params %{"enabled" => true, "flow_table_max_entries" => "not-a-number"}

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

  describe "add-on config delivery refusal (fj#4383)" do
    test "withholds the add-on section when params stay invalid after coercion" do
      log =
        capture_log(fn ->
          assert render_addons(
                   [netprobe_addon(@uncoercible_params)],
                   "agent-refusal-#{System.unique_integer([:positive])}"
                 ) == []
        end)

      assert log =~ "Refusing add-on config delivery for netprobe"
      assert log =~ "flow_table_max_entries"
    end

    test "other add-ons in the same config still deliver" do
      agent = "agent-partial-#{System.unique_integer([:positive])}"
      parent = self()

      capture_log(fn ->
        send(
          parent,
          {:addons,
           render_addons(
             [
               netprobe_addon(@uncoercible_params),
               netprobe_addon(%{"enabled" => true}, %{addon_id: "otel-collector"})
             ],
             agent
           )}
        )
      end)

      assert_received {:addons, addons}
      assert [%Monitoring.AddonAssignmentConfig{addon_id: "otel-collector"}] = addons
    end

    test "emits delivery_refused telemetry with agent, addon, assignment and errors" do
      agent = "agent-telemetry-#{System.unique_integer([:positive])}"
      handler_id = "delivery-refused-#{agent}"
      parent = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:serviceradar, :addon_config, :delivery_refused],
          fn _event, measurements, metadata, _cfg ->
            send(parent, {:refused, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log(fn ->
        render_addons(
          [netprobe_addon(@uncoercible_params, %{assignment_id: "assignment-123"})],
          agent
        )
      end)

      assert_received {:refused, %{count: 1}, metadata}
      assert metadata.agent_id == agent
      assert metadata.addon_id == "netprobe"
      assert metadata.assignment_id == "assignment-123"
      assert Enum.any?(metadata.errors, &(&1 =~ "flow_table_max_entries"))
    end

    test "error log is deduped for identical refused params and re-fires after recovery" do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      agent = "agent-dedup-#{System.unique_integer([:positive])}"

      first = capture_log(fn -> render_addons([netprobe_addon(@uncoercible_params)], agent) end)
      assert first =~ "Refusing add-on config delivery"

      # Same (agent, addon, params) refusal on the next config cycle: no new
      # error line (the generator runs every poll; refusal must not log-storm).
      second = capture_log(fn -> render_addons([netprobe_addon(@uncoercible_params)], agent) end)
      refute second =~ "Refusing add-on config delivery"

      # Recovery flips the marker (and says so at info)...
      recovered =
        capture_log(fn ->
          assert [_] = render_addons([netprobe_addon(%{"enabled" => true})], agent)
        end)

      assert recovered =~ "Add-on config delivery resumed for netprobe"

      # ...so a re-breakage logs at error again.
      rebroken =
        capture_log(fn -> render_addons([netprobe_addon(@uncoercible_params)], agent) end)

      assert rebroken =~ "Refusing add-on config delivery"
    end
  end

  defp render_addons(addons, agent_id) do
    @base_config
    |> Map.merge(%{agent_id: agent_id, addons: addons})
    |> AgentConfigGenerator.to_proto_response()
    |> Map.fetch!(:addons)
  end

  defp netprobe_addon(params, overrides \\ %{}) do
    Map.merge(
      %{
        addon_id: "netprobe",
        version: "0.1.20",
        enabled: true,
        binary_path: "/usr/local/bin/serviceradar-netprobe",
        args: [],
        params: params,
        config_schema: @netprobe_style_schema
      },
      overrides
    )
  end
end
