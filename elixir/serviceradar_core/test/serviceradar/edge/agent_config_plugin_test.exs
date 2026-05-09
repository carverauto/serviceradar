defmodule ServiceRadar.Edge.AgentConfigPluginTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Edge.Crypto

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
      download_url: "https://internal/download",
      download_token: "download-token-1"
    }

    config = AgentConfigGenerator.to_proto_plugin_config([assignment], %{})
    [proto] = config.assignments

    assert proto.source_repo_url == "https://github.com/acme/demo"
    assert proto.source_commit == "abc123"
    assert proto.download_token == "download-token-1"
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
          "secretref:password_secret_ref:test" => Crypto.encrypt("super-secret")
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
      download_token: "",
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

  test "plugin config resolves policy credential broker api token refs even when package schema is stale" do
    assignment =
      base_plugin_assignment(%{
        source: :policy,
        plugin_id: "proxmox-inventory",
        params: %{
          "credential_broker" => %{
            "schema" => "serviceradar.edge_credential_broker_grant.v1",
            "credential_rule_id" => "rule-1"
          },
          "api_token_secret_ref" => "secretref:api_token_secret_ref:test",
          "_secret_material" => %{
            "secretref:api_token_secret_ref:test" => Crypto.encrypt("root@pam!sr=token-secret")
          }
        },
        plugin_package: %{
          manifest: %{},
          config_schema: %{
            "type" => "object",
            "properties" => %{}
          }
        }
      })

    config = AgentConfigGenerator.to_proto_plugin_config([assignment], %{})
    [proto] = config.assignments
    params = Jason.decode!(proto.params_json)

    assert params["api_token"] == "root@pam!sr=token-secret"
    assert params["api_token_secret_ref"] == "secretref:api_token_secret_ref:test"
    refute Map.has_key?(params, "_secret_material")
  end

  test "plugin config resolves policy credential broker refs inside plugin input templates" do
    assignment =
      base_plugin_assignment(%{
        source: :policy,
        plugin_id: "proxmox-inventory",
        params: %{
          "schema" => "serviceradar.plugin_inputs.v1",
          "agent_id" => "agent-a",
          "inputs" => [],
          "template" => %{
            "credential_broker" => %{
              "schema" => "serviceradar.edge_credential_broker_grant.v1",
              "credential_rule_id" => "rule-1"
            },
            "api_token_secret_ref" => "secretref:api_token_secret_ref:test",
            "_secret_material" => %{
              "secretref:api_token_secret_ref:test" => Crypto.encrypt("root@pam!sr=token-secret")
            }
          }
        },
        plugin_package: %{
          manifest: %{},
          config_schema: %{
            "type" => "object",
            "properties" => %{}
          }
        }
      })

    config = AgentConfigGenerator.to_proto_plugin_config([assignment], %{})
    [proto] = config.assignments
    params = Jason.decode!(proto.params_json)

    refute Map.has_key?(params, "api_token")
    assert params["template"]["api_token"] == "root@pam!sr=token-secret"
    assert params["template"]["api_token_secret_ref"] == "secretref:api_token_secret_ref:test"
    refute Map.has_key?(params["template"], "_secret_material")
  end

  test "plugin config does not resolve manual credential refs without schema support" do
    assignment =
      base_plugin_assignment(%{
        source: :manual,
        plugin_id: "proxmox-inventory",
        params: %{
          "credential_broker" => %{
            "schema" => "serviceradar.edge_credential_broker_grant.v1",
            "credential_rule_id" => "rule-1"
          },
          "api_token_secret_ref" => "secretref:api_token_secret_ref:test",
          "_secret_material" => %{
            "secretref:api_token_secret_ref:test" => Crypto.encrypt("root@pam!sr=token-secret")
          }
        },
        plugin_package: %{
          manifest: %{},
          config_schema: %{
            "type" => "object",
            "properties" => %{}
          }
        }
      })

    config = AgentConfigGenerator.to_proto_plugin_config([assignment], %{})
    [proto] = config.assignments
    params = Jason.decode!(proto.params_json)

    refute Map.has_key?(params, "api_token")
    assert params["api_token_secret_ref"] == "secretref:api_token_secret_ref:test"
    refute Map.has_key?(params, "_secret_material")
  end

  defp base_plugin_assignment(overrides) do
    Map.merge(
      %{
        assignment_id: "assign-1",
        plugin_id: "plugin-1",
        package_id: "package-1",
        version: "1.0.0",
        name: "Plugin",
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
        wasm_object_key: "plugins/test/1.0.0/package.wasm",
        content_hash: "abc123",
        source_type: "upload",
        source_repo_url: "",
        source_commit: "",
        download_url: "",
        download_token: "",
        plugin_package: %{
          manifest: %{},
          config_schema: %{}
        }
      },
      overrides
    )
  end
end
