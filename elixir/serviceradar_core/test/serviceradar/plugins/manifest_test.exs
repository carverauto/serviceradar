defmodule ServiceRadar.Plugins.ManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.IntegrationDescriptor
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @wasm_plugins_root Path.expand("../../../../../go/cmd/wasm-plugins", __DIR__)
  @first_party_config_schema_paths (case Path.wildcard(
                                           Path.join(
                                             @wasm_plugins_root,
                                             "**/config*.schema.json"
                                           )
                                         ) do
                                      [] -> raise "no first-party Wasm config schemas found"
                                      paths -> paths
                                    end)
  @first_party_manifest_paths (case Path.wildcard(
                                      Path.join(@wasm_plugins_root, "**/plugin*.yaml")
                                    ) do
                                 [] -> raise "no first-party Wasm manifests found"
                                 paths -> paths
                               end)

  for path <- @first_party_config_schema_paths do
    @external_resource path
  end

  for path <- @first_party_manifest_paths do
    @external_resource path
  end

  @valid_manifest %{
    "id" => "http-checker",
    "name" => "HTTP Checker",
    "version" => "1.0.0",
    "description" => "Checks HTTP endpoints",
    "entrypoint" => "run_check",
    "runtime" => "wasi-preview1",
    "capabilities" => ["get_config", "log", "submit_result", "http_request"],
    "permissions" => %{
      "allowed_domains" => ["api.example.com"],
      "allowed_ports" => [80, 443]
    },
    "resources" => %{
      "requested_memory_mb" => 32,
      "requested_cpu_ms" => 5000,
      "max_open_connections" => 8
    },
    "outputs" => "serviceradar.plugin_result.v1",
    "schema_version" => 1,
    "display_contract" => %{"schema_version" => 1, "widgets" => ["stat_card"]},
    "source" => %{
      "repo_url" => "https://github.com/example/http-checker",
      "commit" => "abc123",
      "license" => "Apache-2.0"
    }
  }

  test "valid manifest map parses and normalizes" do
    assert {:ok, manifest} = Manifest.from_map(@valid_manifest)
    assert manifest.id == "http-checker"
    assert manifest.runtime == "wasi-preview1"
    assert manifest.outputs == "serviceradar.plugin_result.v1"
    assert manifest.resources.requested_memory_mb == 32
    assert manifest.schema_version == 1
  end

  test "every first-party Wasm package passes the same manifest contract" do
    for path <- @first_party_manifest_paths do
      assert {:ok, _manifest} = path |> File.read!() |> Manifest.from_yaml(), path
    end
  end

  test "signal schema declarations parse and normalize" do
    signal_schema = %{
      "id" => "com.carverauto.sample.dns_activity",
      "version" => "1.0.0",
      "signal_type" => "event",
      "payload_kind" => "ocsf_event",
      "payload_schema" => "schemas/dns_activity.schema.json",
      "display_contract" => "display/dns_activity.display.json",
      "display_contract_id" => "com.carverauto.sample.dns_activity.display",
      "display_contract_version" => "1.0.0",
      "ocsf_schema_version" => "1.5.0",
      "class_uid" => 4003,
      "type_uid" => 400_301
    }

    manifest = Map.put(@valid_manifest, "signal_schemas", [signal_schema])

    assert {:ok, parsed} = Manifest.from_map(manifest)
    assert [parsed_schema] = parsed.signal_schemas
    assert parsed_schema["id"] == "com.carverauto.sample.dns_activity"
    assert parsed_schema["payload_kind"] == "ocsf_event"
    assert parsed_schema["display_contract"] == "display/dns_activity.display.json"
    assert parsed_schema["class_uid"] == 4003
  end

  test "signal schema declarations reject unsafe contract shapes" do
    manifest =
      Map.put(@valid_manifest, "signal_schemas", [
        %{
          "id" => "Bad.Schema",
          "version" => "not-semver",
          "signal_type" => "metric",
          "payload_kind" => "unknown",
          "payload_schema" => "../dns_activity.schema.json",
          "display_contract" => "/display/dns_activity.display.json",
          "display_contract_id" => "com.carverauto.sample.display",
          "display_contract_version" => "1.0.0",
          "html" => "<script></script>"
        }
      ])

    assert {:error, errors} = Manifest.from_map(manifest)
    joined = Enum.join(errors, "\n")

    assert joined =~ "signal_schemas[1].id must use lowercase"
    assert joined =~ "signal_schemas[1].version must be a valid semver string"
    assert joined =~ "signal_schemas[1].signal_type must be one of"
    assert joined =~ "signal_schemas[1].payload_kind must be one of"
    assert joined =~ "signal_schemas[1].payload_schema must not traverse directories"
    assert joined =~ "signal_schemas[1].display_contract must be a relative bundle path"
    assert joined =~ "signal_schemas[1].html is not allowed"
  end

  test "producer schedule declarations parse and normalize" do
    manifest =
      @valid_manifest
      |> Map.put("capabilities", [
        "get_config",
        "log",
        "submit_result",
        "artifact-staging:v1",
        "advisory-feed:v1",
        "producer-schedule:v1",
        "action-result-ingest:v1"
      ])
      |> Map.put("producer_schedules", [
        %{
          "schedule_id" => "cisa_kev_refresh",
          "label" => "Refresh CISA KEV",
          "description" => "Downloads and emits normalized advisory batches",
          "action_id" => "advisory.refresh",
          "command_type" => "plugin.run_action",
          "default_cadence_seconds" => 86_400,
          "min_cadence_seconds" => 3_600,
          "max_cadence_seconds" => 2_592_000,
          "allow_cron" => true,
          "jitter_seconds" => 300,
          "settings_schema" => %{"type" => "object"},
          "credential_requirements" => %{"refs" => ["vulncheck_api"]},
          "payload_template" => %{"feed_key" => "cisa-kev"},
          "redaction" => %{"credential_refs" => true},
          "dispatch_scope" => "assignment",
          "timeout_seconds" => 600
        }
      ])

    assert {:ok, parsed} = Manifest.from_map(manifest)
    assert [schedule] = parsed.producer_schedules
    assert schedule["schedule_id"] == "cisa_kev_refresh"
    assert schedule["command_type"] == "plugin.run_action"
    assert schedule["action_id"] == "advisory.refresh"
    assert schedule["default_cadence_seconds"] == 86_400
    assert schedule["settings_schema"] == %{"type" => "object"}
    assert "action-result-ingest:v1" in parsed.capabilities
  end

  test "producer schedule declarations reject unsafe or incomplete shapes" do
    manifest =
      Map.put(@valid_manifest, "producer_schedules", [
        %{
          "schedule_id" => "Bad Schedule",
          "label" => "Bad Schedule",
          "command_type" => "provider.refresh",
          "default_cadence_seconds" => 10,
          "min_cadence_seconds" => 30,
          "max_cadence_seconds" => 20,
          "dispatch_scope" => "provider",
          "settings_schema" => [],
          "html" => "<script></script>"
        }
      ])

    assert {:error, errors} = Manifest.from_map(manifest)
    joined = Enum.join(errors, "\n")

    assert joined =~ "producer_schedules[1].schedule_id must use lowercase"
    assert joined =~ "producer_schedules[1].command_type must be one of"
    assert joined =~ "producer_schedules[1].min_cadence_seconds must be <= max_cadence_seconds"
    assert joined =~ "producer_schedules[1].dispatch_scope must be one of"
    assert joined =~ "producer_schedules[1].settings_schema must be a map"
    assert joined =~ "producer_schedules[1].html is not allowed"
  end

  test "signed packages declare credential and inventory integrations without core code" do
    manifest = integration_manifest()

    assert {:ok, parsed} = Manifest.from_map(manifest)

    assert [profile] = parsed.integrations["credential_profiles"]
    assert profile["provider"] == "example-inventory"
    assert profile["provisioning"]["schedule_id"] == "example-inventory.refresh"
    assert [method] = profile["auth_methods"]
    assert method["label"] == "Username and password"
    assert Enum.map(method["fields"], & &1["id"]) == ["username", "password"]
    assert method["payload"] == %{"format" => "json"}
    refute Map.has_key?(method, "description")
    refute Enum.any?(method, fn {_key, value} -> value == "nil" end)

    assert [source] = parsed.integrations["inventory_sources"]
    assert source["source"] == "example-inventory"

    assert source["metadata_fields"] == [
             %{"key" => "site", "label" => "Site", "format" => "text"}
           ]

    assert parsed.integrations["documentation"]["path"] == "docs/configuration.md"

    assert parsed.integrations["documentation"]["url"] ==
             "https://plugins.example.test/example-inventory/v1.0.0/configuration"
  end

  test "inventory sources may advertise emitted facts" do
    manifest =
      update_in(
        integration_manifest(),
        ["integrations", "inventory_sources", Access.at(0)],
        &Map.put(&1, "emitted_facts", ["switch_port_attachment", "vlan_uid"])
      )

    assert {:ok, parsed} = Manifest.from_map(manifest)
    assert [source] = parsed.integrations["inventory_sources"]
    assert source["emitted_facts"] == ["switch_port_attachment", "vlan_uid"]
  end

  test "plugin manifests must not declare fact winners" do
    manifest =
      update_in(
        integration_manifest(),
        ["integrations", "inventory_sources", Access.at(0)],
        &Map.put(&1, "winner", true)
      )

    assert {:error, errors} = Manifest.from_map(manifest)

    assert Enum.any?(errors, fn error ->
             String.contains?(error, "winner") and
               String.contains?(error, "must not declare fact authority")
           end)
  end

  test "plugin manifests must not declare precedence" do
    manifest = put_in(integration_manifest(), ["integrations", "precedence"], ["armis"])
    assert {:error, errors} = Manifest.from_map(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "precedence"))
  end

  test "integration documentation rejects non-HTTPS URLs" do
    manifest =
      put_in(
        integration_manifest(),
        ["integrations", "documentation", "url"],
        "javascript:alert(1)"
      )

    assert {:error, errors} = Manifest.from_map(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "must be an HTTPS URL"))
  end

  test "integration descriptors reject defaults for secret fields" do
    manifest =
      put_in(
        integration_manifest(),
        [
          "integrations",
          "credential_profiles",
          Access.at(0),
          "auth_methods",
          Access.at(0),
          "fields",
          Access.at(1),
          "default"
        ],
        "must-not-ship-in-a-package"
      )

    assert {:error, errors} = Manifest.from_map(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "default is not allowed for secret fields"))
  end

  test "integration descriptors reject malformed HTTP methods without raising" do
    profile =
      put_in(
        CredentialIntegrationFixtures.target_policy_profile(),
        ["provisioning", "consumers", Access.at(0), "grant", "allow", "methods"],
        [%{"unexpected" => "map"}]
      )

    assert {:error, errors} =
             IntegrationDescriptor.validate(%{"credential_profiles" => [profile]}, [])

    assert Enum.any?(errors, &String.contains?(&1, "unsupported HTTP method"))
  end

  test "integration descriptors reject undeclared schedules and credential requirements" do
    manifest =
      put_in(
        integration_manifest(),
        ["integrations", "credential_profiles", Access.at(0), "provisioning", "schedule_id"],
        "missing.refresh"
      )

    assert {:error, errors} = Manifest.from_map(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "must reference a declared producer schedule"))

    manifest =
      put_in(
        integration_manifest(),
        [
          "integrations",
          "credential_profiles",
          Access.at(0),
          "provisioning",
          "credential_requirement"
        ],
        "missing_account"
      )

    assert {:error, errors} = Manifest.from_map(manifest)

    assert Enum.any?(
             errors,
             &String.contains?(&1, "must reference a requirement on the producer schedule")
           )
  end

  test "northbound action descriptors parse and normalize" do
    manifest =
      Map.put(@valid_manifest, "actions", [
        %{
          "action_id" => "example-network.disable_port",
          "version" => "1.0.0",
          "label" => "Disable switch port",
          "description" => "Calls external NMS to disable an interface",
          "scopes" => ["interface"],
          "required_context" => ["device.ip", "interface.name"],
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"reason" => %{"type" => "string"}}
          },
          "timeout_seconds" => 120,
          "safety_classification" => "destructive",
          "requires_confirmation" => true
        }
      ])

    assert {:ok, parsed} = Manifest.from_map(manifest)
    assert [action] = parsed.actions
    assert action.action_id == "example-network.disable_port"
    assert action.scopes == ["interface"]
    assert action.required_context == ["device.ip", "interface.name"]
    assert action.safety_classification == "destructive"
    assert action.requires_confirmation == true
  end

  test "northbound actions declare a maximum run override duration only when set" do
    action = %{
      "action_id" => "demo.inject_fault",
      "label" => "Inject fault",
      "scopes" => ["device"]
    }

    manifest =
      Map.put(@valid_manifest, "actions", [
        Map.put(action, "max_override_duration_seconds", 1800),
        Map.put(action, "action_id", "demo.status")
      ])

    assert {:ok, parsed} = Manifest.from_map(manifest)
    assert [with_max, without_max] = parsed.actions
    assert with_max.max_override_duration_seconds == 1800
    # Absent rather than nil, so existing descriptors keep their hash.
    refute Map.has_key?(without_max, :max_override_duration_seconds)

    assert {:error, errors} =
             Manifest.from_map(
               Map.put(@valid_manifest, "actions", [
                 Map.put(action, "max_override_duration_seconds", 0)
               ])
             )

    assert "actions[1].max_override_duration_seconds must be a positive integer" in errors
  end

  test "northbound action descriptors reject provider-owned UI code" do
    manifest =
      Map.put(@valid_manifest, "actions", [
        %{
          "action_id" => "bad.action",
          "label" => "Bad Action",
          "scopes" => ["device"],
          "html" => "<script>alert('no')</script>"
        }
      ])

    assert {:error, errors} = Manifest.from_map(manifest)

    assert Enum.any?(
             errors,
             &String.contains?(&1, "actions[1].html is not allowed")
           )
  end

  test "missing required fields return errors" do
    assert {:error, errors} = Manifest.from_map(%{})
    assert "missing required field: id" in errors
    assert "missing required field: name" in errors
    assert "missing required field: version" in errors
  end

  test "invalid capabilities are rejected" do
    manifest = Map.put(@valid_manifest, "capabilities", ["get_config", "exec_shell"])
    assert {:error, errors} = Manifest.from_map(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "unsupported"))
  end

  test "grpc_request capability is accepted" do
    manifest =
      @valid_manifest
      |> Map.put("capabilities", ["get_config", "log", "submit_result", "grpc_request"])
      |> Map.put("permissions", %{
        "allowed_networks" => ["192.0.2.0/24"],
        "allowed_ports" => [9200]
      })

    assert {:ok, parsed} = Manifest.from_map(manifest)
    assert "grpc_request" in parsed.capabilities
  end

  test "invalid semver is rejected" do
    manifest = Map.put(@valid_manifest, "version", "version1")
    assert {:error, errors} = Manifest.from_map(manifest)
    assert "version must be a valid semver string" in errors
  end

  test "resource requests must be positive integers" do
    manifest = put_in(@valid_manifest, ["resources", "requested_memory_mb"], -1)

    assert {:error, errors} = Manifest.from_map(manifest)
    assert "resources.requested_memory_mb must be a positive integer" in errors
  end

  test "yaml manifest parses" do
    yaml = """
    id: http-checker
    name: HTTP Checker
    version: 1.0.0
    entrypoint: run_check
    runtime: wasi-preview1
    capabilities:
      - get_config
      - log
      - submit_result
      - http_request
    permissions:
      allowed_domains:
        - api.example.com
    resources:
      requested_memory_mb: 32
      requested_cpu_ms: 5000
      max_open_connections: 8
    outputs: serviceradar.plugin_result.v1
    """

    assert {:ok, _manifest} = Manifest.from_yaml(yaml)
  end

  test "camera stream manifest parses" do
    yaml = """
    id: axis-camera-stream
    name: AXIS Camera Stream
    version: 0.1.0
    entrypoint: stream_camera
    runtime: wasi-preview1
    capabilities:
      - get_config
      - log
      - camera_media_stream
      - http_request
      - tcp_connect
      - tcp_read
      - tcp_write
      - tcp_close
    permissions:
      allowed_domains:
        - "*"
      allowed_ports:
        - 554
    resources:
      requested_memory_mb: 64
      requested_cpu_ms: 2000
      max_open_connections: 1
    outputs: serviceradar.camera_stream.v1
    """

    assert {:ok, manifest} = Manifest.from_yaml(yaml)
    assert manifest.outputs == "serviceradar.camera_stream.v1"
  end

  test "proxmox console stream manifest parses" do
    yaml = """
    id: proxmox-console
    name: Proxmox Console
    version: 0.1.0
    entrypoint: run_console
    runtime: wasi-preview1
    capabilities:
      - get_config
      - log
      - proxmox_console_stream
      - tcp_connect
      - tcp_read
      - tcp_write
      - tcp_close
      - websocket_connect
      - websocket_send
      - websocket_recv
      - websocket_close
    permissions:
      allowed_domains:
        - "*"
      allowed_ports:
        - 22
        - 8006
    resources:
      requested_memory_mb: 64
      requested_cpu_ms: 2000
      max_open_connections: 2
    outputs: serviceradar.proxmox_console.v1
    """

    assert {:ok, manifest} = Manifest.from_yaml(yaml)
    assert manifest.outputs == "serviceradar.proxmox_console.v1"
    assert "proxmox_console_stream" in manifest.capabilities
  end

  test "rejects yaml aliases and anchors" do
    yaml = """
    defaults: &defaults
      id: bad
    <<: *defaults
    """

    assert {:error, errors} = Manifest.parse_yaml_map(yaml)
    assert "yaml anchors and aliases are not allowed" in errors
  end

  test "config schema validation accepts JSON object" do
    schema = ~S({"type":"object","properties":{"interval":{"type":"string"}}})
    assert :ok == Manifest.validate_config_schema(schema)
  end

  test "config schema validation accepts every first-party Wasm plugin schema" do
    Enum.each(@first_party_config_schema_paths, fn path ->
      schema = path |> File.read!() |> Jason.decode!()

      assert :ok == Manifest.validate_config_schema(schema),
             "invalid first-party config schema: #{Path.relative_to(path, @wasm_plugins_root)}"
    end)
  end

  test "every bundled first-party manifest and companion schema passes the real import validator" do
    for manifest_path <- @first_party_manifest_paths do
      {:ok, manifest_map} = manifest_path |> File.read!() |> Manifest.parse_yaml_map()

      config_schema =
        case companion_config_schema_path(manifest_path) do
          nil -> nil
          schema_path -> schema_path |> File.read!() |> Jason.decode!()
        end

      changeset =
        Ash.Changeset.for_create(ServiceRadar.Plugins.PluginPackage, :create, %{
          manifest: manifest_map,
          config_schema: config_schema
        })

      assert :ok == ServiceRadar.Plugins.Validations.Manifest.validate(changeset, [], %{}),
             "bundled first-party manifest failed import validation: #{Path.relative_to(manifest_path, @wasm_plugins_root)}"
    end
  end

  defp companion_config_schema_path(manifest_path) do
    dir = Path.dirname(manifest_path)
    filename = Path.basename(manifest_path)

    schema_name =
      cond do
        filename == "plugin.yaml" ->
          "config.schema.json"

        String.starts_with?(filename, "plugin.") and String.ends_with?(filename, ".yaml") ->
          variant = filename |> String.trim_leading("plugin.") |> String.trim_trailing(".yaml")
          "config.#{variant}.schema.json"

        true ->
          nil
      end

    if schema_name do
      candidate = Path.join(dir, schema_name)
      if File.exists?(candidate), do: candidate
    end
  end

  test "config schema validation accepts vendor extensions and password format annotations" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "ssh" => %{
          "type" => "object",
          "x-serviceradar-ui-hidden" => true,
          "properties" => %{
            "password" => %{
              "type" => "string",
              "format" => "password",
              "x-serviceradar-sensitive" => true
            }
          }
        }
      }
    }

    assert :ok == Manifest.validate_config_schema(schema)
  end

  test "config schema validation rejects non-object JSON" do
    schema = ~S(["bad"])
    assert {:error, errors} = Manifest.validate_config_schema(schema)
    assert "config schema must be a JSON object" in errors
  end

  test "config schema validation rejects unsupported keys" do
    schema = %{
      "type" => "object",
      "properties" => %{"url" => %{"type" => "string", "foo" => "bar"}}
    }

    assert {:error, errors} = Manifest.validate_config_schema(schema)
    assert Enum.any?(errors, &String.contains?(&1, "unsupported keys"))
  end

  describe "snmp_requirements" do
    @valid_snmp_requirement %{
      "name" => "clearpass-node-health",
      "description" => "Node CPU, disk, version and role from CLEARPASS-MIB.",
      "category" => "system",
      "default_poll_interval_seconds" => 300,
      "default_timeout_seconds" => 5,
      "default_retries" => 3,
      "target_hint" => "in:devices device_type:clearpass",
      "oids" => [
        %{
          "oid" => ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.16.0",
          "name" => "node_cpu_pct",
          "data_type" => "gauge"
        },
        %{
          "oid" => ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2",
          "name" => "service_name",
          "data_type" => "string",
          "mode" => "walk",
          "max_rows" => 256,
          "walk_timeout_seconds" => 20
        }
      ]
    }

    test "a well-formed block parses, including a walked table" do
      assert {:ok, manifest} = Manifest.from_map(with_snmp([@valid_snmp_requirement]))
      assert [requirement] = manifest.snmp_requirements
      assert requirement["name"] == "clearpass-node-health"
      assert [_get, walk] = requirement["oids"]
      assert walk["mode"] == "walk"
      assert walk["max_rows"] == 256
    end

    test "a manifest without the block is unaffected" do
      assert {:ok, manifest} = Manifest.from_map(@valid_manifest)
      assert manifest.snmp_requirements == []
    end

    # The centralized-credentials rule, enforced structurally. A plugin that
    # could name a community string or a credential secret would reintroduce
    # per-plugin credential configuration through a side door.
    test "no credential key is expressible" do
      for key <- ~w(version community username security_level auth_protocol
                    auth_password priv_protocol priv_password credential_secret_id) do
        requirement = Map.put(@valid_snmp_requirement, key, "anything")

        assert {:error, errors} = Manifest.from_map(with_snmp([requirement]))

        assert Enum.any?(
                 errors,
                 &String.contains?(&1, "snmp_requirements[1].#{key} is not allowed")
               ),
               "#{key} was accepted: #{inspect(errors)}"
      end
    end

    # A package must not be able to start probing real inventory, become the
    # instance default, or outrank an operator's own profile.
    test "no polling-control key is expressible" do
      for {key, value} <- [
            {"enabled", true},
            {"is_default", true},
            {"priority", 100},
            {"agent_ids", ["agent-1"]},
            {"host", "10.0.0.1"},
            {"port", 161}
          ] do
        requirement = Map.put(@valid_snmp_requirement, key, value)

        assert {:error, errors} = Manifest.from_map(with_snmp([requirement]))

        assert Enum.any?(
                 errors,
                 &String.contains?(&1, "snmp_requirements[1].#{key} is not allowed")
               ),
               "#{key} was accepted: #{inspect(errors)}"
      end
    end

    test "an unknown key is an error rather than an ignored value" do
      requirement = Map.put(@valid_snmp_requirement, "cadence", 60)

      assert {:error, errors} = Manifest.from_map(with_snmp([requirement]))

      assert Enum.any?(
               errors,
               &String.contains?(&1, "snmp_requirements[1].cadence is not allowed")
             )
    end

    # These are the agent's own rules. They are enforced at import because
    # ValidateForAgent drops a target it cannot use: a malformed OID would
    # otherwise be accepted into a package, materialize into a profile, and then
    # silently collect nothing.
    test "an OID the agent would reject is refused at import" do
      cases = [
        {%{"oid" => "1.3.6.1.2.1.1.3.0"}, "must start with .1.3.6.1."},
        {%{"oid" => ".1.3.6.1.4.x.1"}, "must start with .1.3.6.1."},
        {%{"data_type" => "widget"}, "data_type must be one of"},
        {%{"mode" => "sweep"}, "mode must be one of"},
        {%{"name" => String.duplicate("a", 65)}, "at most 64 bytes"},
        {%{"name" => ""}, "must be a non-empty string"},
        {%{"scale" => -1}, "scale must be a non-negative number"},
        {%{"max_rows" => -1}, "max_rows must be a non-negative number"}
      ]

      for {override, expected} <- cases do
        oid =
          Map.merge(
            %{"oid" => ".1.3.6.1.2.1.1.3.0", "name" => "x", "data_type" => "gauge"},
            override
          )

        requirement = Map.put(@valid_snmp_requirement, "oids", [oid])

        assert {:error, errors} = Manifest.from_map(with_snmp([requirement]))

        assert Enum.any?(errors, &String.contains?(&1, expected)),
               "#{inspect(override)} was accepted; expected #{expected}, got #{inspect(errors)}"
      end
    end

    test "an empty oid list is refused" do
      requirement = Map.put(@valid_snmp_requirement, "oids", [])

      assert {:error, errors} = Manifest.from_map(with_snmp([requirement]))
      assert Enum.any?(errors, &String.contains?(&1, "oids must be a non-empty list"))
    end

    test "a non-positive default is refused" do
      requirement = Map.put(@valid_snmp_requirement, "default_retries", 0)

      assert {:error, errors} = Manifest.from_map(with_snmp([requirement]))

      assert Enum.any?(
               errors,
               &String.contains?(&1, "default_retries must be a positive integer")
             )
    end

    # Validation reads through normalize_string, so an OID with surrounding
    # whitespace validates fine. Storing the raw value would then materialize a
    # template the agent rejects on isValidOID, and the target would be dropped
    # silently at the far end rather than refused here.
    test "stored oids are normalized, not merely validated" do
      requirement =
        Map.put(@valid_snmp_requirement, "oids", [
          %{
            "oid" => " .1.3.6.1.2.1.1.3.0 ",
            "name" => " uptime ",
            "data_type" => "gauge",
            "mode" => " walk "
          }
        ])

      assert {:ok, manifest} = Manifest.from_map(with_snmp([requirement]))

      assert [%{"oid" => oid, "name" => name, "mode" => mode}] =
               hd(manifest.snmp_requirements)["oids"]

      assert oid == ".1.3.6.1.2.1.1.3.0"
      assert name == "uptime"
      assert mode == "walk"
    end

    test "the block itself must be a list" do
      assert {:error, errors} = Manifest.from_map(with_snmp(%{"name" => "x"}))
      assert Enum.any?(errors, &String.contains?(&1, "snmp_requirements must be a list"))
    end
  end

  defp with_snmp(requirements), do: Map.put(@valid_manifest, "snmp_requirements", requirements)

  defp integration_manifest do
    @valid_manifest
    |> Map.put("capabilities", @valid_manifest["capabilities"] ++ ["producer-schedule:v1"])
    |> Map.put("producer_schedules", [
      %{
        "schedule_id" => "example-inventory.refresh",
        "label" => "Refresh example inventory",
        "action_id" => "example-inventory.refresh",
        "command_type" => "plugin.run_action",
        "default_cadence_seconds" => 86_400,
        "min_cadence_seconds" => 3_600,
        "max_cadence_seconds" => 2_592_000,
        "dispatch_scope" => "assignment",
        "credential_requirements" => %{
          "inventory_account" => %{
            "required" => true,
            "resolution_location" => "agent",
            "grants" => []
          }
        }
      }
    ])
    |> Map.put("integrations", %{
      "documentation" => %{
        "title" => "Example inventory configuration",
        "path" => "docs/configuration.md",
        "url" => "https://plugins.example.test/example-inventory/v1.0.0/configuration"
      },
      "credential_profiles" => [
        %{
          "provider" => "example-inventory",
          "label" => "Example Inventory",
          "auth_methods" => [
            %{
              "id" => "username_password",
              "label" => "Username and password",
              "credential_kind" => "username_password",
              "fields" => [
                %{
                  "id" => "username",
                  "label" => "Username",
                  "control" => "text",
                  "required" => true,
                  "secret" => false,
                  "public" => true
                },
                %{
                  "id" => "password",
                  "label" => "Password",
                  "control" => "password",
                  "required" => true,
                  "secret" => true
                }
              ]
            }
          ],
          "purposes" => ["device_inventory"],
          "scope_types" => ["agent"],
          "provisioning" => %{
            "mode" => "producer_schedule",
            "schedule_id" => "example-inventory.refresh",
            "credential_requirement" => "inventory_account"
          }
        }
      ],
      "inventory_sources" => [
        %{
          "source" => "example-inventory",
          "label" => "Example Inventory",
          "metadata_fields" => [
            %{"key" => "site", "label" => "Site", "format" => "text"}
          ]
        }
      ]
    })
  end

  describe "producer_schedule provisioning with schedule_ids" do
    # One credential rule, several schedules of the same package: an inventory
    # refresh and a faster telemetry poll sharing one vendor account.
    defp multi_schedule_manifest(provisioning_overrides, schedule_overrides \\ %{}) do
      manifest = integration_manifest()
      [refresh] = manifest["producer_schedules"]

      telemetry =
        Map.merge(
          %{
            refresh
            | "schedule_id" => "example-inventory.telemetry",
              "label" => "Collect example telemetry",
              "action_id" => "example-inventory.telemetry",
              "default_cadence_seconds" => 60,
              "min_cadence_seconds" => 30
          },
          schedule_overrides
        )

      manifest
      |> Map.put("producer_schedules", [refresh, telemetry])
      |> update_in(
        ["integrations", "credential_profiles", Access.at(0), "provisioning"],
        fn provisioning ->
          provisioning
          |> Map.delete("schedule_id")
          |> Map.merge(provisioning_overrides)
        end
      )
    end

    defp provisioning_errors(manifest) do
      assert {:error, errors} = Manifest.from_map(manifest)
      Enum.filter(errors, &String.contains?(&1, ".provisioning"))
    end

    test "a list of declared schedules sharing the requirement parses in order" do
      manifest =
        multi_schedule_manifest(%{
          "schedule_ids" => ["example-inventory.refresh", "example-inventory.telemetry"]
        })

      assert {:ok, parsed} = Manifest.from_map(manifest)
      assert [profile] = parsed.integrations["credential_profiles"]

      assert profile["provisioning"] == %{
               "mode" => "producer_schedule",
               "schedule_ids" => ["example-inventory.refresh", "example-inventory.telemetry"],
               "credential_requirement" => "inventory_account"
             }

      assert IntegrationDescriptor.producer_schedule_ids(profile["provisioning"]) == [
               "example-inventory.refresh",
               "example-inventory.telemetry"
             ]
    end

    test "a single schedule_id still normalizes without a schedule_ids key" do
      assert {:ok, parsed} = Manifest.from_map(integration_manifest())
      assert [profile] = parsed.integrations["credential_profiles"]

      assert profile["provisioning"] == %{
               "mode" => "producer_schedule",
               "schedule_id" => "example-inventory.refresh",
               "credential_requirement" => "inventory_account"
             }

      assert IntegrationDescriptor.producer_schedule_ids(profile["provisioning"]) == [
               "example-inventory.refresh"
             ]
    end

    test "declaring both schedule_id and schedule_ids is rejected" do
      manifest =
        multi_schedule_manifest(%{
          "schedule_id" => "example-inventory.refresh",
          "schedule_ids" => ["example-inventory.telemetry"]
        })

      assert [error] = provisioning_errors(manifest)
      assert error =~ "must declare exactly one of schedule_id or schedule_ids, not both"
    end

    test "declaring neither schedule_id nor schedule_ids is rejected" do
      assert [error] = provisioning_errors(multi_schedule_manifest(%{}))
      assert error =~ "provisioning must declare schedule_id or schedule_ids"
    end

    test "an undeclared schedule id is named with its position" do
      manifest =
        multi_schedule_manifest(%{
          "schedule_ids" => ["example-inventory.refresh", "example-inventory.missing"]
        })

      assert [error] = provisioning_errors(manifest)

      assert error =~
               "provisioning.schedule_ids[2] (example-inventory.missing) must reference a declared producer schedule"
    end

    test "every listed schedule must declare the named credential requirement" do
      manifest =
        multi_schedule_manifest(
          %{"schedule_ids" => ["example-inventory.refresh", "example-inventory.telemetry"]},
          %{"credential_requirements" => %{"telemetry_account" => %{"required" => true}}}
        )

      assert [error] = provisioning_errors(manifest)

      assert error =~
               "provisioning.schedule_ids[2] (example-inventory.telemetry) must declare credential requirement inventory_account"
    end

    test "duplicate schedule ids are rejected" do
      manifest =
        multi_schedule_manifest(%{
          "schedule_ids" => [
            "example-inventory.refresh",
            "example-inventory.telemetry",
            "example-inventory.refresh"
          ]
        })

      assert [error] = provisioning_errors(manifest)

      assert error =~
               "provisioning.schedule_ids contains duplicate schedule_id example-inventory.refresh"
    end

    test "an empty or non-list schedule_ids is rejected" do
      for value <- [[], "example-inventory.refresh"] do
        assert [error] = provisioning_errors(multi_schedule_manifest(%{"schedule_ids" => value}))

        assert error =~
                 "provisioning.schedule_ids must be a non-empty list with at most 8 entries"
      end
    end
  end

  describe "declared action credential sources" do
    defp source_action(requirements) do
      %{
        "action_id" => "example-inventory.move_device",
        "label" => "Move device between accounts",
        "scopes" => ["device"],
        "safety_classification" => "destructive",
        "requires_confirmation" => true,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"destination_rule_id" => %{"type" => "string"}}
        },
        "credential_requirements" => requirements
      }
    end

    defp with_source_action(requirements) do
      Map.put(integration_manifest(), "actions", [source_action(requirements)])
    end

    test "accepts assignment_schedule and package_rule requirements" do
      requirements = %{
        "source_account" => %{
          "credential_source" => "assignment_schedule",
          "requirement" => "inventory_account",
          "required" => true,
          "allow" => %{"methods" => ["POST"], "hosts" => ["api.example.com"]}
        },
        "destination_account" => %{
          "credential_source" => "package_rule",
          "rule_input" => "destination_rule_id",
          "required" => true
        }
      }

      assert {:ok, parsed} = Manifest.from_map(with_source_action(requirements))
      assert [%{credential_requirements: ^requirements}] = parsed.actions
    end

    test "rejects an unknown credential_source" do
      assert {:error, errors} =
               Manifest.from_map(
                 with_source_action(%{"api" => %{"credential_source" => "operator_input"}})
               )

      assert "actions[1].credential_requirements.api.credential_source must be one of: assignment_schedule, package_rule" in errors
    end

    test "rejects source keys without a credential_source" do
      assert {:error, errors} =
               Manifest.from_map(
                 with_source_action(%{
                   "credentials" => [
                     %{"name" => "api", "secret_input" => "api_secret", "requirement" => "x"}
                   ]
                 })
               )

      assert "actions[1].credential_requirements.api.requirement is only allowed with credential_source" in errors
    end

    test "rejects a declared source combined with a secret or secret input" do
      assert {:error, errors} =
               Manifest.from_map(
                 with_source_action(%{
                   "api" => %{
                     "credential_source" => "package_rule",
                     "rule_input" => "destination_rule_id",
                     "credential_secret_input" => "destination_rule_id"
                   }
                 })
               )

      assert "actions[1].credential_requirements.api.credential_secret_input is not allowed with credential_source; the source supplies the secret" in errors
    end

    test "requires a schedule requirement the package provisions" do
      assert {:error, errors} =
               Manifest.from_map(
                 with_source_action(%{
                   "api" => %{
                     "credential_source" => "assignment_schedule",
                     "requirement" => "other_account"
                   }
                 })
               )

      assert "actions[1].credential_requirements.api.requirement must name the credential_requirement of a producer_schedule credential profile in integrations.credential_profiles" in errors

      assert {:error, errors} =
               Manifest.from_map(
                 with_source_action(%{
                   "api" => %{"credential_source" => "assignment_schedule"}
                 })
               )

      assert "actions[1].credential_requirements.api.requirement must be a non-empty string" in errors
    end

    test "requires a rule_input declared in the input schema" do
      assert {:error, errors} =
               Manifest.from_map(
                 with_source_action(%{
                   "api" => %{
                     "credential_source" => "package_rule",
                     "rule_input" => "undeclared_rule_id"
                   }
                 })
               )

      assert "actions[1].credential_requirements.api.rule_input must name a string property declared in input_schema.properties" in errors
    end

    test "requires package rule inputs to use string properties" do
      manifest =
        %{
          "api" => %{
            "credential_source" => "package_rule",
            "rule_input" => "destination_rule_id"
          }
        }
        |> with_source_action()
        |> Map.update!("actions", fn [action] ->
          action
          |> put_in(["input_schema", "properties", "destination_rule_id", "type"], "integer")
          |> then(&[&1])
        end)

      assert {:error, errors} = Manifest.from_map(manifest)

      assert "actions[1].credential_requirements.api.rule_input must name a string property declared in input_schema.properties" in errors
    end

    test "package_rule needs a producer_schedule credential profile" do
      manifest =
        Map.put(@valid_manifest, "actions", [
          source_action(%{
            "api" => %{
              "credential_source" => "package_rule",
              "rule_input" => "destination_rule_id"
            }
          })
        ])

      assert {:error, errors} = Manifest.from_map(manifest)

      assert "actions[1].credential_requirements.api.credential_source package_rule requires a producer_schedule credential profile in integrations.credential_profiles" in errors
    end
  end

  describe "producer schedule target_input" do
    defp schedule_manifest(target_input) do
      @valid_manifest
      |> Map.put("capabilities", ["get_config", "log", "submit_result", "producer-schedule:v1"])
      |> Map.put("producer_schedules", [
        %{
          "schedule_id" => "interface_check",
          "label" => "Interface check",
          "action_id" => "interface.check",
          "command_type" => "plugin.run_action",
          "default_cadence_seconds" => 3_600,
          "min_cadence_seconds" => 300,
          "max_cadence_seconds" => 86_400,
          "target_input" => target_input
        }
      ])
    end

    test "normalizes a valid target_input into the contract" do
      assert {:ok, parsed} =
               Manifest.from_map(
                 schedule_manifest(%{
                   "query_param" => "target_query",
                   "fields_param" => "target_fields"
                 })
               )

      assert [schedule] = parsed.producer_schedules

      assert schedule["target_input"] == %{
               "entity" => "devices",
               "query_param" => "target_query",
               "fields_param" => "target_fields",
               "max_items" => 500
             }
    end

    test "rejects malformed target_input" do
      for bad <- [
            %{"fields_param" => "target_fields"},
            %{"query_param" => "Target Query"},
            %{"query_param" => "target_query", "entity" => "interfaces"},
            %{"query_param" => "target_query", "max_items" => 5_000},
            %{"query_param" => "target_query", "surprise" => true},
            "target_query"
          ] do
        assert {:error, errors} = Manifest.from_map(schedule_manifest(bad))
        assert Enum.join(errors, " ") =~ "target_input"
      end
    end
  end
end
