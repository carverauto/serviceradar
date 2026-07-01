defmodule ServiceRadar.Credentials.ProviderProfiles.ProxmoxProfile do
  @moduledoc """
  Provider profile for Proxmox VE inventory + console credential rules.

  This is a verbatim extraction of the previous Proxmox-only params template and
  credential-broker grant builders in
  `ServiceRadar.Credentials.PluginAssignmentMaterializer`. Output must stay
  byte-identical (enforced by `ProxmoxProfileGoldenTest`).
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
    purpose_string = Atom.to_string(purpose)

    if purpose_string in RuleAccessors.rule_purposes(rule) do
      true
    else
      purpose == @console_purpose and RuleAccessors.rule_purpose(rule) == @inventory_purpose and
        RuleAccessors.auth_method(rule) == "proxmox_api_token"
    end
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
      "insecure_skip_verify" => RuleAccessors.tls_policy(rule) == :skip_verify,
      "ssh_host_key_policy" => RuleAccessors.ssh_host_key_policy(rule),
      "credential_rule_id" => RuleAccessors.value_string(rule, [:id, "id"])
    }

    if RuleAccessors.auth_method(rule) == "proxmox_api_token" do
      {:ok, Map.put(params, "api_token_secret_ref", SecretRefs.network_credential_ref(secret_id))}
    else
      {:ok, Map.put(params, "credential_secret", SecretRefs.network_credential_ref(secret_id))}
    end
  end

  def params_template(_purpose, rule, secret_id, %{grant: grant}) do
    {:ok,
     %{
       "credential_broker" => grant,
       "api_token_secret_ref" => SecretRefs.network_credential_ref(secret_id),
       "include_guests" => RuleAccessors.metadata_bool(rule, "include_guests", true),
       "timeout_ms" => RuleAccessors.metadata_int(rule, "timeout_ms", 30_000),
       "insecure_skip_verify" => RuleAccessors.tls_policy(rule) == :skip_verify,
       "auto_discovery_enabled" =>
         RuleAccessors.metadata_bool(rule, "auto_discovery_enabled", false),
       "credential_rule_id" => RuleAccessors.value_string(rule, [:id, "id"])
     }}
  end
end
