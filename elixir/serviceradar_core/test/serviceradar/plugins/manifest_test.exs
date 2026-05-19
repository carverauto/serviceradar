defmodule ServiceRadar.Plugins.ManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.Manifest

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

  test "northbound action descriptors parse and normalize" do
    manifest =
      Map.put(@valid_manifest, "actions", [
        %{
          "action_id" => "hpna.disable_port",
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
    assert action.action_id == "hpna.disable_port"
    assert action.scopes == ["interface"]
    assert action.required_context == ["device.ip", "interface.name"]
    assert action.safety_classification == "destructive"
    assert action.requires_confirmation == true
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
end
