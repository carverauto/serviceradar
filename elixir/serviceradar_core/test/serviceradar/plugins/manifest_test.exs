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
    manifest =
      @valid_manifest
      |> put_in(["resources", "requested_memory_mb"], -1)

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

  test "config schema validation accepts JSON object" do
    schema = ~S({"type":"object","properties":{"interval":{"type":"string"}}})
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
