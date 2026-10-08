defmodule ServiceRadarWebNGWeb.PluginConfigCliTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, register_control_session!: 2, system_actor: 0]

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Plugins.Packages

  @moduletag :web_ng_shared_fixture_db
  @moduletag timeout: 120_000

  test "real CLI apply persists configuration and reuses it without secret re-entry" do
    marker = Ash.UUID.generate()
    plugin_id = "example-config-#{marker}"
    agent_uid = "example-agent-#{marker}"
    register_control_session!(agent_uid, "example-gateway")
    package = approved_package(plugin_id)
    {:ok, token, _} = Guardian.create_access_token(admin_user_fixture())

    server =
      start_supervised!({Bandit, plug: ServiceRadarWebNGWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    instance = "http://127.0.0.1:#{port}"
    directory = Path.join(System.fetch_env!("TEST_TMPDIR"), "plugin-config-#{marker}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    playbook_path = Path.join(directory, "playbook.yaml")
    secret_name = "Example inventory #{marker}"
    controller_secret_name = "Example controller #{marker}"
    rule_name = "Example inventory rule #{marker}"
    controller_name = "Example controller #{marker}"

    playbook = %{
      secrets: [
        %{
          name: secret_name,
          provider: "netbox",
          auth_method: "api_token",
          values_from: %{api_token: "EXAMPLE_INVENTORY_TOKEN"}
        },
        %{
          name: controller_secret_name,
          provider: "awx",
          auth_method: "bearer_token",
          values_from: %{api_token: "EXAMPLE_CONTROLLER_TOKEN"}
        }
      ],
      rules: [
        %{
          name: rule_name,
          provider: "netbox",
          auth_method: "api_token",
          purpose: "inventory_sync",
          secret: secret_name,
          scope_type: "agent",
          scope_value: agent_uid,
          target_query: "in:devices ip:192.0.2.10",
          tls_policy: "verify",
          allowed_ports: [443],
          controller_host: "inventory.example.com",
          enabled: true
        }
      ],
      ansible_controllers: [
        %{
          name: controller_name,
          base_url: "https://controller.example.com",
          agent_id: Ash.UUID.generate(),
          sync_credential: controller_secret_name,
          enabled: true
        }
      ],
      assignments: [
        %{
          plugin_id: plugin_id,
          agent_uid: agent_uid,
          enabled: true,
          interval_seconds: 120,
          timeout_seconds: 15,
          params: %{"address" => "198.51.100.10"}
        }
      ]
    }

    # JSON is a YAML subset, so the real YAML parser handles this generated,
    # entirely synthetic playbook without a second fixture representation.
    File.write!(playbook_path, Jason.encode!(playbook))

    first =
      cli!(instance, token, ["apply", "--file", playbook_path], [
        {"EXAMPLE_INVENTORY_TOKEN", "invented-inventory-token"},
        {"EXAMPLE_CONTROLLER_TOKEN", "invented-controller-token"}
      ])

    assert first =~ "created"
    observed = snapshot(instance, token, plugin_id, agent_uid, secret_name, rule_name, controller_name)
    [secret] = observed.secrets
    [rule] = observed.rules
    [controller] = observed.controllers
    [assignment] = observed.assignments
    assert rule["secret_id"] == secret["id"]
    assert rule["metadata"]["host"] == "inventory.example.com"
    assert rule["tls_policy"] == "verify"
    assert assignment["plugin_package_id"] == package.id
    assert assignment["plugin_id"] == plugin_id
    assert assignment["interval_seconds"] == 120
    assert assignment["params"] == %{"address" => "198.51.100.10"}
    assert controller["base_url"] == "https://controller.example.com"

    ciphertext = encrypted_payload(secret["id"])
    assert is_binary(ciphertext) and byte_size(ciphertext) > 0
    assert {:ok, plaintext} = ServiceRadar.Vault.decrypt(ciphertext)
    assert plaintext =~ "invented-inventory-token"
    assert :binary.match(ciphertext, "invented-inventory-token") == :nomatch
    refute Jason.encode!(observed) =~ "invented-inventory-token"
    refute Map.has_key?(secret, "secret_payload")

    replay =
      cli!(instance, token, ["apply", "--file", playbook_path], [
        {"EXAMPLE_INVENTORY_TOKEN", nil},
        {"EXAMPLE_CONTROLLER_TOKEN", nil}
      ])

    assert replay =~ "keep #{secret["id"]}"
    assert replay =~ "updated #{assignment["id"]}"

    assert snapshot(instance, token, plugin_id, agent_uid, secret_name, rule_name, controller_name) ==
             observed

    assert encrypted_payload(secret["id"]) == ciphertext

    assert Repo.query!(
             "SELECT count(*) FROM platform.plugin_assignments WHERE agent_uid = $1 AND plugin_package_id = ($2::text)::uuid",
             [agent_uid, package.id]
           ).rows == [[1]]
  end

  defp cli!(instance, token, arguments, environment \\ []) do
    relative_executable =
      __DIR__
      |> Path.join("../../../../js/cli/plugin_config_cli.runfiles-path")
      |> File.read!()
      |> String.trim()

    executable =
      Path.join([
        System.fetch_env!("TEST_SRCDIR"),
        System.fetch_env!("TEST_WORKSPACE"),
        relative_executable
      ])

    {output, status} =
      System.cmd(executable, ["plugin" | arguments] ++ ["--instance", instance],
        env: [{"SERVICERADAR_TOKEN", token} | environment],
        stderr_to_stdout: true
      )

    assert status == 0, "CLI failed (#{status}): #{output}"
    output
  end

  defp snapshot(instance, token, plugin_id, agent_uid, secret_name, rule_name, controller_name) do
    %{
      secrets: list(instance, token, "secrets", ["--name", secret_name]),
      rules: list(instance, token, "rules", ["--name", rule_name]),
      controllers: list(instance, token, "controllers", ["--name", controller_name]),
      assignments: list(instance, token, "assignments", ["--plugin-id", plugin_id, "--agent-uid", agent_uid])
    }
  end

  defp list(instance, token, resource, filters) do
    instance
    |> cli!(token, [resource, "list", "--json" | filters])
    |> Jason.decode!()
    |> Enum.map(&Map.drop(&1, ["inserted_at", "updated_at"]))
  end

  defp encrypted_payload(id) do
    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT encrypted_secret_payload FROM platform.network_credential_secrets WHERE id = ($1::text)::uuid",
        [id]
      )

    payload
  end

  defp approved_package(plugin_id) do
    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Example config"}, actor: system_actor())
    |> Ash.create!()

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Example config",
          version: "1.0.0",
          entrypoint: "run_check",
          outputs: "serviceradar.plugin_result.v1",
          manifest: %{
            "id" => plugin_id,
            "name" => "Example config",
            "version" => "1.0.0",
            "entrypoint" => "run_check",
            "outputs" => "serviceradar.plugin_result.v1",
            "capabilities" => ["get_config"],
            "resources" => %{"requested_cpu_ms" => 1_000, "requested_memory_mb" => 64}
          },
          config_schema: %{},
          signature: %{}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, approved} = Packages.approve(package.id, %{}, actor: system_actor())
    approved
  end
end
