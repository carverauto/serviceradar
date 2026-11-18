defmodule ServiceRadar.DeclarativeChecks.CredentialResolver do
  @moduledoc """
  Issues endpoint-locked `CredentialBrokerGrant` records and resolves credentials
  via `ServiceRadar.Credentials.SecretBroker` for declarative check credential
  slots (`1.2`, Decision 1 & 3).

  Ensures secret material never enters `platform.declarative_checks`, agent JSON
  configs, `node_snapshots`, or logs.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Plugins.SecretRefs

  @system_actor SystemActor.system(:declarative_check_credential_resolver)
  @default_ttl_seconds 300

  @doc """
  Issues an endpoint-locked `CredentialBrokerGrant` for a `DeclarativeCheckCredentialBinding`
  targeting `endpoint_url` (or `host`/`port`).
  """
  @spec issue_slot_grant(map(), map(), map(), keyword()) ::
          {:ok, CredentialBrokerGrant.t()} | {:error, term()}
  def issue_slot_grant(check, binding, target_spec \\ %{}, opts \\ [])
      when is_map(check) and is_map(binding) and is_map(target_spec) and is_list(opts) do
    actor = Keyword.get(opts, :actor, @system_actor)

    with {:ok, secret_id, rule_id} <- resolve_binding_ids(binding, actor),
         {:ok, allowlist} <- extract_endpoint_allowlist(target_spec) do
      ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
      now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
      expires_at = DateTime.shift(now, second: ttl)
      slug = to_string(Map.get(check, :slug) || Map.get(check, "slug") || "declarative-check")
      slot = to_string(Map.get(binding, :slot) || Map.get(binding, "slot") || "default")

      purpose =
        to_string(
          Map.get(target_spec, :purpose) || Map.get(target_spec, "purpose") || "synthetic_http"
        )

      grant_attrs = %{
        secret_id: secret_id,
        secret_ref: SecretRefs.network_credential_ref(secret_id),
        credential_rule_id: rule_id,
        grant_type: "declarative_check_slot",
        consumer_kind: :service_monitoring,
        consumer_id: "#{slug}:#{slot}",
        purpose: purpose,
        target_kind:
          to_string(
            Map.get(target_spec, :target_kind) || Map.get(target_spec, "target_kind") ||
              "endpoint"
          ),
        target_id:
          to_string(
            Map.get(target_spec, :target_key) || Map.get(target_spec, "target_key") || "singleton"
          ),
        agent_id: Map.get(target_spec, :agent_id) || Map.get(target_spec, "agent_id"),
        resolution_location: Map.get(target_spec, :resolution_location, :control_plane),
        allowed_schemes: allowlist.schemes,
        allowed_hosts: allowlist.hosts,
        allowed_ports: allowlist.ports,
        ttl_seconds: ttl,
        expires_at: expires_at
      }

      case Keyword.get(opts, :grant_issuer) do
        issuer when is_function(issuer, 1) -> issuer.(grant_attrs)
        _ -> CredentialBrokerGrant.issue_grant(grant_attrs, actor: @system_actor)
      end
    end
  end

  @doc """
  Resolves secret material exclusively via `SecretBroker.resolve_with_grant/2`.
  """
  @spec resolve_grant(map() | struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_grant(grant, opts \\ []) when is_map(grant) and is_list(opts) do
    SecretBroker.resolve_with_grant(grant, Keyword.put_new(opts, :actor, @system_actor))
  end

  defp resolve_binding_ids(binding, _actor) do
    secret_id =
      Map.get(binding, :credential_secret_id) || Map.get(binding, "credential_secret_id")

    rule_id = Map.get(binding, :credential_rule_id) || Map.get(binding, "credential_rule_id")

    cond do
      not is_nil(secret_id) ->
        {:ok, to_string(secret_id), nil}

      not is_nil(rule_id) ->
        case NetworkCredentialRule.get_by_id(rule_id, actor: @system_actor) do
          {:ok, %NetworkCredentialRule{enabled: true, secret_id: sid}} ->
            {:ok, to_string(sid), to_string(rule_id)}

          {:ok, %NetworkCredentialRule{enabled: false}} ->
            {:error, :credential_rule_disabled}

          _ ->
            {:error, :credential_rule_unavailable}
        end

      true ->
        {:error, :missing_credential_binding_target}
    end
  end

  defp extract_endpoint_allowlist(target_spec) do
    case Map.get(target_spec, :url) || Map.get(target_spec, "url") do
      url when is_binary(url) and url != "" ->
        uri = URI.parse(url)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
          port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
          {:ok, %{schemes: [uri.scheme], hosts: [uri.host], ports: [port]}}
        else
          {:error, :invalid_target_endpoint_url}
        end

      _ ->
        host = Map.get(target_spec, :host) || Map.get(target_spec, "host")
        port = Map.get(target_spec, :port) || Map.get(target_spec, "port")

        {:ok,
         %{
           schemes: ["https"],
           hosts: if(is_binary(host) and host != "", do: [host], else: []),
           ports: if(is_integer(port), do: [port], else: [])
         }}
    end
  end
end
