defmodule ServiceRadar.Edge.ProxmoxConsoleSessions do
  @moduledoc """
  Creates and consumes short-lived Proxmox console tickets.

  This module deliberately handles session tickets only. It does not resolve
  SSH private keys or Proxmox tickets; the edge console broker will use the
  stored credential rule ID to request scoped credential material later.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @provider "proxmox"
  @default_ticket_ttl_seconds 60
  @default_idle_timeout_seconds 900
  @default_absolute_timeout_seconds 3600
  @supported_target_kinds [:pve_host, :qemu_guest, :lxc_guest]
  @supported_console_modes [:ssh, :proxmox_termproxy, :proxmox_vncwebsocket]

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
      {:ok, nil} -> {:error, :device_not_found}
      {:error, %NotFound{}} -> {:error, :device_not_found}
      error -> error
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
      {:ok, nil} -> {:error, :invalid_or_expired_ticket}
      {:error, %NotFound{}} -> {:error, :invalid_or_expired_ticket}
      error -> error
    end
  end

  defp ensure_session_match(_session, nil), do: :ok

  defp ensure_session_match(%{id: id}, expected_id) do
    if to_string(id) == to_string(expected_id), do: :ok, else: {:error, :invalid_or_expired_ticket}
  end

  @doc """
  Requests a console close. The broker will complete the close asynchronously.
  """
  @spec request_close(String.t(), keyword()) :: {:ok, ProxmoxConsoleSession.t()} | {:error, term()}
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
      {:ok, nil} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Marks a console session failed from broker-side stream setup or runtime errors.
  """
  @spec fail_session(String.t(), term(), keyword()) :: {:ok, ProxmoxConsoleSession.t()} | {:error, term()}
  def fail_session(session_id, reason, opts \\ []) when is_binary(session_id) do
    ash_opts = [actor: SystemActor.system(:proxmox_console_fail)]

    with {:ok, %ProxmoxConsoleSession{} = session} <- ProxmoxConsoleSession.get_by_id(session_id, ash_opts),
         {:ok, failed} <-
           ProxmoxConsoleSession.fail_session(
             session,
             %{failure_reason: format_failure_reason(reason), close_reason: "console_session_failed"},
             ash_opts
           ) do
      write_audit(:proxmox_console_session_failed, failed, opts,
        close_reason: failed.close_reason,
        failure_reason: failed.failure_reason
      )

      {:ok, failed}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      error -> error
    end
  end

  defp resolve_target(device, request, system_opts) do
    requested_kind = normalize_target_kind(Map.get(request, :target_kind) || Map.get(request, "target_kind"))
    requested_mode = normalize_console_mode(Map.get(request, :console_mode) || Map.get(request, "console_mode"))

    with {:ok, inferred_kind} <- infer_target_kind(device, system_opts),
         {:ok, target_kind} <- pick_target_kind(requested_kind, inferred_kind),
         {:ok, console_mode} <- pick_console_mode(requested_mode, target_kind) do
      {:ok, %{target_kind: target_kind, console_mode: console_mode}}
    end
  end

  defp infer_target_kind(device, system_opts) do
    with {:ok, hosts} <- virtualization_by_device(VirtualizationHost, device.uid, system_opts),
         {:host, []} <- {:host, hosts},
         {:ok, guests} <- virtualization_by_device(VirtualizationGuest, device.uid, system_opts),
         {:guest, []} <- {:guest, guests} do
      infer_target_kind_from_device(device)
    else
      {:host, [_host | _]} -> {:ok, :pve_host}
      {:guest, [%{guest_type: "lxc"} | _]} -> {:ok, :lxc_guest}
      {:guest, [%{guest_type: "qemu"} | _]} -> {:ok, :qemu_guest}
      {:guest, [_guest | _]} -> {:ok, :qemu_guest}
      {:error, _reason} -> infer_target_kind_from_device(device)
    end
  end

  defp virtualization_by_device(resource, device_uid, ash_opts) do
    resource
    |> Ash.Query.for_read(:by_device, %{device_uid: device_uid})
    |> Ash.read(ash_opts)
  end

  defp infer_target_kind_from_device(%{vendor_name: vendor}) when is_binary(vendor) do
    if String.downcase(vendor) =~ "proxmox", do: {:ok, :pve_host}, else: {:error, :unsupported_console_target}
  end

  defp infer_target_kind_from_device(%{metadata: metadata}) when is_map(metadata) do
    case ValueUtils.string_value(metadata, ["proxmox_guest_type", :proxmox_guest_type, "guest_type", :guest_type]) do
      "lxc" -> {:ok, :lxc_guest}
      "qemu" -> {:ok, :qemu_guest}
      _ -> {:error, :unsupported_console_target}
    end
  end

  defp infer_target_kind_from_device(_device), do: {:error, :unsupported_console_target}

  defp pick_target_kind(nil, inferred), do: {:ok, inferred}
  defp pick_target_kind(kind, _inferred) when kind in @supported_target_kinds, do: {:ok, kind}
  defp pick_target_kind(_kind, _inferred), do: {:error, :unsupported_console_target}

  defp pick_console_mode(nil, :pve_host), do: {:ok, :ssh}
  defp pick_console_mode(nil, _guest_kind), do: {:ok, :proxmox_termproxy}
  defp pick_console_mode(:ssh, :pve_host), do: {:ok, :ssh}

  defp pick_console_mode(mode, target_kind)
       when mode in [:proxmox_termproxy, :proxmox_vncwebsocket] and target_kind in [:qemu_guest, :lxc_guest],
       do: {:ok, mode}

  defp pick_console_mode(mode, _target_kind) when mode in @supported_console_modes,
    do: {:error, :unsupported_console_mode}

  defp pick_console_mode(_mode, _target_kind), do: {:error, :unsupported_console_mode}

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
    |> Enum.reduce_while({:error, :no_console_credential_rule}, fn {scope_type, scope_value}, _acc ->
      case NetworkCredentialRule.list_enabled_for_scope(@provider, scope_type, scope_value, actor: system_actor) do
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
    if {rule_scope_type(rule), value_string(rule, [:scope_value, "scope_value"])} in rule_scopes(device) do
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
        if Enum.any?(sample_devices, &(value_string(&1, [:uid, "uid", :device_uid, "device_uid"]) == device.uid)) do
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
      _ -> required_string(device, [:agent_id, "agent_id"], :missing_agent_scope)
    end
  end

  defp session_attrs(device, target, rule, agent_id, ticket_hash, request, opts) do
    %{
      ticket_hash: ticket_hash,
      ticket_expires_at:
        DateTime.add(DateTime.utc_now(), Keyword.get(opts, :ticket_ttl_seconds, @default_ticket_ttl_seconds), :second),
      device_uid: device.uid,
      target_kind: target.target_kind,
      console_mode: target.console_mode,
      agent_id: agent_id,
      gateway_id: value_string(device, [:gateway_id, "gateway_id"]),
      credential_rule_id: value_string(rule, [:id, "id"]),
      requested_by: requested_by(opts),
      idle_timeout_seconds: int_request(request, :idle_timeout_seconds, @default_idle_timeout_seconds),
      absolute_timeout_seconds: int_request(request, :absolute_timeout_seconds, @default_absolute_timeout_seconds),
      metadata: session_metadata(request)
    }
  end

  defp session_metadata(request) do
    terminal =
      %{}
      |> put_positive_int("cols", Map.get(request, :cols) || Map.get(request, "cols"))
      |> put_positive_int("rows", Map.get(request, :rows) || Map.get(request, "rows"))

    request_metadata = Map.get(request, :metadata) || Map.get(request, "metadata") || %{}

    %{}
    |> maybe_put("terminal", terminal)
    |> Map.merge(if(is_map(request_metadata), do: request_metadata, else: %{}))
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
  defp action_suffix(action), do: Atom.to_string(action)

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
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp request_credential_rule_id(request) do
    request
    |> value_string([:credential_rule_id, "credential_rule_id"])
    |> blank_to_nil()
  end

  defp rule_scopes(device) do
    Enum.reject(
      [
        {:agent, value_string(device, [:agent_id, "agent_id"])},
        {:gateway, value_string(device, [:gateway_id, "gateway_id"])},
        {:partition, partition_value(device)}
      ],
      fn {_type, value} -> is_nil(value) or value == "" end
    )
  end

  defp partition_value(%{metadata: metadata}) when is_map(metadata) do
    value_string(metadata, [:partition_id, "partition_id", :partition, "partition", :site, "site"])
  end

  defp partition_value(_device), do: nil

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

  defp normalize_target_kind(value) when is_atom(value) and value in @supported_target_kinds, do: value
  defp normalize_target_kind("pve_host"), do: :pve_host
  defp normalize_target_kind("qemu_guest"), do: :qemu_guest
  defp normalize_target_kind("lxc_guest"), do: :lxc_guest
  defp normalize_target_kind(_value), do: nil

  defp normalize_console_mode(value) when is_atom(value) and value in @supported_console_modes, do: value
  defp normalize_console_mode("ssh"), do: :ssh
  defp normalize_console_mode("proxmox_termproxy"), do: :proxmox_termproxy
  defp normalize_console_mode("proxmox_vncwebsocket"), do: :proxmox_vncwebsocket
  defp normalize_console_mode(_value), do: nil

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

  defp put_positive_int(map, key, value) when is_integer(value) and value > 0, do: Map.put(map, key, value)

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
  defp format_failure_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> format_failure_reason()
  defp format_failure_reason(reason), do: reason |> inspect() |> format_failure_reason()

  defp required_string(map, keys, error_reason) do
    case value_string(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error_reason}
    end
  end

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)

  defp blank_to_nil(value) when value in ["", nil], do: nil
  defp blank_to_nil(value), do: value

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(value), do: value
end
