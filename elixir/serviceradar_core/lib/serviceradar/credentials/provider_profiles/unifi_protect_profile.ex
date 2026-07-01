defmodule ServiceRadar.Credentials.ProviderProfiles.UnifiProtectProfile do
  @moduledoc """
  Provider profile for UniFi Protect camera inventory + stream credential rules.

  The `target_query` resolves to the Protect controller device(s); the plugin
  enumerates cameras behind `/proxy/protect/api/bootstrap`. Host is injected
  per-target from SRQL items, so it is intentionally absent from the template.
  """

  @behaviour ServiceRadar.Credentials.CredentialProviderProfile

  alias ServiceRadar.Credentials.ProviderProfiles.CameraProfileHelpers
  alias ServiceRadar.Credentials.RuleAccessors

  @provider "unifi-protect"
  @inventory_plugin_id "unifi-protect-camera"
  @stream_plugin_id "unifi-protect-camera-stream"
  @inventory_purpose :camera_inventory
  @stream_purpose :camera_stream
  @grant_type "unifi_protect_api"

  @impl true
  def provider, do: @provider

  @impl true
  def purposes, do: [@inventory_purpose, @stream_purpose]

  @impl true
  def plugin_id(@stream_purpose), do: @stream_plugin_id
  def plugin_id(_purpose), do: @inventory_plugin_id

  @impl true
  def host_source, do: :per_target_items

  @impl true
  def secret_ref_fields, do: ["password_secret_ref", "api_key_secret_ref"]

  @impl true
  def resolve_username?(_purpose, rule), do: RuleAccessors.auth_method(rule) != "api_key"

  @impl true
  def rule_has_purpose?(rule, purpose) do
    Atom.to_string(purpose) in RuleAccessors.rule_purposes(rule)
  end

  @impl true
  def grant_spec(purpose, rule, secret_id, agent_id) do
    CameraProfileHelpers.grant_spec(
      @grant_type,
      purpose,
      rule,
      secret_id,
      agent_id,
      plugin_id(purpose)
    )
  end

  @impl true
  def params_template(_purpose, rule, _secret_id, ctx) do
    params = %{
      "credential_broker" => ctx.grant,
      "scheme" => RuleAccessors.metadata_string(rule, "scheme", "https"),
      "timeout_ms" => RuleAccessors.metadata_int(rule, "timeout_ms", 30_000),
      "insecure_skip_verify" => RuleAccessors.tls_policy(rule) == :skip_verify,
      "rtsp_port" => RuleAccessors.metadata_int(rule, "rtsp_port", 7447),
      "bootstrap_path" =>
        RuleAccessors.metadata_string(rule, "bootstrap_path", "/proxy/protect/api/bootstrap"),
      "login_path" => RuleAccessors.metadata_string(rule, "login_path", "/api/auth/login"),
      "credential_rule_id" => RuleAccessors.value_string(rule, [:id, "id"])
    }

    {:ok, CameraProfileHelpers.put_credentials(params, rule, ctx)}
  end
end
