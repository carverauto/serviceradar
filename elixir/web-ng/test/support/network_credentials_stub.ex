defmodule ServiceRadarWebNG.TestSupport.NetworkCredentialsStub do
  @moduledoc false

  def list_secrets(opts) do
    send(test_pid(), {:network_credentials_list_secrets, opts})
    {:ok, [secret()]}
  end

  def get_secret(id, opts) do
    send(test_pid(), {:network_credentials_get_secret, id, opts})

    if to_string(id) == secret().id do
      {:ok, secret()}
    else
      {:error, :not_found}
    end
  end

  def create_secret(attrs, opts) do
    send(test_pid(), {:network_credentials_create_secret, attrs, opts})
    {:ok, Map.put(secret(), :name, attrs["name"] || attrs[:name] || secret().name)}
  end

  def update_secret_details(id, attrs, opts) do
    send(test_pid(), {:network_credentials_update_secret, id, attrs, opts})
    {:ok, Map.merge(secret(), Map.new(attrs, fn {key, value} -> {to_atom_key(key), value} end))}
  end

  def rotate_secret(_id, %{"community" => ""}, _opts) do
    {:error, :invalid_request, "missing credential field: community"}
  end

  def rotate_secret(id, values, opts) do
    send(test_pid(), {:network_credentials_rotate_secret, id, values, opts})
    {:ok, secret()}
  end

  def list_rules(opts) do
    send(test_pid(), {:network_credentials_list_rules, opts})
    {:ok, [rule()]}
  end

  def get_rule(id, opts) do
    send(test_pid(), {:network_credentials_get_rule, id, opts})

    if to_string(id) == rule().id do
      {:ok, rule()}
    else
      {:error, :not_found}
    end
  end

  def create_rule(attrs, opts) do
    send(test_pid(), {:network_credentials_create_rule, attrs, opts})
    {:ok, Map.merge(rule(), Map.take(attrs, [:name, :ca_bundle_pem, :tls_policy, :provider]))}
  end

  def update_rule(id, attrs, opts) do
    send(test_pid(), {:network_credentials_update_rule, id, attrs, opts})
    {:ok, Map.merge(rule(), attrs)}
  end

  def set_rule_enabled(id, enabled, opts) do
    send(test_pid(), {:network_credentials_set_rule_enabled, id, enabled, opts})
    {:ok, Map.put(rule(), :enabled, enabled)}
  end

  def secret do
    %{
      id: "00000000-0000-4000-8000-000000000101",
      name: "demo-proxmox-readonly",
      description: "synthetic",
      provider: "proxmox",
      credential_kind: :api_token,
      username: "root",
      public_fingerprint: "sha256:example",
      source_type: :internal_encrypted,
      rotation_state: :active,
      last_rotated_at: ~U[2026-09-01 00:00:00Z],
      next_rotation_due_at: nil,
      metadata: %{"auth_method" => "proxmox_api_token"},
      inserted_at: ~U[2026-09-01 00:00:00Z],
      updated_at: ~U[2026-09-01 00:00:00Z],
      secret_payload: "MUST-NOT-LEAK"
    }
  end

  def rule do
    %{
      id: "00000000-0000-4000-8000-000000000201",
      name: "demo-proxmox-inventory",
      description: nil,
      enabled: true,
      priority: 100,
      provider: "proxmox",
      auth_method: "proxmox_api_token",
      purpose: "inventory_enrichment",
      target_query: "in:devices metadata.proxmox_candidate:true",
      scope_type: :agent,
      scope_value: "agent-site01-01",
      secret_id: secret().id,
      allowed_ports: [8006],
      tls_policy: :verify,
      ssh_host_key_policy: :known_hosts,
      ca_bundle_pem: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
      server_cert_fingerprint: nil,
      metadata: %{},
      last_test_status: nil,
      last_tested_at: nil,
      last_test_message: nil,
      inserted_at: ~U[2026-09-01 00:00:00Z],
      updated_at: ~U[2026-09-01 00:00:00Z]
    }
  end

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key("name"), do: :name
  defp to_atom_key("description"), do: :description
  defp to_atom_key(key) when is_binary(key), do: :name

  defp test_pid do
    Application.get_env(:serviceradar_web_ng, :network_credentials_test_pid, self())
  end
end
