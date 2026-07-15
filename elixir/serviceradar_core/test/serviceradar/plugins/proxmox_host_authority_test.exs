defmodule ServiceRadar.Plugins.ProxmoxHostAuthorityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.ProxmoxHostAuthority

  @sentinel "__SERVICERADAR_HOST_CREDENTIAL__"
  @integration_id "11111111-1111-4111-8111-111111111111"
  @controller_id "22222222-2222-4222-8222-222222222222"
  @provider_instance_ref "proxmox:v3:#{@integration_id}:#{@controller_id}:farm01"

  test "partitions inventory grants into exact source-scoped PVE bindings" do
    params = %{
      "schema" => "serviceradar.plugin_inputs.v1",
      "template" => %{
        "credential_broker" => inventory_grant(),
        "api_token_secret_ref" => "secretref:network_credential:secret-1",
        "api_token" => "must-not-reach-wasm",
        "_secret_material" => %{"ref" => "must-not-reach-wasm"},
        "insecure_skip_verify" => true
      },
      "inputs" => [
        %{
          "name" => "targets",
          "items" => [
            %{
              "uid" => "device-farm-pve01",
              "ip" => "192.168.2.10",
              "integration_id" => "proxmox:v2:farm01:node:pve01",
              "provider_ref" => "proxmox:node:pve01",
              "target_kind" => "pve_host"
            },
            %{
              "uid" => "device-tonka-pve01",
              "ip" => "192.168.1.10",
              "integration_id" => "proxmox:v2:tonka01:node:pve01",
              "provider_ref" => "proxmox:node:pve01",
              "target_kind" => "pve_host"
            }
          ]
        }
      ]
    }

    {public, host} =
      partition("proxmox-inventory", "run_check", params, "assignment-1")

    assert public["template"]["api_token"] == @sentinel
    refute Map.has_key?(public["template"], "credential_broker")
    refute Map.has_key?(public["template"], "api_token_secret_ref")
    refute Map.has_key?(public["template"], "insecure_skip_verify")
    refute inspect(public) =~ "must-not-reach-wasm"

    assert host["schema"] == "serviceradar.plugin_host_authority.v1"
    assert length(host["bindings"]) == 2

    bindings = Map.new(host["bindings"], &{&1["origin"], &1})
    farm = bindings["https://192.168.2.10:8006"]
    tonka = bindings["https://192.168.1.10:8006"]

    assert farm["target_ids"]["integration_id"] == "proxmox:v2:farm01:node:pve01"
    assert tonka["target_ids"]["integration_id"] == "proxmox:v2:tonka01:node:pve01"
    refute farm["binding_id"] == tonka["binding_id"]
    assert farm["credential_broker"]["allow"]["hosts"] == ["192.168.2.10"]
    assert farm["credential_broker"]["allow"]["ports"] == [8006]
    assert farm["credential_broker"]["allow"]["methods"] == ["GET"]
    assert farm["assignment_policy_version"] == 1
    assert farm["assignment_policy_fingerprint"] =~ ~r/\A[0-9a-f]{64}\z/
    refute Map.has_key?(farm, "ssh_host_key_policy")
    refute Map.has_key?(farm, "insecure_skip_verify")
  end

  test "native guest console binds only the owning PVE and exact guest paths" do
    params = %{
      "schema" => "serviceradar.plugin_inputs.v1",
      "template" => %{
        "credential_broker" => console_grant("proxmox_api_token"),
        "api_token_secret_ref" => "secretref:network_credential:secret-1"
      },
      "inputs" => [
        %{
          "name" => "targets",
          "items" => [
            %{
              "uid" => "guest-farm-155",
              "ip" => "192.168.2.126",
              "proxmox_base_url" => "https://192.168.2.10:8006/api2/json",
              "integration_id" => @integration_id,
              "controller_id" => @controller_id,
              "provider_instance_ref" => @provider_instance_ref,
              "provider_ref" => "#{@provider_instance_ref}:qemu:155",
              "native_cluster_id" => "farm01",
              "object_kind" => "qemu",
              "native_object_id" => "155",
              "node" => "pve01",
              "cluster" => "farm01",
              "vmid" => "155",
              "controller_device_uid" => "farm-pve01",
              "controller_provider_ref" => "#{@provider_instance_ref}:node:pve01",
              "target_kind" => "qemu_guest"
            }
          ]
        }
      ]
    }

    {public, host} =
      partition("proxmox-console", "run_console", params, "assignment-2")

    assert public["template"]["api_token"] == @sentinel
    refute inspect(public) =~ "credential_broker"
    assert [binding] = host["bindings"]
    assert binding["origin"] == "https://192.168.2.10:8006"
    assert binding["target_ids"]["device_uid"] == "guest-farm-155"
    assert binding["target_ids"]["integration_id"] == @integration_id
    assert binding["target_ids"]["controller_id"] == @controller_id
    assert binding["target_ids"]["provider_instance_ref"] == @provider_instance_ref
    assert binding["target_ids"]["provider_ref"] == "#{@provider_instance_ref}:qemu:155"
    assert binding["target_ids"]["native_cluster_id"] == "farm01"
    assert binding["target_ids"]["object_kind"] == "qemu"
    assert binding["target_ids"]["native_object_id"] == "155"
    assert binding["target_ids"]["node"] == "pve01"
    assert binding["target_ids"]["cluster"] == "farm01"
    assert binding["target_ids"]["vmid"] == "155"
    assert binding["target_ids"]["controller_device_uid"] == "farm-pve01"

    assert binding["target_ids"]["controller_provider_ref"] ==
             "#{@provider_instance_ref}:node:pve01"

    assert binding["credential_broker"]["allow"]["paths"] == [
             "/api2/json/nodes/pve01/qemu/155/vncproxy",
             "/api2/json/nodes/pve01/qemu/155/vncwebsocket"
           ]
  end

  test "guest console never treats a guest IP as the PVE controller" do
    params = %{
      "template" => %{
        "credential_broker" => console_grant("proxmox_api_token"),
        "api_token_secret_ref" => "secretref:network_credential:secret-1"
      },
      "inputs" => [
        %{
          "items" => [
            %{
              "uid" => "guest-farm-155",
              "ip" => "192.168.2.126",
              "provider_ref" => "proxmox:guest:pve01:qemu:155",
              "target_kind" => "qemu_guest"
            }
          ]
        }
      ]
    }

    {public, host} =
      partition("proxmox-console", "run_console", params, "assignment-3")

    assert public["template"]["api_token"] == @sentinel
    assert host == nil
    refute inspect(public) =~ "192.168.2.10"
  end

  test "cleartext Proxmox controller origins never produce host authority" do
    params = %{
      "template" => %{
        "credential_broker" => console_grant("proxmox_api_token"),
        "api_token_secret_ref" => "secretref:network_credential:secret-1"
      },
      "inputs" => [
        %{
          "items" => [
            %{
              "uid" => "guest-farm-155",
              "proxmox_base_url" => "http://192.168.2.10:8006",
              "integration_id" => "proxmox:v3:source:controller:farm01:qemu:155",
              "provider_ref" => "proxmox:v3:source:controller:farm01:qemu:155",
              "target_kind" => "qemu_guest"
            }
          ]
        }
      ]
    }

    {public, host} =
      partition(
        "proxmox-console",
        "run_console",
        params,
        "assignment-cleartext"
      )

    assert public["template"]["api_token"] == @sentinel
    assert host == nil
  end

  test "hostname Proxmox origins never produce authority without address pinning" do
    params = %{
      "template" => %{
        "credential_broker" => console_grant("proxmox_api_token"),
        "api_token_secret_ref" => "secretref:network_credential:secret-1"
      },
      "inputs" => [
        %{
          "items" => [
            %{
              "uid" => "guest-farm-155",
              "proxmox_base_url" => "https://pve01.farm01.example:8006",
              "integration_id" => "proxmox:v3:source:controller:farm01:qemu:155",
              "provider_ref" => "proxmox:v3:source:controller:farm01:qemu:155",
              "target_kind" => "qemu_guest"
            }
          ]
        }
      ]
    }

    {_public, host} =
      partition(
        "proxmox-console",
        "run_console",
        params,
        "assignment-hostname"
      )

    assert host == nil
  end

  test "controller-scoped console binding can serve exact session-derived guest paths" do
    params = %{
      "template" => %{
        "credential_broker" => console_grant("proxmox_api_token"),
        "api_token_secret_ref" => "secretref:network_credential:secret-1"
      },
      "inputs" => [
        %{
          "items" => [
            %{
              "uid" => "farm-pve01",
              "ip" => "192.168.2.10",
              "integration_id" => @integration_id,
              "controller_id" => @controller_id,
              "provider_instance_ref" => @provider_instance_ref,
              "provider_ref" => "#{@provider_instance_ref}:node:pve01",
              "native_cluster_id" => "farm01",
              "object_kind" => "node",
              "native_object_id" => "pve01",
              "node" => "pve01",
              "cluster" => "farm01",
              "controller_device_uid" => "farm-pve01",
              "controller_provider_ref" => "#{@provider_instance_ref}:node:pve01",
              "target_kind" => "pve_host"
            }
          ]
        }
      ]
    }

    {_public, host} =
      partition(
        "proxmox-console",
        "run_console",
        params,
        "assignment-controller"
      )

    assert [binding] = host["bindings"]
    assert binding["origin"] == "https://192.168.2.10:8006"
    assert binding["target_ids"]["device_uid"] == "farm-pve01"
    assert binding["target_ids"]["integration_id"] == @integration_id
    assert binding["target_ids"]["controller_id"] == @controller_id
    assert binding["target_ids"]["provider_instance_ref"] == @provider_instance_ref
    assert binding["target_ids"]["provider_ref"] == "#{@provider_instance_ref}:node:pve01"
    assert binding["target_ids"]["object_kind"] == "node"
    refute Map.has_key?(binding["target_ids"], "target_kind")
    refute Map.has_key?(binding["target_ids"], "controller_device_uid")
    refute Map.has_key?(binding["target_ids"], "controller_provider_ref")
    assert binding["credential_broker"]["allow"]["methods"] == ["GET", "POST"]
    assert binding["credential_broker"]["allow"]["paths"] == []
  end

  test "SSH console keeps the PVE controller identity and limits the grant to port 22" do
    params = %{
      "template" => %{
        "credential_broker" => console_grant("ssh_private_key"),
        "credential_secret" => "secretref:network_credential:ssh-secret",
        "ssh_host_key_policy" => "trust_on_first_use"
      },
      "inputs" => [
        %{
          "items" => [
            %{
              "uid" => "pve-tonka-01",
              "proxmox_base_url" => "https://192.168.1.10:8006",
              "provider_ref" => "proxmox:node:pve01",
              "target_kind" => "pve_host"
            }
          ]
        }
      ]
    }

    {public, host} =
      partition("proxmox-console", "run_console", params, "assignment-4")

    assert public["template"]["credential_secret"] == @sentinel
    refute Map.has_key?(public["template"], "ssh_host_key_policy")
    assert [binding] = host["bindings"]
    assert binding["origin"] == "https://192.168.1.10:8006"
    assert binding["credential_broker"]["allow"]["hosts"] == ["192.168.1.10"]
    assert binding["credential_broker"]["allow"]["ports"] == [22]
    assert binding["credential_broker"]["allow"]["methods"] == []
    assert binding["credential_broker"]["allow"]["paths"] == []
    assert binding["ssh_host_key_policy"] == "trust_on_first_use"
  end

  test "SSH console host-key policy is closed and host-only" do
    base = %{
      "template" => %{
        "credential_broker" => console_grant("ssh_private_key"),
        "credential_secret" => "secretref:network_credential:ssh-secret"
      },
      "inputs" => [
        %{
          "items" => [
            %{
              "uid" => "pve-tonka-01",
              "proxmox_base_url" => "https://192.168.1.10:8006",
              "provider_ref" => "proxmox:node:pve01",
              "target_kind" => "pve_host"
            }
          ]
        }
      ]
    }

    for policy <- [nil, "", "skip_verify", "accept_any", "TRUST_ON_FIRST_USE"] do
      params =
        if is_nil(policy),
          do: base,
          else: put_in(base, ["template", "ssh_host_key_policy"], policy)

      {public, host} = partition("proxmox-console", "run_console", params, "assignment-ssh")

      assert host == nil
      refute inspect(public) =~ "ssh_host_key_policy"
    end

    for policy <- ["known_hosts", "trust_on_first_use"] do
      params = put_in(base, ["template", "ssh_host_key_policy"], policy)
      {public, host} = partition("proxmox-console", "run_console", params, "assignment-ssh")

      refute inspect(public) =~ "ssh_host_key_policy"
      assert [binding] = host["bindings"]
      assert binding["ssh_host_key_policy"] == policy
    end
  end

  test "assignment policy binding must be exact and versioned" do
    params = %{
      "credential_rule_id" => "rule-console",
      "policy_id" => "network-credential-rule:rule-console:console_access",
      "policy_version" => 7
    }

    assert {:ok, binding} =
             ProxmoxHostAuthority.assignment_policy_binding(
               "proxmox-console",
               "run_console",
               params,
               "assignment-policy"
             )

    assert binding.policy_version == 7
    assert binding.credential_rule_id == "rule-console"

    assert binding.fingerprint ==
             "470356f22e46c9fcb1a5ddfcb9d8597ec520941418459b6211a75ea5a4ac0167"

    for change <- [
          %{"policy_version" => 0},
          %{"policy_version" => "7"},
          %{"policy_id" => "network-credential-rule:rule-console:inventory_enrichment"},
          %{"credential_rule_id" => "different-rule"}
        ] do
      assert {:error, :invalid_assignment_policy_binding} =
               ProxmoxHostAuthority.assignment_policy_binding(
                 "proxmox-console",
                 "run_console",
                 Map.merge(params, change),
                 "assignment-policy"
               )
    end
  end

  defp partition(plugin_id, entrypoint, params, assignment_id) do
    {rule_id, purpose} =
      case plugin_id do
        "proxmox-inventory" -> {"rule-inventory", "inventory_enrichment"}
        "proxmox-console" -> {"rule-console", "console_access"}
      end

    params =
      Map.merge(
        %{
          "policy_id" => "network-credential-rule:#{rule_id}:#{purpose}",
          "policy_version" => 1
        },
        params
      )

    ProxmoxHostAuthority.partition(plugin_id, entrypoint, params, assignment_id)
  end

  defp inventory_grant do
    %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_id" => "grant-inventory",
      "grant_type" => "proxmox_api_token",
      "credential_rule_id" => "rule-inventory",
      "credential_secret_ref" => "secretref:network_credential:secret-1",
      "consumer" => %{
        "kind" => "plugin",
        "id" => "proxmox-inventory",
        "purpose" => "inventory_enrichment"
      },
      "target" => %{"agent_id" => "edge-farm"},
      "resolution_location" => "agent",
      "inject" => %{
        "type" => "http_header",
        "name" => "Authorization",
        "scheme" => "PVEAPIToken"
      },
      "allow" => %{
        "methods" => ["GET"],
        "paths" => ["/api2/json/nodes", "/api2/json/nodes/*"]
      },
      "expires_at" => "2026-07-13T12:00:00Z"
    }
  end

  defp console_grant(auth_method) do
    %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_id" => "grant-console",
      "grant_type" => "proxmox_console",
      "credential_rule_id" => "rule-console",
      "credential_secret_ref" => "secretref:network_credential:secret-1",
      "consumer" => %{
        "kind" => "plugin",
        "id" => "proxmox-console",
        "purpose" => "console_access"
      },
      "target" => %{"agent_id" => "edge-farm"},
      "resolution_location" => "agent",
      "auth_method" => auth_method,
      "allow" => %{},
      "expires_at" => "2026-07-13T12:00:00Z"
    }
  end
end
