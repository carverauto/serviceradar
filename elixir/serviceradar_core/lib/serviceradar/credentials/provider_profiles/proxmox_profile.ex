defmodule ServiceRadar.Credentials.ProviderProfiles.ProxmoxProfile do
  @moduledoc """
  Provider profile for Proxmox VE inventory + console credential rules.

  This owns the Proxmox-only params template and credential-broker grant
  builders extracted from `PluginAssignmentMaterializer`. API-token paths
  require verified TLS, SSH paths require host-key verification, and legacy
  insecure transport overrides are never materialized.
  """

  @behaviour ServiceRadar.Credentials.CredentialProviderProfile

  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.SecretRefs

  @provider "proxmox"
  @inventory_plugin_id "proxmox-inventory"
  @console_plugin_id "proxmox-console"
  @inventory_purpose :inventory_enrichment
  @console_purpose :console_access

  @impl true
  def provider, do: @provider

  @impl true
  def purposes, do: [@inventory_purpose, @console_purpose]

  @impl true
  def plugin_id(@console_purpose), do: @console_plugin_id
  def plugin_id(_purpose), do: @inventory_plugin_id

  @impl true
  def host_source, do: :per_target_items

  @impl true
  def secret_ref_fields, do: ["api_token_secret_ref", "credential_secret"]

  @impl true
  def resolve_username?(_purpose, _rule), do: false

  @impl true
  def rule_has_purpose?(rule, purpose) do
    Atom.to_string(purpose) in RuleAccessors.rule_purposes(rule)
  end

  @impl true
  def grant_spec(@console_purpose, rule, secret_id, agent_id) do
    attrs = %{
      secret_id: secret_id,
      secret_ref: SecretRefs.network_credential_ref(secret_id),
      credential_rule_id: RuleAccessors.value_string(rule, [:id, "id"]),
      grant_type: "proxmox_console",
      consumer_kind: :plugin,
      consumer_id: @console_plugin_id,
      purpose: "console_access",
      agent_id: agent_id,
      resolution_location: :agent,
      ttl_seconds: RuleAccessors.metadata_int(rule, "credential_broker_ttl_seconds", 300)
    }

    {attrs, %{"auth_method" => RuleAccessors.auth_method(rule)}}
  end

  def grant_spec(_purpose, rule, secret_id, agent_id) do
    attrs = %{
      secret_id: secret_id,
      secret_ref: SecretRefs.network_credential_ref(secret_id),
      credential_rule_id: RuleAccessors.value_string(rule, [:id, "id"]),
      grant_type: "proxmox_api_token",
      consumer_kind: :plugin,
      consumer_id: @inventory_plugin_id,
      purpose: "inventory_enrichment",
      agent_id: agent_id,
      resolution_location: :agent,
      inject: %{
        "type" => "http_header",
        "name" => "Authorization",
        "scheme" => "PVEAPIToken"
      },
      allowed_methods: ["GET"],
      # Proxmox VE's historical REST API prefix is /api2/json.
      allowed_paths: [
        "/api2/json/version",
        "/api2/json/cluster/status",
        "/api2/json/nodes",
        "/api2/json/nodes/*",
        "/api2/json/cluster/resources"
      ],
      ttl_seconds: RuleAccessors.metadata_int(rule, "credential_broker_ttl_seconds", 300)
    }

    {attrs, %{}}
  end

  @impl true
  def params_template(@console_purpose, rule, secret_id, %{grant: grant}) do
    params = %{
      "credential_broker" => grant,
      "timeout_ms" => RuleAccessors.metadata_int(rule, "timeout_ms", 30_000),
      "ssh_host_key_policy" => RuleAccessors.ssh_host_key_policy(rule),
      "credential_rule_id" => RuleAccessors.value_string(rule, [:id, "id"])
    }

    case RuleAccessors.auth_method(rule) do
      "proxmox_api_token" ->
        with :ok <- require_verified_tls(rule) do
          {:ok,
           Map.put(params, "api_token_secret_ref", SecretRefs.network_credential_ref(secret_id))}
        end

      "ssh_private_key" ->
        with :ok <- require_verified_ssh_host_key(rule) do
          {:ok,
           Map.put(params, "credential_secret", SecretRefs.network_credential_ref(secret_id))}
        end

      _unsupported_auth_method ->
        {:error, :unsupported_proxmox_console_auth_method}
    end
  end

  def params_template(_purpose, rule, secret_id, %{grant: grant}) do
    with :ok <- require_verified_tls(rule) do
      {:ok,
       %{
         "credential_broker" => grant,
         "api_token_secret_ref" => SecretRefs.network_credential_ref(secret_id),
         "include_guests" => RuleAccessors.metadata_bool(rule, "include_guests", true),
         "timeout_ms" => RuleAccessors.metadata_int(rule, "timeout_ms", 30_000),
         "auto_discovery_enabled" =>
           RuleAccessors.metadata_bool(rule, "auto_discovery_enabled", false),
         "credential_rule_id" => RuleAccessors.value_string(rule, [:id, "id"])
       }}
    end
  end

  defp require_verified_tls(rule) do
    if RuleAccessors.tls_policy(rule) == :verify,
      do: :ok,
      else: {:error, :proxmox_tls_verification_required}
  end

  defp require_verified_ssh_host_key(rule) do
    if RuleAccessors.ssh_host_key_policy(rule) in ["known_hosts", "trust_on_first_use"],
      do: :ok,
      else: {:error, :proxmox_ssh_host_key_verification_required}
  end
end
