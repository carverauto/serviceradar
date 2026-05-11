defmodule ServiceRadar.Edge.ProxmoxConsoleSessions do
  @moduledoc """
  Creates and consumes short-lived Proxmox console tickets.

  This module deliberately handles session tickets only. It does not resolve
  SSH private keys or Proxmox tickets; the edge console broker will use the
  stored credential rule ID to request scoped credential material later.
  """

  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Edge.RemoteConsoleTarget
  alias ServiceRadar.Edge.RemoteConsoleTargetResolver
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Plugins.ValueUtils

  @provider "proxmox"
  @default_ticket_ttl_seconds 60
  @default_idle_timeout_seconds 900
  @default_absolute_timeout_seconds 3600

  @type create_request :: %{
          optional(:target_kind) => atom() | String.t(),
          optional(:console_mode) => atom() | String.t(),
          optional(:credential_rule_id) => String.t(),
          optional(:cols) => integer(),
          optional(:rows) => integer(),
          optional(:metadata) => map()
        }

  @doc """
  Authorizes and creates a console session ticket for a canonical device UID.
  """
  @spec request_open(String.t(), create_request(), keyword()) ::
          {:ok, %{session: ProxmoxConsoleSession.t(), ticket: String.t()}} | {:error, term()}
  def request_open(device_uid, request \\ %{}, opts \\ []) when is_binary(device_uid) do
    ash_opts = ash_opts(opts)
    system_opts = [actor: SystemActor.system(:proxmox_console_sessions)]

    with {:ok, %Device{} = device} <- Device.get_by_uid(device_uid, false, ash_opts),
         {:ok, target} <- resolve_target(device, request, system_opts),
         {:ok, rule} <- resolve_credential_rule(device, request, opts),
         {:ok, agent_id} <- resolve_agent_id(device, rule),
         {:ok, ticket, ticket_hash} <- new_ticket(),
         attrs = session_attrs(device, target, rule, agent_id, ticket_hash, request, opts),
         {:ok, session} <- ProxmoxConsoleSession.create_session(attrs, ash_opts) do
      write_audit(:proxmox_console_session_create, session, opts,
        close_reason: nil,
        failure_reason: nil
      )

      {:ok, %{session: session, ticket: ticket}}
    else
      {:ok, nil} ->
        {:error, :device_not_found}

      {:error, error} ->
        if not_found_error?(error), do: {:error, :device_not_found}, else: {:error, error}

      error ->
        error
    end
  end

  @doc """
  Consumes a single-use browser ticket and marks the matching session attached.
  """
  @spec attach_with_ticket(String.t(), keyword()) ::
          {:ok, ProxmoxConsoleSession.t()} | {:error, term()}
  def attach_with_ticket(ticket, opts \\ []) when is_binary(ticket) do
    system_opts = [actor: SystemActor.system(:proxmox_console_ticket)]

    with {:ok, ticket_hash} <- hash_ticket(ticket),
         {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSession.get_by_ticket_hash(ticket_hash, system_opts),
         :ok <- ensure_session_match(session, Keyword.get(opts, :session_id)),
         {:ok, attached} <- ProxmoxConsoleSession.attach(session, %{}, system_opts) do
      write_audit(:proxmox_console_session_attach, attached, opts,
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

  defp ensure_session_match(_session, nil), do: :ok

  defp ensure_session_match(%{id: id}, expected_id) do
    if to_string(id) == to_string(expected_id),
      do: :ok,
      else: {:error, :invalid_or_expired_ticket}
  end

  @doc """
  Requests a console close. The broker will complete the close asynchronously.
  """
  @spec request_close(String.t(), keyword()) ::
          {:ok, ProxmoxConsoleSession.t()} | {:error, term()}
  def request_close(session_id, opts \\ []) when is_binary(session_id) do
    ash_opts = ash_opts(opts)

    with {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSession.get_by_id(session_id, ash_opts),
         {:ok, closing} <-
           ProxmoxConsoleSession.request_close(
             session,
             %{close_reason: normalize_close_reason(Keyword.get(opts, :reason))},
             actor: SystemActor.system(:proxmox_console_close)
           ) do
      write_audit(:proxmox_console_session_close_requested, closing, opts,
        close_reason: closing.close_reason,
        failure_reason: nil
      )

      {:ok, closing}
    else
      {:ok, nil} ->
        {:error, :not_found}

      {:error, error} ->
        if not_found_error?(error), do: {:error, :not_found}, else: {:error, error}

      error ->
        error
    end
  end

  @doc """
  Marks a console session closed after the edge stream reports a clean close.
  """
  @spec close_session(String.t(), keyword()) ::
          {:ok, ProxmoxConsoleSession.t()} | {:error, term()}
  def close_session(session_id, opts \\ []) when is_binary(session_id) do
    ash_opts = [actor: SystemActor.system(:proxmox_console_close)]

    with {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSession.get_by_id(session_id, ash_opts),
         {:ok, closed} <-
           ProxmoxConsoleSession.close(
             session,
             %{close_reason: normalize_close_reason(Keyword.get(opts, :reason))},
             ash_opts
           ) do
      write_audit(:proxmox_console_session_closed, closed, opts,
        close_reason: closed.close_reason,
        failure_reason: nil
      )

      {:ok, closed}
    else
      {:ok, nil} ->
        {:error, :not_found}

      {:error, error} ->
        if not_found_error?(error), do: {:error, :not_found}, else: {:error, error}

      error ->
        error
    end
  end

  @doc """
  Marks a console session expired due to idle or absolute timeout enforcement.
  """
  @spec expire_session(String.t(), keyword()) ::
          {:ok, ProxmoxConsoleSession.t()} | {:error, term()}
  def expire_session(session_id, opts \\ []) when is_binary(session_id) do
    ash_opts = [actor: SystemActor.system(:proxmox_console_expire)]

    with {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSession.get_by_id(session_id, ash_opts),
         {:ok, expired} <-
           ProxmoxConsoleSession.expire(
             session,
             %{close_reason: normalize_close_reason(Keyword.get(opts, :reason))},
             ash_opts
           ) do
      write_audit(:proxmox_console_session_expired, expired, opts,
        close_reason: expired.close_reason,
        failure_reason: nil
      )

      {:ok, expired}
    else
      {:ok, nil} ->
        {:error, :not_found}

      {:error, error} ->
        if not_found_error?(error), do: {:error, :not_found}, else: {:error, error}

      error ->
        error
    end
  end

  @doc """
  Marks a console session failed from broker-side stream setup or runtime errors.
  """
  @spec fail_session(String.t(), term(), keyword()) ::
          {:ok, ProxmoxConsoleSession.t()} | {:error, term()}
  def fail_session(session_id, reason, opts \\ []) when is_binary(session_id) do
    ash_opts = [actor: SystemActor.system(:proxmox_console_fail)]

    with {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSession.get_by_id(session_id, ash_opts),
         {:ok, failed} <-
           ProxmoxConsoleSession.fail_session(
             session,
             %{
               failure_reason: format_failure_reason(reason),
               close_reason: "console_session_failed"
             },
             ash_opts
           ) do
      write_audit(:proxmox_console_session_failed, failed, opts,
        close_reason: failed.close_reason,
        failure_reason: failed.failure_reason
      )

      {:ok, failed}
    else
      {:ok, nil} ->
        {:error, :not_found}

      {:error, error} ->
        if not_found_error?(error), do: {:error, :not_found}, else: {:error, error}

      error ->
        error
    end
  end

  defp resolve_target(device, request, system_opts) do
    RemoteConsoleTargetResolver.resolve_proxmox(device, request, ash_opts: system_opts)
  end

  defp resolve_credential_rule(device, request, opts) do
    system_actor = SystemActor.system(:proxmox_console_rule_resolver)

    case request_credential_rule_id(request) do
      nil ->
        resolve_first_matching_rule(device, system_actor, opts)

      rule_id ->
        with {:ok, %NetworkCredentialRule{} = rule} <-
               NetworkCredentialRule.get_by_id(rule_id, actor: system_actor),
             :ok <- ensure_console_rule(rule),
             :ok <- ensure_rule_scope_allows_device(rule, device),
             :ok <- ensure_rule_targets_device(rule, device, opts) do
          {:ok, rule}
        end
    end
  end

  defp resolve_first_matching_rule(device, system_actor, opts) do
    device
    |> rule_scopes()
    |> Enum.reduce_while({:error, :no_console_credential_rule}, fn {scope_type, scope_value},
                                                                   _acc ->
      case NetworkCredentialRule.list_enabled_for_scope(@provider, scope_type, scope_value,
             actor: system_actor
           ) do
        {:ok, rules} ->
          case Enum.find(rules, &matching_console_rule?(&1, device, opts)) do
            nil -> {:cont, {:error, :no_console_credential_rule}}
            rule -> {:halt, {:ok, rule}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp matching_console_rule?(rule, device, opts) do
    ensure_console_rule(rule) == :ok and
      ensure_rule_scope_allows_device(rule, device) == :ok and
      ensure_rule_targets_device(rule, device, opts) == :ok
  end

  defp ensure_console_rule(%{provider: @provider, purpose: :console_access}), do: :ok
  defp ensure_console_rule(%{provider: @provider, purpose: "console_access"}), do: :ok
  defp ensure_console_rule(_rule), do: {:error, :not_console_credential_rule}

  defp ensure_rule_scope_allows_device(rule, device) do
    if {rule_scope_type(rule), value_string(rule, [:scope_value, "scope_value"])} in rule_scopes(
         device
       ) do
      :ok
    else
      {:error, :credential_rule_scope_denied}
    end
  end

  defp ensure_rule_targets_device(rule, device, opts) do
    previewer = Keyword.get(opts, :previewer, NetworkCredentialRulePreview)

    case previewer.preview_rule(rule,
           sample_limit: Keyword.get(opts, :target_sample_limit, 5_000),
           detect_conflicts?: false
         ) do
      {:ok, %{sample_devices: sample_devices}} ->
        if Enum.any?(
             sample_devices,
             &(value_string(&1, [:uid, "uid", :device_uid, "device_uid"]) == device.uid)
           ) do
          :ok
        else
          {:error, :credential_rule_target_denied}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_agent_id(device, rule) do
    case rule_scope_type(rule) do
      :agent -> {:ok, value_string(rule, [:scope_value, "scope_value"])}
      _ -> required_agent_id(device)
    end
  end

  defp session_attrs(device, target, rule, agent_id, ticket_hash, request, opts) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %{
      ticket_hash: ticket_hash,
      ticket_expires_at:
        DateTime.add(
          now,
          Keyword.get(opts, :ticket_ttl_seconds, @default_ticket_ttl_seconds),
          :second
        ),
      device_uid: device.uid,
      target_kind: target.target_kind,
      console_mode: target.console_mode,
      agent_id: agent_id,
      gateway_id: value_string(device, [:gateway_id, "gateway_id"]),
      credential_rule_id: value_string(rule, [:id, "id"]),
      requested_by: requested_by(opts),
      idle_timeout_seconds:
        int_request(request, :idle_timeout_seconds, @default_idle_timeout_seconds),
      absolute_timeout_seconds:
        int_request(request, :absolute_timeout_seconds, @default_absolute_timeout_seconds),
      metadata: session_metadata(device, target, agent_id, request)
    }
  end

  defp session_metadata(device, target, agent_id, request) do
    terminal =
      %{}
      |> put_positive_int("cols", Map.get(request, :cols) || Map.get(request, "cols"))
      |> put_positive_int("rows", Map.get(request, :rows) || Map.get(request, "rows"))

    request_metadata =
      request
      |> Map.get(:metadata, Map.get(request, "metadata", %{}))
      |> CredentialRedactor.redact()

    target_metadata = target_metadata(device)

    remote_console_target =
      device
      |> RemoteConsoleTarget.proxmox(Map.put(target, :agent_id, agent_id))
      |> RemoteConsoleTarget.to_metadata()

    if_result = if(is_map(request_metadata), do: request_metadata, else: %{})

    if_result
    |> maybe_put("terminal", terminal)
    |> maybe_put("target", target_metadata)
    |> maybe_put("remote_console", remote_console_target)
  end

  defp target_metadata(device) do
    %{}
    |> maybe_put("device_uid", value_string(device, [:uid, "uid"]))
    |> maybe_put("hostname", value_string(device, [:hostname, "hostname", :name, "name"]))
    |> maybe_put("ip", value_string(device, [:ip, "ip"]))
    |> put_positive_int(
      "ssh_port",
      ValueUtils.int_value(device.metadata, ["ssh_port", :ssh_port], 22)
    )
  end

  defp new_ticket do
    ticket = "srpve_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, ticket_hash} <- hash_ticket(ticket) do
      {:ok, ticket, ticket_hash}
    end
  end

  defp hash_ticket(ticket) when is_binary(ticket) and byte_size(ticket) > 16 do
    {:ok, :sha256 |> :crypto.hash(ticket) |> Base.encode16(case: :lower)}
  end

  defp hash_ticket(_ticket), do: {:error, :invalid_ticket}

  defp write_audit(action, session, opts, extra_details) do
    actor = audit_actor(opts)

    details =
      %{
        device_uid: session.device_uid,
        target_kind: format_atom(session.target_kind),
        console_mode: format_atom(session.console_mode),
        provider: remote_console_metadata_value(session, "provider"),
        target_ref: remote_console_metadata_value(session, "target_ref"),
        target_type: remote_console_metadata_value(session, "target_type"),
        protocol: remote_console_metadata_value(session, "protocol"),
        transport: remote_console_metadata_value(session, "transport"),
        agent_id: session.agent_id,
        gateway_id: session.gateway_id,
        credential_rule_id: session.credential_rule_id,
        status: format_atom(session.status)
      }
      |> Map.merge(Map.new(extra_details))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    audit_writer = Keyword.get(opts, :audit_writer, AuditWriter)

    audit_writer.write_async(
      action: action,
      resource_type: "proxmox_console_session",
      resource_id: session.id,
      resource_name: session.device_uid,
      actor: actor,
      details: details,
      severity: :medium,
      message: "Proxmox console session #{action_suffix(action)}"
    )
  end

  defp action_suffix(:proxmox_console_session_create), do: "created"
  defp action_suffix(:proxmox_console_session_attach), do: "attached"
  defp action_suffix(:proxmox_console_session_close_requested), do: "close requested"
  defp action_suffix(:proxmox_console_session_closed), do: "closed"
  defp action_suffix(:proxmox_console_session_expired), do: "expired"
  defp action_suffix(action), do: Atom.to_string(action)

  defp remote_console_metadata_value(%{metadata: %{"remote_console" => metadata}}, key)
       when is_map(metadata),
       do: Map.get(metadata, key)

  defp remote_console_metadata_value(_session, _key), do: nil

  defp ash_opts(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} -> [scope: scope]
      :error -> [actor: Keyword.get(opts, :actor, SystemActor.system(:proxmox_console_sessions))]
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

  defp request_credential_rule_id(request) do
    request
    |> value_string([:credential_rule_id, "credential_rule_id"])
    |> blank_to_nil()
  end

  defp rule_scopes(device) do
    [
      {:agent, device_agent_id(device)},
      {:gateway, value_string(device, [:gateway_id, "gateway_id"])},
      {:partition, partition_value(device)}
    ]
    |> Enum.reject(fn {_type, value} -> is_nil(value) or value == "" end)
    |> Enum.uniq()
  end

  defp device_agent_id(device) do
    value_string(device, [:agent_id, "agent_id"]) ||
      device_metadata_string(device, [
        :sync_service_id,
        "sync_service_id",
        :agent_id,
        "agent_id",
        :source_agent_id,
        "source_agent_id",
        :discovered_by_agent_id,
        "discovered_by_agent_id"
      ])
  end

  defp partition_value(%{metadata: metadata}) when is_map(metadata) do
    value_string(metadata, [:partition_id, "partition_id", :partition, "partition", :site, "site"])
  end

  defp partition_value(_device), do: nil

  defp device_metadata_string(%{metadata: metadata}, keys) when is_map(metadata),
    do: value_string(metadata, keys)

  defp device_metadata_string(_device, _keys), do: nil

  defp rule_scope_type(rule) do
    case value_string(rule, [:scope_type, "scope_type"]) do
      "agent" -> :agent
      "gateway" -> :gateway
      "partition" -> :partition
      :agent -> :agent
      :gateway -> :gateway
      :partition -> :partition
      _ -> nil
    end
  end

  defp int_request(request, key, default) do
    value =
      Map.get(request, key) ||
        Map.get(request, Atom.to_string(key)) ||
        default

    case value do
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

  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_close_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)
    if reason == "", do: "operator_requested", else: reason
  end

  defp normalize_close_reason(_reason), do: "operator_requested"

  defp format_failure_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)

  defp format_failure_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> format_failure_reason()

  defp format_failure_reason(reason), do: reason |> inspect() |> format_failure_reason()

  defp required_agent_id(device) do
    case device_agent_id(device) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_agent_scope}
    end
  end

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)

  defp not_found_error?(%NotFound{}), do: true

  defp not_found_error?(%Invalid{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &not_found_error?/1)

  defp not_found_error?(_error), do: false

  defp blank_to_nil(value) when value in ["", nil], do: nil
  defp blank_to_nil(value), do: value

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(value), do: value
end
