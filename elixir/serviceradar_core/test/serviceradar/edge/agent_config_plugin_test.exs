defmodule ServiceRadar.Edge.AgentConfigPluginTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator

  setup do
    original = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))

    on_exit(fn ->
      if original do
        Application.put_env(:serviceradar_core, :crypto_secret, original)
      else
        Application.delete_env(:serviceradar_core, :crypto_secret)
      end
    end)

    :ok
  end

  test "plugin config preserves github metadata on agent assignments" do
    assignment = %{
      assignment_id: "assign-1",
      plugin_id: "plugin-1",
      package_id: "package-1",
      version: "1.0.0",
      name: "HTTP Check",
      entrypoint: "run_check",
      runtime: nil,
      outputs: "serviceradar.plugin_result.v1",
      capabilities: [],
      params: %{},
      permissions: %{},
      resources: %{},
      enabled: true,
      interval_sec: 60,
      timeout_sec: 10,
      wasm_object_key: "plugins/http-check/1.0.0/package.wasm",
      content_hash: "abc123",
      source_type: "github",
      source_repo_url: "https://github.com/acme/demo",
      source_commit: "abc123",
      download_url: "https://internal/download"
    }

    config = AgentConfigGenerator.to_proto_plugin_config([assignment], %{})
    [proto] = config.assignments

    assert proto.source_repo_url == "https://github.com/acme/demo"
    assert proto.source_commit == "abc123"
  end

  test "plugin config resolves secret refs into runtime params without leaking secret material" do
    assignment = %{
      assignment_id: "assign-1",
      plugin_id: "axis-camera",
      package_id: "package-1",
      version: "1.0.0",
      name: "AXIS Camera",
      entrypoint: "run_check",
      runtime: nil,
      outputs: "serviceradar.plugin_result.v1",
      capabilities: [],
      params: %{
        "username" => "root",
        "password_secret_ref" => "secretref:password_secret_ref:test",
        "_secret_material" => %{
          "secretref:password_secret_ref:test" => ServiceRadar.Edge.Crypto.encrypt("super-secret")
        }
      },
      permissions: %{},
      resources: %{},
      enabled: true,
      interval_sec: 60,
      timeout_sec: 10,
      wasm_object_key: "plugins/axis/1.0.0/package.wasm",
      content_hash: "abc123",
      source_type: "upload",
      source_repo_url: "",
      source_commit: "",
      download_url: "",
      plugin_package: %{
        manifest: %{},
        config_schema: %{
          "type" => "object",
          "properties" => %{
            "password_secret_ref" => %{"type" => "string", "secretRef" => true}
          }
        }
      }
    }

    config = AgentConfigGenerator.to_proto_plugin_config([assignment], %{})
    [proto] = config.assignments
    params = Jason.decode!(proto.params_json)

    assert params["password"] == "super-secret"
    assert params["password_secret_ref"] == "secretref:password_secret_ref:test"
    refute Map.has_key?(params, "_secret_material")
  end
end
