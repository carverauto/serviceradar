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

  describe "materialize_config_json/1" do
    test "encodes config_json from deferred payload and logs sweep format and encoded byte sizes" do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      shared_sweep = %{
        "format" => "shared-targets/v1",
        "config_hash" => "0123456789abcdef",
        "device_table" => [
          %{"ref" => "sr:dev-0001", "ip" => "192.0.2.10", "device_uid" => "sr:dev-0001"}
        ],
        "target_sets" => [
          %{
            "key" => "q-1111111111111111",
            "target_query" => "in:devices",
            "refs" => ["sr:dev-0001"]
          }
        ],
        "groups" => [
          %{"id" => "g-1", "sweep_group_id" => "g-1", "device_target_set" => "q-1111111111111111"}
        ]
      }

      payload = %{
        "sweep" => shared_sweep,
        "mapper" => %{"scheduled_jobs" => []}
      }

      log =
        capture_log([level: :info], fn ->
          materialized =
            AgentConfigGenerator.materialize_config_json(%{
              agent_id: "agent-shared-log",
              config_version: "v-shared-1",
              config_json_payload: payload
            })

          refute Map.has_key?(materialized, :config_json_payload)
          assert Jason.decode!(materialized.config_json) == payload
        end)

      expected_sweep_bytes = byte_size(Jason.encode!(shared_sweep))
      assert log =~ "agent_id=agent-shared-log"
      assert log =~ "version=v-shared-1"
      assert log =~ "sweep_format=shared-targets/v1"
      assert log =~ "sweep_groups=1"
      assert log =~ "sweep_bytes=#{expected_sweep_bytes}"

      legacy_sweep = %{
        "config_hash" => "fedcba9876543210",
        "groups" => [
          %{
            "id" => "g-1",
            "sweep_group_id" => "g-1",
            "device_targets" => [
              %{"network" => "192.0.2.10", "metadata" => %{"device_uid" => "sr:dev-0001"}}
            ]
          }
        ]
      }

      legacy_payload = Map.put(payload, "sweep", legacy_sweep)

      legacy_log =
        capture_log([level: :info], fn ->
          materialized =
            AgentConfigGenerator.materialize_config_json(%{
              agent_id: "agent-legacy-log",
              config_version: "v-legacy-1",
              config_json_payload: legacy_payload
            })

          assert Jason.decode!(materialized.config_json) == legacy_payload
        end)

      assert legacy_log =~ "agent_id=agent-legacy-log"
      assert legacy_log =~ "sweep_format=legacy"
      assert legacy_log =~ "sweep_bytes=#{byte_size(Jason.encode!(legacy_sweep))}"
    end
  end

  describe "compute_version_hash/1 (#6033)" do
    alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
    alias ServiceRadar.AgentConfig.Compilers.SweepCompiler

    test "stays identical for identical input and volatile timestamp/token rotation" do
      base = base_version_components()

      assert AgentConfigGenerator.compute_version_hash(base) ==
               AgentConfigGenerator.compute_version_hash(base)

      rotated_volatile =
        base
        |> put_in([:sweep, "compiled_at"], "2026-10-27T04:00:00Z")
        |> put_in([:sync, "generated_at"], "2026-10-27T04:00:00Z")
        |> put_in([:plugins, Access.at(0), :download_token], "rotated-token-2")
        |> put_in([:plugins, Access.at(0), :download_url], "https://edge.example.test/dl/2")
        |> put_in([:addons, Access.at(0), :download_token], "rotated-addon-token-2")

      assert AgentConfigGenerator.compute_version_hash(base) ==
               AgentConfigGenerator.compute_version_hash(rotated_volatile)

      # When config_hash is already computed on sweep and snmp, compute_version_hash/1
      # reuses it rather than re-traversing their group/target lists.
      same_precomputed_hashes =
        base
        |> put_in([:sweep, "groups"], [%{"id" => "untouched-when-config-hash-present"}])
        |> put_in([:snmp, "targets"], [%{"id" => "untouched-when-config-hash-present"}])

      assert AgentConfigGenerator.compute_version_hash(base) ==
               AgentConfigGenerator.compute_version_hash(same_precomputed_hashes)
    end

    test "changes whenever any config component changes" do
      base = base_version_components()
      base_hash = AgentConfigGenerator.compute_version_hash(base)

      changed_sweep_groups = [
        %{
          "id" => "group-1",
          "sweep_group_id" => "group-1",
          "ports" => [22, 443, 8443],
          "modes" => ["icmp", "tcp"],
          "device_targets" => [
            %{"network" => "192.0.2.10", "metadata" => %{"device_uid" => "sr:dev-0001"}}
          ]
        }
      ]

      changed_snmp_raw = %{
        "enabled" => true,
        "profile_id" => "snmp-prof-1",
        "profile_name" => "Core SNMP",
        "targets" => [
          %{
            "id" => "sr:dev-0001",
            "host" => "192.0.2.10",
            "port" => 161,
            "oids" => [%{"oid" => ".1.3.6.1.2.1.1.5.0", "name" => "sysName"}]
          }
        ]
      }

      component_mutations = [
        {:checks, put_in(base, [:checks, Access.at(0), :interval_sec], 120)},
        {:sync, put_in(base, [:sync, "sources", "armis-1", " poll_interval"], 300)},
        {:sweep_targets,
         put_in(base, [:sweep], %{
           "groups" => changed_sweep_groups,
           "compiled_at" => "2026-10-27T03:00:00Z",
           "config_hash" => SweepCompiler.config_hash(changed_sweep_groups)
         })},
        {:sweep_format, put_in(base, [:sweep, "format"], "shared-targets/v1")},
        {:mapper,
         put_in(base, [:mapper, "scheduled_jobs"], [%{"id" => "job-2", "interval" => "10m"}])},
        {:sysmon, put_in(base, [:sysmon, "sample_interval"], "30s")},
        {:snmp,
         put_in(
           base,
           [:snmp],
           Map.put(changed_snmp_raw, "config_hash", SNMPCompiler.config_hash(changed_snmp_raw))
         )},
        {:visibility, put_in(base, [:visibility, "enabled"], true)},
        {:bumblebee, put_in(base, [:bumblebee, "scan_profile"], "servers")},
        {:endpoint_inventory, put_in(base, [:endpoint_inventory, "cadence"], "24h")},
        {:plugins, put_in(base, [:plugins, Access.at(0), :interval_sec], 180)},
        {:plugin_engine_limits, put_in(base, [:plugin_engine_limits, :max_concurrent], 8)},
        {:addons, put_in(base, [:addons, Access.at(0), :version], "0.1.21")}
      ]

      for {component, mutated} <- component_mutations do
        mutated_hash = AgentConfigGenerator.compute_version_hash(mutated)

        assert mutated_hash != base_hash,
               "expected config_version hash to change when #{inspect(component)} changed"
      end
    end

    defp base_version_components do
      sweep_groups = [
        %{
          "id" => "group-1",
          "sweep_group_id" => "group-1",
          "ports" => [22, 443],
          "modes" => ["icmp", "tcp"],
          "device_targets" => [
            %{"network" => "192.0.2.10", "metadata" => %{"device_uid" => "sr:dev-0001"}}
          ]
        }
      ]

      snmp_raw = %{
        "enabled" => true,
        "profile_id" => "snmp-prof-1",
        "profile_name" => "Core SNMP",
        "targets" => [
          %{
            "id" => "sr:dev-0001",
            "host" => "192.0.2.10",
            "port" => 161,
            "oids" => [%{"oid" => ".1.3.6.1.2.1.1.3.0", "name" => "sysUpTime"}]
          }
        ]
      }

      %{
        checks: [
          %{
            check_id: "chk-1",
            check_type: "icmp",
            name: "Ping 1",
            enabled: true,
            interval_sec: 60,
            timeout_sec: 5,
            target: "192.0.2.10",
            port: nil,
            path: nil,
            method: nil,
            settings: %{}
          }
        ],
        sync: %{
          "agent_id" => "agent-1",
          "partition" => "default",
          "generated_at" => "2026-10-27T03:00:00Z",
          "sources" => %{"armis-1" => %{"endpoint" => "https://armis.example.test"}}
        },
        sweep: %{
          "groups" => sweep_groups,
          "compiled_at" => "2026-10-27T03:00:00Z",
          "config_hash" => SweepCompiler.config_hash(sweep_groups)
        },
        mapper: %{"scheduled_jobs" => [%{"id" => "job-1", "interval" => "5m"}]},
        sysmon: %{"enabled" => true, "sample_interval" => "10s"},
        snmp: Map.put(snmp_raw, "config_hash", SNMPCompiler.config_hash(snmp_raw)),
        visibility: %{"enabled" => false},
        bumblebee: %{"enabled" => true, "scan_profile" => "workstations"},
        endpoint_inventory: %{"enabled" => true, "cadence" => "12h"},
        plugins: [
          %{
            assignment_id: "assign-1",
            plugin_id: "http-check",
            interval_sec: 60,
            timeout_sec: 10,
            params: %{"url" => "https://example.test"},
            download_url: "https://edge.example.test/dl/1",
            download_token: "rotated-token-1"
          }
        ],
        plugin_engine_limits: %{max_concurrent: 4},
        addons: [
          %{
            addon_id: "netprobe",
            version: "0.1.20",
            enabled: true,
            binary_path: "/usr/local/bin/serviceradar-netprobe",
            params: %{"enabled" => true},
            download_token: "rotated-addon-token-1"
          }
        ]
      }
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
