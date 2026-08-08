defmodule ServiceRadar.Edge.RemoteAccessCentralCredentialGrants do
  @moduledoc """
  Builds scoped central credential broker grants for remote-access sessions.

  Grants are references, not decrypted credentials. The returned broker opts are
  intended to stay in memory for one attach/open attempt and bind a credential
  rule to exactly one session, agent, protocol, and target.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  @grant_schema "serviceradar.edge_credential_broker_grant.v1"
  @grant_type "ssh_session"
  @default_ttl_seconds 60
  @max_ttl_seconds 300

  @type grant :: %{
          broker_opts: keyword(),
          audit: map()
        }

  @spec build_broker_grant(map() | struct(), keyword()) :: {:ok, grant()} | {:error, term()}
  def build_broker_grant(session, opts \\ [])

  def build_broker_grant(session, opts) when is_map(session) do
    with {:ok, rule_id} <-
           required_string(
             session,
             [:credential_rule_id, "credential_rule_id"],
             :credential_rule_required
           ),
         {:ok, %NetworkCredentialRule{} = rule} <- fetch_rule(rule_id, opts),
         :ok <- ensure_rule_enabled(rule),
         :ok <- ensure_rule_protocol(rule, session),
         :ok <- ensure_rule_purpose(rule),
         :ok <- ensure_rule_scope(rule, session),
         {:ok, secret_id} <-
           required_string(rule, [:secret_id, "secret_id"], :credential_secret_required),
         {:ok, target} <- session_target(session) do
      grant = broker_grant(session, rule, secret_id, target)

      {:ok,
       %{
         broker_opts: [
           metadata: %{"credential_broker" => grant},
           credential_mode: "centrally_brokered"
         ],
         audit: audit_grant(session, rule, grant)
       }}
    end
  end

  def build_broker_grant(_session, _opts), do: {:error, :invalid_request}

  defp fetch_rule(rule_id, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:remote_access_central_credential_grant))

    case NetworkCredentialRule.get_by_id(rule_id, actor: actor) do
      {:ok, %NetworkCredentialRule{} = rule} -> {:ok, rule}
      {:ok, nil} -> {:error, :credential_rule_not_found}
      {:error, %NotFound{}} -> {:error, :credential_rule_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_rule_enabled(%NetworkCredentialRule{enabled: true}), do: :ok
  defp ensure_rule_enabled(_rule), do: {:error, :credential_rule_disabled}

  defp ensure_rule_protocol(%NetworkCredentialRule{provider: provider}, session) do
    if provider == value_string(session, [:protocol, "protocol"]),
      do: :ok,
      else: {:error, :credential_rule_protocol_mismatch}
  end

  defp ensure_rule_purpose(%NetworkCredentialRule{purpose: purpose})
       when purpose in ["console_access", "generic"],
       do: :ok

  defp ensure_rule_purpose(_rule), do: {:error, :credential_rule_purpose_mismatch}

  defp ensure_rule_scope(
         %NetworkCredentialRule{scope_type: :agent, scope_value: scope_value},
         session
       ) do
    if scope_value == value_string(session, [:agent_id, "agent_id"]),
      do: :ok,
      else: {:error, :credential_rule_scope_mismatch}
  end

  defp ensure_rule_scope(
         %NetworkCredentialRule{scope_type: :gateway, scope_value: scope_value},
         session
       ) do
    if scope_value == value_string(session, [:gateway_id, "gateway_id"]),
      do: :ok,
      else: {:error, :credential_rule_scope_mismatch}
  end

  defp ensure_rule_scope(_rule, _session), do: {:error, :credential_rule_scope_mismatch}

  defp broker_grant(session, rule, secret_id, target) do
    ttl_seconds = grant_ttl(rule)

    compact_map(%{
      "schema" => @grant_schema,
      "grant_type" => @grant_type,
      "session_id" => value_string(session, [:id, "id", :session_id, "session_id"]),
      "actor_id" => value_string(session, [:requested_by, "requested_by"]),
      "agent_id" => value_string(session, [:agent_id, "agent_id"]),
      "gateway_id" => value_string(session, [:gateway_id, "gateway_id"]),
      "protocol" => value_string(session, [:protocol, "protocol"]),
      "credential_rule_id" => value_string(rule, [:id, "id"]),
      "credential_secret_ref" =>
        SecretRefs.network_credential_grant_ref(secret_id,
          ttl_seconds: ttl_seconds,
          claims: %{
            "session_id" => value_string(session, [:id, "id", :session_id, "session_id"]),
            "actor_id" => value_string(session, [:requested_by, "requested_by"]),
            "agent_id" => value_string(session, [:agent_id, "agent_id"]),
            "gateway_id" => value_string(session, [:gateway_id, "gateway_id"]),
            "protocol" => value_string(session, [:protocol, "protocol"]),
            "target" => target
          }
        ),
      "target" => target,
      "allow" => %{
        "protocols" => [value_string(session, [:protocol, "protocol"])],
        "hosts" => [Map.fetch!(target, "host")],
        "ports" => [Map.fetch!(target, "port")]
      },
      "ttl_seconds" => ttl_seconds
    })
  end

  defp audit_grant(session, rule, grant) do
    %{
      credential_custody_mode: "centrally_brokered",
      credential_mode: "centrally_brokered",
      session_id: Map.get(grant, "session_id"),
      agent_id: Map.get(grant, "agent_id"),
      gateway_id: Map.get(grant, "gateway_id"),
      protocol: Map.get(grant, "protocol"),
      credential_rule_id: value_string(rule, [:id, "id"]),
      target_ref: value_string(session, [:device_uid, "device_uid"]),
      ttl_seconds: Map.get(grant, "ttl_seconds")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
    |> CredentialRedactor.redact()
  end

  defp session_target(session) do
    host = value_string(session, [:target_host, "target_host"])
    port = ValueUtils.int_value(session, [:target_port, "target_port"], nil)

    cond do
      is_nil(host) or host == "" ->
        {:error, :missing_remote_access_target}

      not is_integer(port) or port < 1 or port > 65_535 ->
        {:error, :invalid_remote_access_target_port}

      true ->
        {:ok,
         compact_map(%{
           "device_uid" => value_string(session, [:device_uid, "device_uid"]),
           "host" => host,
           "port" => port
         })}
    end
  end

  defp grant_ttl(rule) do
    metadata = ValueUtils.map_value(rule, [:metadata, "metadata"], stringify_keys: true) || %{}

    metadata
    |> ValueUtils.int_value(["credential_broker_ttl_seconds"], @default_ttl_seconds)
    |> clamp(1, @max_ttl_seconds)
  end

  defp required_string(map, keys, error) do
    case value_string(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)

  defp clamp(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp(_value, min, _max), do: min

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
    |> Map.new()
  end
end
