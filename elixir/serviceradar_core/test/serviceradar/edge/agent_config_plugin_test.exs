defmodule ServiceRadar.Edge.AgentConfigPluginTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentConfig.Compiler
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

  describe "download token freshness epoch (task 3.3)" do
    test "epoch is zero when no assignment carries a download token" do
      assert AgentConfigGenerator.download_token_epoch([], []) == 0

      assert AgentConfigGenerator.download_token_epoch(
               [%{download_token: nil}],
               [%{"download_token" => ""}]
             ) == 0
    end

    test "epoch advances with time so configs re-version before token TTL elapses" do
      plugins = [%{download_token: "tok"}]
      epoch_seconds = AgentConfigGenerator.download_token_epoch_seconds()

      now = 1_780_000_000
      same_window = now + div(epoch_seconds, 4)
      next_window = now + epoch_seconds

      assert AgentConfigGenerator.download_token_epoch(plugins, [], now) ==
               AgentConfigGenerator.download_token_epoch(plugins, [], same_window)

      assert AgentConfigGenerator.download_token_epoch(plugins, [], next_window) >
               AgentConfigGenerator.download_token_epoch(plugins, [], now)
    end

    test "epoch interval stays at half the signed token TTL, floored at 5 minutes" do
      original = Application.get_env(:serviceradar_core, :plugin_storage)

      on_exit(fn ->
        if original do
          Application.put_env(:serviceradar_core, :plugin_storage, original)
        else
          Application.delete_env(:serviceradar_core, :plugin_storage)
        end
      end)

      Application.put_env(:serviceradar_core, :plugin_storage, download_ttl_seconds: 86_400)
      assert AgentConfigGenerator.download_token_epoch_seconds() == 43_200

      Application.put_env(:serviceradar_core, :plugin_storage, download_ttl_seconds: 60)
      assert AgentConfigGenerator.download_token_epoch_seconds() == 300

      Application.put_env(:serviceradar_core, :plugin_storage,
        download_ttl_seconds: 86_400,
        download_token_epoch_seconds: 600
      )

      assert AgentConfigGenerator.download_token_epoch_seconds() == 600
    end

    test "addon download tokens also enroll the config in the freshness epoch" do
      assert AgentConfigGenerator.download_token_epoch(
               [],
               [%{download_token: "tok"}],
               1_780_000_000
             ) > 0
    end
  end

  test "host-authority lease rotation re-versions delivery without changing public params" do
    assignment = %{
      assignment_id: "proxmox-assignment",
      params: %{
        "credential_rule_id" => "rule-1",
        "api_token" => "__SERVICERADAR_HOST_CREDENTIAL__"
      },
      host_params: %{
        "schema" => "serviceradar.plugin_host_authority.v1",
        "bindings" => [
          %{
            "binding_id" => "binding-1",
            "provider" => "proxmox",
            "credential_rule_id" => "rule-1",
            "origin" => "https://192.168.2.10:8006",
            "insecure_skip_verify" => false,
            "target_ids" => %{"device_uid" => "pve-farm-1"},
            "credential_broker" => %{
              "schema" => "serviceradar.edge_credential_broker_grant.v1",
              "grant_id" => "grant-a",
              "credential_secret_ref" => "secretref:network_credential:secret-1",
              "expires_at" => "2026-07-13T15:00:00Z"
            }
          }
        ]
      }
    }

    rotated =
      assignment
      |> put_in(
        [:host_params, "bindings", Access.at(0), "credential_broker", "grant_id"],
        "grant-b"
      )
      |> put_in(
        [:host_params, "bindings", Access.at(0), "credential_broker", "expires_at"],
        "2026-07-13T15:05:00Z"
      )

    projection = AgentConfigGenerator.plugin_assignment_version_projection(assignment)
    rotated_projection = AgentConfigGenerator.plugin_assignment_version_projection(rotated)

    assert projection.params == rotated_projection.params
    refute Compiler.content_hash(projection) == Compiler.content_hash(rotated_projection)
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

  test "Proxmox inventory proto rendering never resolves or exposes legacy credential fields" do
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

    assert params["api_token"] == "__SERVICERADAR_HOST_CREDENTIAL__"
    refute Map.has_key?(params, "api_token_secret_ref")
    refute Map.has_key?(params, "credential_broker")
    refute Map.has_key?(params, "_secret_material")
    refute proto.params_json =~ "token-secret"
  end

  test "Proxmox console proto rendering never resolves or exposes legacy SSH credentials" do
    payload = Jason.encode!(%{"username" => "root", "private_key" => "PRIVATE KEY"})

    assignment =
      base_plugin_assignment(%{
        source: :policy,
        plugin_id: "proxmox-console",
        entrypoint: "run_console",
        params: %{
          "credential_broker" => %{
            "schema" => "serviceradar.edge_credential_broker_grant.v1",
            "credential_rule_id" => "console-rule"
          },
          "credential_secret" => "secretref:credential_secret:test",
          "_secret_material" => %{
            "secretref:credential_secret:test" => Crypto.encrypt(payload)
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

    assert params["credential_secret"] == "__SERVICERADAR_HOST_CREDENTIAL__"
    refute Map.has_key?(params, "credential_broker")
    refute Map.has_key?(params, "_secret_material")
    refute proto.params_json =~ "PRIVATE KEY"
  end

  test "Proxmox inventory input templates expose only the host-credential sentinel" do
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
    assert params["template"]["api_token"] == "__SERVICERADAR_HOST_CREDENTIAL__"
    refute Map.has_key?(params["template"], "api_token_secret_ref")
    refute Map.has_key?(params["template"], "credential_broker")
    refute Map.has_key?(params["template"], "_secret_material")
    refute proto.params_json =~ "token-secret"
  end

  test "Proxmox console input templates expose only the host-credential sentinel" do
    payload = Jason.encode!(%{"username" => "root", "private_key" => "PRIVATE KEY"})

    assignment =
      base_plugin_assignment(%{
        source: :policy,
        plugin_id: "proxmox-console",
        entrypoint: "run_console",
        params: %{
          "schema" => "serviceradar.plugin_inputs.v1",
          "agent_id" => "agent-a",
          "inputs" => [],
          "template" => %{
            "credential_broker" => %{
              "schema" => "serviceradar.edge_credential_broker_grant.v1",
              "credential_rule_id" => "console-rule"
            },
            "credential_secret" => "secretref:credential_secret:test",
            "_secret_material" => %{
              "secretref:credential_secret:test" => Crypto.encrypt(payload)
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

    assert params["template"]["credential_secret"] == "__SERVICERADAR_HOST_CREDENTIAL__"
    refute Map.has_key?(params["template"], "credential_broker")
    refute Map.has_key?(params["template"], "_secret_material")
    refute proto.params_json =~ "PRIVATE KEY"
  end

  test "manual Proxmox assignments fail closed without exposing credential refs" do
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

    assert params["api_token"] == "__SERVICERADAR_HOST_CREDENTIAL__"
    refute Map.has_key?(params, "api_token_secret_ref")
    refute Map.has_key?(params, "credential_broker")
    refute Map.has_key?(params, "_secret_material")
    refute proto.params_json =~ "token-secret"
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
