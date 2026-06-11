defmodule ServiceRadar.Credentials.NetworkCredentialRuleTestPlan do
  @moduledoc """
  Builds redacted command payloads for testing network credential rules.

  Test plans intentionally carry a credential reference, never plaintext
  credential material. The receiving edge side resolves the reference through
  the same authenticated config/credential channel used for plugin assignment.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  @proxmox_provider "proxmox"
  @proxmox_command_type "proxmox.credential_test"
  @default_timeout_ms 30_000

  @spec proxmox_api_test_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def proxmox_api_test_by_id(id, opts \\ []) when is_binary(id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:network_credential_rule_test_plan))

    with {:ok, %NetworkCredentialRule{} = rule} <-
           NetworkCredentialRule.get_by_id(id, actor: actor) do
      proxmox_api_test(rule, Keyword.put(opts, :actor, actor))
    end
  end

  @spec proxmox_api_test(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def proxmox_api_test(rule, opts \\ [])

  def proxmox_api_test(rule, opts) when is_map(rule) do
    previewer = Keyword.get(opts, :previewer, NetworkCredentialRulePreview)

    with :ok <- ensure_proxmox_api_rule(rule),
         {:ok, preview} <-
           previewer.preview_rule(
             rule,
             opts
             |> Keyword.put(:sample_limit, 1)
             |> Keyword.put(:detect_conflicts?, false)
           ),
         {:ok, target} <- select_target(preview),
         {:ok, agent_id} <- select_agent(preview, target, rule),
         {:ok, secret_id} <- required_string(rule, [:secret_id, "secret_id"], "secret_id") do
      build_plan(rule, preview, target, agent_id, secret_id, opts)
    end
  end

  def proxmox_api_test(_rule, _opts), do: {:error, :invalid_rule}

  defp ensure_proxmox_api_rule(rule) do
    cond do
      value_string(rule, [:provider, "provider"]) != @proxmox_provider ->
        {:error, :unsupported_provider}

      value_string(rule, [:auth_method, "auth_method"]) not in ["proxmox_api_token", nil] ->
        {:error, :unsupported_auth_method}

      true ->
        :ok
    end
  end

  defp build_plan(rule, preview, target, agent_id, secret_id, opts) do
    credential_rule_id = value_string(rule, [:id, "id"])

    with {:ok, grant} <- credential_broker_grant(rule, target, agent_id, secret_id, opts) do
      {:ok,
       %{
         command_type: @proxmox_command_type,
         agent_id: agent_id,
         required_capability: "http",
         ttl_seconds: metadata_int(rule, "test_ttl_seconds", 120),
         context: %{
           credential_rule_id: credential_rule_id,
           provider: @proxmox_provider,
           device_uid: device_uid(target),
           target_query: value_string(rule, [:target_query, "target_query"])
         },
         payload: %{
           "schema" => "serviceradar.proxmox_credential_test.v1",
           "credential_rule_id" => credential_rule_id,
           "provider" => @proxmox_provider,
           "auth_method" => "proxmox_api_token",
           "credential_broker" => grant,
           "target" => target_payload(target, agent_id),
           "tls" => %{
             "insecure_skip_verify" => tls_policy(rule) == :skip_verify
           },
           "timeout_ms" => metadata_int(rule, "timeout_ms", @default_timeout_ms),
           "preview" => %{
             "matched_devices" => Map.get(preview, :matched_devices, 0),
             "scoped_devices" => Map.get(preview, :scoped_devices, 0)
           }
         }
       }}
    end
  end

  defp credential_broker_grant(rule, target, agent_id, secret_id, opts) do
    target = target_payload(target, agent_id)

    attrs =
      %{
        secret_id: secret_id,
        secret_ref: SecretRefs.network_credential_ref(secret_id),
        credential_rule_id: value_string(rule, [:id, "id"]),
        grant_type: "proxmox_api_token",
        consumer_kind: :test,
        consumer_id: value_string(rule, [:id, "id"]),
        purpose: "credential_rule_test",
        target_kind: "device",
        target_id: Map.get(target, "device_uid"),
        agent_id: agent_id,
        resolution_location: :agent,
        inject: %{"type" => "http_header", "name" => "Authorization", "scheme" => "PVEAPIToken"},
        allowed_methods: ["GET"],
        allowed_hosts: allowed_hosts_for(Map.get(target, "base_url")),
        allowed_paths: ["/api2/json/version", "/api2/json/nodes"],
        ttl_seconds: metadata_int(rule, "test_ttl_seconds", 120)
      }

    issue_grant(attrs, opts, %{
      "target" => %{
        "kind" => "device",
        "id" => Map.get(target, "device_uid"),
        "agent_id" => agent_id,
        "device_uid" => Map.get(target, "device_uid"),
        "base_url" => Map.get(target, "base_url")
      }
    })
  end

  defp select_target(preview) do
    preview
    |> Map.get(:sample_devices, [])
    |> List.wrap()
    |> Enum.find(&valid_target?/1)
    |> case do
      nil -> {:error, :no_scoped_target}
      target -> {:ok, target}
    end
  end

  defp select_agent(preview, target, rule) do
    agent_id = value_string(target, [:agent_id, "agent_id", :agent_uid, "agent_uid"])

    if is_binary(agent_id) and agent_id != "" do
      {:ok, agent_id}
    else
      case agent_from_preview(preview) do
        {:ok, value} -> {:ok, value}
        # No in-scope device carries an agent_id link yet — proxmox host
        # devices are discovered before they're agent-bound, so agent_distribution
        # is empty. When the rule is explicitly scoped to a single agent, that
        # agent is the eligible dispatch target.
        {:error, _} -> scoped_agent(rule)
      end
    end
  end

  defp scoped_agent(rule) do
    scope_type = value_string(rule, [:scope_type, "scope_type"])
    scope_value = value_string(rule, [:scope_value, "scope_value"])

    if scope_type == "agent" and is_binary(scope_value) and scope_value != "" do
      {:ok, scope_value}
    else
      {:error, :no_eligible_agent}
    end
  end

  defp agent_from_preview(preview) do
    case Map.get(preview, :agents, []) do
      [agent | _] ->
        case value_string(agent, [:agent_id, "agent_id"]) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, :no_eligible_agent}
        end

      _ ->
        {:error, :no_eligible_agent}
    end
  end

  defp valid_target?(target) when is_map(target) do
    target_base_url(target) != "" and device_uid(target) != ""
  end

  defp valid_target?(_target), do: false

  defp issue_grant(attrs, opts, extras) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:network_credential_rule_test_plan))
    issuer = Keyword.get(opts, :grant_issuer, default_grant_issuer(actor))

    case issuer.(attrs) do
      {:ok, %{} = grant} -> {:ok, CredentialBrokerGrant.to_payload(grant, extras)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_credential_broker_grant_issuer_result, other}}
    end
  end

  defp issue_persisted_grant(attrs) do
    attrs
    |> CredentialBrokerGrant.issue_attrs()
    |> CredentialBrokerGrant.issue_grant(
      actor: SystemActor.system(:network_credential_rule_test_plan)
    )
  end

  defp default_grant_issuer(actor) do
    if SystemActor.system_actor?(actor) do
      &issue_persisted_grant/1
    else
      &issue_ephemeral_test_grant/1
    end
  end

  defp issue_ephemeral_test_grant(attrs) do
    grant =
      attrs
      |> CredentialBrokerGrant.issue_attrs()
      |> Map.put(:id, "test-grant-#{System.unique_integer([:positive])}")

    {:ok, grant}
  end

  defp allowed_hosts_for(base_url) do
    case URI.parse(to_string(base_url)) do
      %URI{host: host} when is_binary(host) and host != "" -> [host]
      _ -> []
    end
  end

  defp target_payload(target, agent_id) do
    compact_map(%{
      "kind" => "device",
      "id" => device_uid(target),
      "agent_id" => agent_id,
      "device_uid" => device_uid(target),
      "base_url" => target_base_url(target),
      "hostname" => value_string(target, [:hostname, "hostname", :name, "name"]),
      "ip" => value_string(target, [:ip, "ip", :device_ip, "device_ip"])
    })
  end

  defp target_base_url(target) do
    direct =
      first_non_empty(
        value_string(target, [:base_url, "base_url"]),
        value_string(target, [:proxmox_base_url, "proxmox_base_url"]),
        value_string(target, [:endpoint, "endpoint"]),
        value_string(target, [:management_url, "management_url"])
      )

    cond do
      direct != "" ->
        normalize_base_url(direct)

      (host =
         first_non_empty(
           value_string(target, [:ip, "ip", :device_ip, "device_ip"]),
           value_string(target, [:hostname, "hostname", :name, "name"])
         )) != "" ->
        normalize_base_url(host)

      true ->
        ""
    end
  end

  defp normalize_base_url(value) do
    value = String.trim(value || "")

    cond do
      value == "" ->
        ""

      String.starts_with?(value, ["http://", "https://"]) ->
        String.trim_trailing(value, "/")

      true ->
        "https://" <> String.trim_trailing(value, "/") <> ":8006"
    end
  end

  defp device_uid(target) do
    value_string(target, [:uid, "uid", :device_uid, "device_uid", :device_id, "device_id"])
  end

  defp tls_policy(rule) do
    case value_string(rule, [:tls_policy, "tls_policy"]) do
      "skip_verify" -> :skip_verify
      _ -> :verify
    end
  end

  defp metadata_int(rule, key, default) do
    metadata = ValueUtils.map_value(rule, [:metadata, "metadata"], stringify_keys: true) || %{}
    ValueUtils.int_value(metadata, [key], default)
  end

  defp required_string(map, keys, label) do
    case value_string(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_field, label}}
    end
  end

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)

  defp first_non_empty(values) when is_list(values), do: first_non_empty(List.to_tuple(values))

  defp first_non_empty(values) when is_tuple(values) do
    values
    |> Tuple.to_list()
    |> Enum.find_value("", fn value ->
      value = String.trim(value || "")
      if value == "", do: nil, else: value
    end)
  end

  defp first_non_empty(a, b, c, d), do: first_non_empty({a, b, c, d})
  defp first_non_empty(a, b), do: first_non_empty({a, b})

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end
end
