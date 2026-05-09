defmodule ServiceRadar.Edge.RemoteAccessSessions do
  @moduledoc """
  Creates and advances generic remote-access session lifecycle records.

  This module owns attach tickets and durable lifecycle metadata only. It does
  not persist SSH private keys, passwords, passphrases, provider tickets, or
  certificate private-key material.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Plugins.ValueUtils

  @default_attach_ttl_seconds 60
  @default_idle_timeout_seconds 900
  @default_absolute_timeout_seconds 3600
  @supported_protocols [
    :ssh,
    :proxmox_console,
    :vsphere_console,
    :rdp,
    :app,
    :database,
    :kubernetes,
    :desktop,
    :ot
  ]
  @supported_adapters @supported_protocols
  @supported_target_kinds [:inventory_device, :provider_console, :freeform_target]
  @supported_custody_modes [
    :ssh_certificate,
    :user_present,
    :centrally_brokered,
    :provider_ticket,
    :none
  ]

  @type create_request :: %{
          optional(:protocol) => atom() | String.t(),
          optional(:adapter) => atom() | String.t(),
          optional(:target_kind) => atom() | String.t(),
          optional(:target_host) => String.t(),
          optional(:target_port) => integer() | String.t(),
          optional(:agent_id) => String.t(),
          optional(:gateway_id) => String.t(),
          optional(:credential_custody_mode) => atom() | String.t(),
          optional(:credential_rule_id) => String.t(),
          optional(:approval_id) => String.t(),
          optional(:cols) => integer(),
          optional(:rows) => integer(),
          optional(:metadata) => map()
        }

  @doc """
  Authorizes and creates a generic remote-access attach ticket.
  """
  @spec request_open(String.t(), create_request(), keyword()) ::
          {:ok, %{session: RemoteAccessSession.t(), ticket: String.t()}} | {:error, term()}
  def request_open(device_uid, request \\ %{}, opts \\ []) when is_binary(device_uid) do
    with {:ok, request} <- normalize_request(request),
         {:ok, %Device{} = device} <- resolve_device(device_uid),
         {:ok, attrs} <- session_attrs(device, request, opts),
         ticket = Map.fetch!(attrs, :__attach_ticket__),
         session_attrs = Map.delete(attrs, :__attach_ticket__),
         {:ok, session} <- RemoteAccessSession.create_session(session_attrs, ash_opts(opts)) do
      write_audit(:remote_access_session_create, session, opts,
        terminal_outcome: nil,
        close_reason: nil,
        failure_reason: nil
      )

      {:ok, %{session: session, ticket: ticket}}
    else
      {:ok, nil} ->
        {:error, :device_not_found}

      {:error, error} = result ->
        if not_found_error?(error) do
          {:error, :device_not_found}
        else
          write_denial_audit(error, device_uid, request, opts)
          result
        end

      error ->
        error
    end
  end

  @doc """
  Consumes a single-use browser attach ticket and marks the session attached.
  """
  @spec attach_with_ticket(String.t(), keyword()) ::
          {:ok, RemoteAccessSession.t()} | {:error, term()}
  def attach_with_ticket(ticket, opts \\ []) when is_binary(ticket) do
    system_opts = [actor: SystemActor.system(:remote_access_ticket)]

    with {:ok, ticket_hash} <- hash_ticket(ticket),
         {:ok, %RemoteAccessSession{} = session} <-
           RemoteAccessSession.get_by_attach_ticket_hash(ticket_hash, system_opts),
         :ok <- ensure_session_match(session, Keyword.get(opts, :session_id)),
         {:ok, attached} <- RemoteAccessSession.attach(session, %{}, system_opts) do
      write_audit(:remote_access_session_attach, attached, opts,
        terminal_outcome: nil,
        close_reason: nil,
        failure_reason: nil
      )

      {:ok, attached}
    else
      {:ok, nil} ->
        {:error, :invalid_or_expired_ticket}

      {:error, error} ->
        if not_found_error?(error),
          do: {:error, :invalid_or_expired_ticket},
          else: {:error, error}

      error ->
        error
    end
  end

  @doc """
  Requests a session close. The broker or agent will complete the close.
  """
  @spec request_close(String.t(), keyword()) :: {:ok, RemoteAccessSession.t()} | {:error, term()}
  def request_close(session_id, opts \\ []) when is_binary(session_id) do
    transition_session(session_id, :request_close, opts, fn session ->
      RemoteAccessSession.request_close(
        session,
        %{
          close_reason: normalize_close_reason(Keyword.get(opts, :reason)),
          outcome: normalize_outcome(Keyword.get(opts, :outcome))
        },
        actor: SystemActor.system(:remote_access_close)
      )
    end)
  end

  @doc """
  Marks a session opening after the selected agent receives an open frame.
  """
  @spec mark_opening(String.t(), keyword()) :: {:ok, RemoteAccessSession.t()} | {:error, term()}
  def mark_opening(session_id, opts \\ []) when is_binary(session_id) do
    transition_session(session_id, :mark_opening, opts, fn session ->
      RemoteAccessSession.mark_opening(
        session,
        command_attrs(opts),
        actor: SystemActor.system(:remote_access_open)
      )
    end)
  end

  @doc """
  Marks a session active after the selected agent reports the adapter is ready.
  """
  @spec activate_session(String.t(), keyword()) ::
          {:ok, RemoteAccessSession.t()} | {:error, term()}
  def activate_session(session_id, opts \\ []) when is_binary(session_id) do
    transition_session(session_id, :activate, opts, fn session ->
      RemoteAccessSession.activate(session, %{}, actor: SystemActor.system(:remote_access_open))
    end)
  end

  @doc """
  Marks a session closed after the edge stream reports a clean close.
  """
  @spec close_session(String.t(), keyword()) :: {:ok, RemoteAccessSession.t()} | {:error, term()}
  def close_session(session_id, opts \\ []) when is_binary(session_id) do
    transition_session(session_id, :close, opts, fn session ->
      RemoteAccessSession.close(
        session,
        %{
          close_reason: normalize_close_reason(Keyword.get(opts, :reason)),
          outcome: normalize_outcome(Keyword.get(opts, :outcome)) || :completed
        },
        actor: SystemActor.system(:remote_access_close)
      )
    end)
  end

  @doc """
  Marks a session expired due to idle, absolute, or attach-ticket timeout.
  """
  @spec expire_session(String.t(), keyword()) :: {:ok, RemoteAccessSession.t()} | {:error, term()}
  def expire_session(session_id, opts \\ []) when is_binary(session_id) do
    transition_session(session_id, :expire, opts, fn session ->
      RemoteAccessSession.expire(
        session,
        %{
          close_reason: normalize_close_reason(Keyword.get(opts, :reason)),
          outcome: normalize_outcome(Keyword.get(opts, :outcome)) || :idle_timeout
        },
        actor: SystemActor.system(:remote_access_expire)
      )
    end)
  end

  @doc """
  Marks a session failed from broker-side setup, policy, route, or adapter errors.
  """
  @spec fail_session(String.t(), term(), keyword()) ::
          {:ok, RemoteAccessSession.t()} | {:error, term()}
  def fail_session(session_id, reason, opts \\ []) when is_binary(session_id) do
    transition_session(session_id, :fail, opts, fn session ->
      RemoteAccessSession.fail_session(
        session,
        %{
          failure_reason: format_failure_reason(reason),
          close_reason: "remote_access_session_failed",
          outcome: normalize_outcome(Keyword.get(opts, :outcome)) || :internal_error
        },
        actor: SystemActor.system(:remote_access_fail)
      )
    end)
  end

  defp transition_session(session_id, transition, opts, fun) do
    system_opts = [actor: SystemActor.system(:remote_access_session_lifecycle)]

    with {:ok, %RemoteAccessSession{} = session} <-
           RemoteAccessSession.get_by_id(session_id, system_opts),
         {:ok, updated} <- fun.(session) do
      write_audit(audit_action(transition), updated, opts,
        terminal_outcome: format_atom(updated.outcome),
        close_reason: updated.close_reason,
        failure_reason: updated.failure_reason
      )

      {:ok, updated}
    else
      {:ok, nil} ->
        {:error, :not_found}

      {:error, error} ->
        if not_found_error?(error), do: {:error, :not_found}, else: {:error, error}

      error ->
        error
    end
  end

  defp resolve_device(device_uid) do
    Device.get_by_uid(device_uid, false,
      actor: SystemActor.system(:remote_access_device_resolver)
    )
  end

  defp session_attrs(device, request, opts) do
    with {:ok, protocol} <- normalize_protocol(value(request, :protocol) || :ssh),
         {:ok, adapter} <- normalize_adapter(value(request, :adapter) || protocol),
         {:ok, target_kind} <-
           normalize_target_kind(value(request, :target_kind) || :inventory_device),
         {:ok, custody_mode} <-
           normalize_custody_mode(value(request, :credential_custody_mode), protocol),
         {:ok, agent_id} <- resolve_agent_id(device, request),
         {:ok, target_host} <- resolve_target_host(device, request),
         {:ok, ticket, ticket_hash} <- new_ticket() do
      now = RemoteAccessSession.utc_now()

      attrs =
        Map.put(
          %{
            attach_ticket_hash: ticket_hash,
            attach_expires_at:
              DateTime.add(
                now,
                Keyword.get(opts, :attach_ttl_seconds, @default_attach_ttl_seconds),
                :second
              ),
            device_uid: device.uid,
            target_kind: target_kind,
            target_host: target_host,
            target_port: int_request(request, :target_port, 22),
            protocol: protocol,
            adapter: adapter,
            agent_id: agent_id,
            gateway_id:
              value(request, :gateway_id) || value_string(device, [:gateway_id, "gateway_id"]),
            credential_custody_mode: custody_mode,
            credential_rule_id: blank_to_nil(value(request, :credential_rule_id)),
            requested_by: requested_by(opts),
            approval_id: blank_to_nil(value(request, :approval_id)),
            rbac_decision: :allowed,
            idle_timeout_seconds:
              int_request(request, :idle_timeout_seconds, @default_idle_timeout_seconds),
            absolute_timeout_seconds:
              int_request(request, :absolute_timeout_seconds, @default_absolute_timeout_seconds),
            recording_policy: sanitized_map(value(request, :recording_policy)),
            enhanced_recording_policy: sanitized_map(value(request, :enhanced_recording_policy)),
            metadata: session_metadata(device, request)
          },
          :__attach_ticket__,
          ticket
        )

      {:ok, attrs}
    end
  end

  defp normalize_request(request) when is_map(request), do: {:ok, request}
  defp normalize_request(_request), do: {:error, :invalid_remote_access_request}

  defp normalize_protocol(value) when is_atom(value) and value in @supported_protocols,
    do: {:ok, value}

  defp normalize_protocol(value) when is_binary(value),
    do: normalize_protocol(to_known_atom(value, @supported_protocols))

  defp normalize_protocol(_value), do: {:error, :unsupported_remote_access_protocol}

  defp normalize_adapter(value) when is_atom(value) and value in @supported_adapters,
    do: {:ok, value}

  defp normalize_adapter(value) when is_binary(value),
    do: normalize_adapter(to_known_atom(value, @supported_adapters))

  defp normalize_adapter(_value), do: {:error, :unsupported_remote_access_adapter}

  defp normalize_target_kind(value) when is_atom(value) and value in @supported_target_kinds,
    do: {:ok, value}

  defp normalize_target_kind(value) when is_binary(value),
    do: normalize_target_kind(to_known_atom(value, @supported_target_kinds))

  defp normalize_target_kind(_value), do: {:error, :unsupported_remote_access_target}

  defp normalize_custody_mode(nil, :ssh), do: {:ok, :ssh_certificate}
  defp normalize_custody_mode(nil, :proxmox_console), do: {:ok, :provider_ticket}
  defp normalize_custody_mode(nil, _protocol), do: {:ok, :none}

  defp normalize_custody_mode(value, _protocol)
       when is_atom(value) and value in @supported_custody_modes,
       do: {:ok, value}

  defp normalize_custody_mode(value, protocol) when is_binary(value) do
    case to_known_atom(value, @supported_custody_modes) do
      nil -> {:error, :unsupported_credential_custody_mode}
      mode -> normalize_custody_mode(mode, protocol)
    end
  end

  defp normalize_custody_mode(_value, _protocol),
    do: {:error, :unsupported_credential_custody_mode}

  defp to_known_atom(value, allowed) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp resolve_agent_id(device, request) do
    case blank_to_nil(value(request, :agent_id) || value_string(device, [:agent_id, "agent_id"])) do
      nil -> {:error, :missing_agent_scope}
      agent_id -> {:ok, agent_id}
    end
  end

  defp resolve_target_host(device, request) do
    case blank_to_nil(value(request, :target_host) || device_hostname(device)) do
      nil -> {:error, :missing_remote_access_target}
      target_host -> {:ok, target_host}
    end
  end

  defp device_hostname(device) do
    value_string(device, [:hostname, "hostname", :name, "name"]) ||
      value_string(device, [:ip, "ip"]) ||
      value_string(device, [:uid, "uid"])
  end

  defp session_metadata(device, request) do
    terminal =
      %{}
      |> put_positive_int("cols", value(request, :cols))
      |> put_positive_int("rows", value(request, :rows))

    request_metadata =
      request
      |> value(:metadata)
      |> sanitized_map()

    target_metadata =
      %{}
      |> maybe_put("device_uid", value_string(device, [:uid, "uid"]))
      |> maybe_put("hostname", value_string(device, [:hostname, "hostname", :name, "name"]))
      |> maybe_put("ip", value_string(device, [:ip, "ip"]))

    %{}
    |> maybe_put("terminal", terminal)
    |> maybe_put("target", target_metadata)
    |> Map.merge(request_metadata)
    |> CredentialRedactor.redact()
  end

  defp new_ticket do
    ticket = "srra_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, ticket_hash} <- hash_ticket(ticket) do
      {:ok, ticket, ticket_hash}
    end
  end

  defp hash_ticket(ticket) when is_binary(ticket) and byte_size(ticket) > 16 do
    {:ok, :sha256 |> :crypto.hash(ticket) |> Base.encode16(case: :lower)}
  end

  defp hash_ticket(_ticket), do: {:error, :invalid_ticket}

  defp ensure_session_match(_session, nil), do: :ok

  defp ensure_session_match(%{id: id}, expected_id) do
    if to_string(id) == to_string(expected_id),
      do: :ok,
      else: {:error, :invalid_or_expired_ticket}
  end

  defp write_audit(action, session, opts, extra_details) do
    actor = audit_actor(opts)

    details =
      %{
        device_uid: session.device_uid,
        target_kind: format_atom(session.target_kind),
        target_host: session.target_host,
        target_port: session.target_port,
        protocol: format_atom(session.protocol),
        adapter: format_atom(session.adapter),
        agent_id: session.agent_id,
        gateway_id: session.gateway_id,
        credential_custody_mode: format_atom(session.credential_custody_mode),
        credential_rule_id: session.credential_rule_id,
        rbac_decision: format_atom(session.rbac_decision),
        approval_id: session.approval_id,
        status: format_atom(session.status)
      }
      |> Map.merge(Map.new(extra_details))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> scrub_session_metadata()
      |> CredentialRedactor.redact()

    audit_writer = Keyword.get(opts, :audit_writer, AuditWriter)

    audit_writer.write_async(
      action: action,
      resource_type: "remote_access_session",
      resource_id: session.id,
      resource_name: session.device_uid || session.target_host,
      actor: actor,
      details: details,
      severity: audit_severity(action),
      message: "Remote access session #{action_suffix(action)}"
    )
  end

  defp write_denial_audit(error, device_uid, request, opts) do
    audit_writer = Keyword.get(opts, :audit_writer, AuditWriter)

    audit_writer.write_async(
      action: :remote_access_session_denied,
      resource_type: "remote_access_session",
      resource_id: device_uid,
      resource_name: device_uid,
      actor: audit_actor(opts),
      details:
        CredentialRedactor.redact(%{
          device_uid: device_uid,
          protocol: format_atom(value(request || %{}, :protocol) || :ssh),
          credential_custody_mode: format_atom(value(request || %{}, :credential_custody_mode)),
          rbac_decision: "denied",
          failure_reason: format_failure_reason(error)
        }),
      severity: :high,
      message: "Remote access session denied"
    )
  end

  defp audit_action(:request_close), do: :remote_access_session_close_requested
  defp audit_action(:close), do: :remote_access_session_closed
  defp audit_action(:expire), do: :remote_access_session_expired
  defp audit_action(:fail), do: :remote_access_session_failed
  defp audit_action(:mark_opening), do: :remote_access_session_opening
  defp audit_action(:activate), do: :remote_access_session_active

  defp command_attrs(opts) do
    case blank_to_nil(Keyword.get(opts, :command_id)) do
      nil -> %{}
      command_id -> %{command_id: command_id}
    end
  end

  defp audit_severity(:remote_access_session_failed), do: :high
  defp audit_severity(:remote_access_session_denied), do: :high
  defp audit_severity(_action), do: :medium

  defp action_suffix(:remote_access_session_create), do: "created"
  defp action_suffix(:remote_access_session_attach), do: "attached"
  defp action_suffix(:remote_access_session_close_requested), do: "close requested"
  defp action_suffix(:remote_access_session_closed), do: "closed"
  defp action_suffix(:remote_access_session_expired), do: "expired"
  defp action_suffix(:remote_access_session_failed), do: "failed"
  defp action_suffix(:remote_access_session_opening), do: "opening"
  defp action_suffix(:remote_access_session_active), do: "active"
  defp action_suffix(action), do: Atom.to_string(action)

  defp ash_opts(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} -> [scope: scope]
      :error -> [actor: Keyword.get(opts, :actor, SystemActor.system(:remote_access_sessions))]
    end
  end

  defp audit_actor(opts) do
    case Keyword.get(opts, :scope) do
      %{user: user} when not is_nil(user) -> user
      _ -> Keyword.get(opts, :actor)
    end
  end

  defp requested_by(opts) do
    case audit_actor(opts) do
      %{id: id} when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> uuid
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp sanitized_map(value) when is_map(value) do
    value
    |> scrub_session_metadata()
    |> CredentialRedactor.redact()
  end

  defp sanitized_map(_value), do: %{}

  defp scrub_session_metadata(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      if sensitive_metadata_key?(key) do
        {key, "REDACTED"}
      else
        {key, scrub_session_metadata(nested_value)}
      end
    end)
  end

  defp scrub_session_metadata(value) when is_list(value),
    do: Enum.map(value, &scrub_session_metadata/1)

  defp scrub_session_metadata(value), do: value

  defp sensitive_metadata_key?(key) when is_atom(key),
    do: sensitive_metadata_key?(Atom.to_string(key))

  defp sensitive_metadata_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    normalized in [
      "credential",
      "credentials",
      "passphrase",
      "password",
      "private_key",
      "secret",
      "secret_payload",
      "ticket",
      "token"
    ] or String.ends_with?(normalized, "_credential") or
      String.ends_with?(normalized, "_password") or
      String.ends_with?(normalized, "_secret") or String.ends_with?(normalized, "_ticket") or
      String.ends_with?(normalized, "_token")
  end

  defp sensitive_metadata_key?(_key), do: false

  defp int_request(request, key, default) do
    case value(request, key) || default do
      int when is_integer(int) and int > 0 ->
        int

      string when is_binary(string) ->
        case Integer.parse(string) do
          {int, ""} when int > 0 -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp put_positive_int(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp put_positive_int(map, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> Map.put(map, key, int)
      _ -> map
    end
  end

  defp put_positive_int(map, _key, _value), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil

  defp value_string(source, keys) do
    source
    |> ValueUtils.string_value(keys)
    |> blank_to_nil()
  rescue
    _ -> nil
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp normalize_close_reason(reason) when is_binary(reason) do
    reason
    |> String.slice(0, 240)
    |> blank_to_nil()
  end

  defp normalize_close_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_close_reason(_reason), do: nil

  defp normalize_outcome(value) when is_atom(value), do: value
  defp normalize_outcome(value) when is_binary(value), do: to_known_atom(value, outcome_values())
  defp normalize_outcome(_value), do: nil

  defp outcome_values do
    [
      :completed,
      :idle_timeout,
      :absolute_timeout,
      :agent_disconnected,
      :target_unreachable,
      :credential_rejected,
      :credential_policy_denied,
      :rbac_denied,
      :protocol_error,
      :internal_error
    ]
  end

  defp format_failure_reason(reason) when is_binary(reason),
    do: reason |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)

  defp format_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_failure_reason(reason), do: inspect(reason, printable_limit: 200, limit: 20)

  defp format_atom(nil), do: nil
  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(value), do: to_string(value)

  defp not_found_error?(%NotFound{}), do: true

  defp not_found_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &not_found_error?/1)

  defp not_found_error?(_error), do: false
end
