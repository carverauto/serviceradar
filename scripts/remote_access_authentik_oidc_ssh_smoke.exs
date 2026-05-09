alias ServiceRadar.Edge.RemoteAccessSSHCACommandSigner
alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
alias ServiceRadar.Edge.RemoteAccessSSHIdentityIssuer
alias ServiceRadarWebNGWeb.Auth.ConfigCache
alias ServiceRadarWebNGWeb.Auth.OIDCClient

defmodule ServiceRadar.RemoteAccessAuthentikOIDCSSHSmokeAuditWriter do
  @moduledoc false

  def write_async(_opts), do: :ok
end

required_env = fn name ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" -> value
    _ -> raise "#{name} is required"
  end
end

client_id = required_env.("SERVICERADAR_AUTHENTIK_OIDC_CLIENT_ID")
client_secret = required_env.("SERVICERADAR_AUTHENTIK_OIDC_CLIENT_SECRET")
discovery_url = required_env.("SERVICERADAR_AUTHENTIK_OIDC_DISCOVERY_URL")
id_token = required_env.("SERVICERADAR_AUTHENTIK_OIDC_ID_TOKEN")
nonce = required_env.("SERVICERADAR_AUTHENTIK_OIDC_NONCE")
group = required_env.("SERVICERADAR_AUTHENTIK_OIDC_GROUP")
principal = required_env.("SERVICERADAR_REMOTE_ACCESS_SSH_PRINCIPAL")
public_key_file = required_env.("SERVICERADAR_REMOTE_ACCESS_PUBLIC_KEY_FILE")
cert_file = required_env.("SERVICERADAR_REMOTE_ACCESS_CERT_FILE")
ca_key_file = required_env.("SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_FILE")
signer_command = required_env.("SERVICERADAR_REMOTE_ACCESS_SSHCA_SIGNER")
session_id = System.get_env("SERVICERADAR_REMOTE_ACCESS_SESSION_ID", "authentik-smoke-session")
agent_id = System.get_env("SERVICERADAR_REMOTE_ACCESS_AGENT_ID", "authentik-smoke-agent")
gateway_id = System.get_env("SERVICERADAR_REMOTE_ACCESS_GATEWAY_ID", "authentik-smoke-gateway")
target_host = System.get_env("SERVICERADAR_REMOTE_ACCESS_TARGET_HOST", "127.0.0.1")
target_id = System.get_env("SERVICERADAR_REMOTE_ACCESS_TARGET_ID", "authentik-smoke-target")

Code.ensure_loaded!(RemoteAccessSSHCACommandSigner)

if !Process.whereis(ConfigCache) do
  {:ok, _pid} = ConfigCache.start_link(ttl_ms: to_timeout(minute: 5))
end

expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)

:ets.insert(
  ConfigCache,
  {:auth_settings,
   %{
     is_enabled: true,
     mode: :active_sso,
     provider_type: :oidc,
     oidc_client_id: client_id,
     oidc_client_secret_encrypted: client_secret,
     oidc_discovery_url: discovery_url,
     oidc_scopes: "openid email profile groups",
     claim_mappings: %{"email" => "email", "name" => "name", "sub" => "sub"}
   }, expires_at}
)

with {:ok, claims} <- OIDCClient.verify_id_token(id_token, nonce: nonce),
     {:ok, user_info} <- OIDCClient.extract_user_info(claims),
     {:ok, public_key} <- File.read(public_key_file),
     {:ok, envelope} <-
       RemoteAccessSSHIdentityIssuer.issue(
         %{
           id: "authentik-smoke:" <> user_info.external_id,
           email: user_info.email,
           display_name: user_info.name || user_info.email,
           external_id: user_info.external_id,
           last_auth_method: :oidc,
           permissions: MapSet.new([RemoteAccessSSHCertificatePolicy.permission()])
         },
         %{
           session_id: session_id,
           agent_id: agent_id,
           gateway_id: gateway_id,
           public_key: public_key,
           target: %{device_uid: target_id, host: target_host},
           principal_mappings: [
             %{"source" => "groups", "value" => group, "principals" => [principal]}
           ],
           requested_principals: [principal],
           ttl_seconds: 300
         },
         signer: RemoteAccessSSHCACommandSigner,
         audit_writer: ServiceRadar.RemoteAccessAuthentikOIDCSSHSmokeAuditWriter,
         idp_claims: claims,
         command: signer_command,
         args: ["--ca-key-file", ca_key_file, "--max-ttl", "15m"],
         ca_key_id: "authentik-smoke-ca"
       ) do
  certificate = get_in(envelope, [:ssh, "certificate"]) || raise "issuer returned no certificate"
  :ok = File.write(cert_file, certificate <> "\n")
  :ok = File.chmod(cert_file, 0o600)

  summary = %{
    result: "ok",
    email: user_info.email,
    external_id: user_info.external_id,
    groups: claims["groups"],
    session_id: envelope.session_id,
    agent_id: envelope.agent_id,
    principal: principal,
    credential_mode: envelope.credential_mode,
    credential_custody_mode: "short_lived_certificate",
    certificate_fingerprint: envelope.fingerprint,
    ca_key_id: envelope.ca_key_id
  }

  IO.puts("SR_REMOTE_ACCESS_AUTHENTIK_SMOKE=" <> Jason.encode!(summary, pretty: true))
else
  {:error, reason} -> raise "Authentik OIDC to SSH certificate smoke failed: #{inspect(reason)}"
end
