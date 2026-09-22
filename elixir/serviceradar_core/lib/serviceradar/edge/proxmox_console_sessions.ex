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
  alias ServiceRadar.Credentials.CredentialUsePolicy
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Edge.RemoteConsoleTarget
  alias ServiceRadar.Edge.RemoteConsoleTargetResolver
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.ProxmoxSourceScopeResolver
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.ProxmoxHostAuthority
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @provider "proxmox"
  @console_plugin_id "proxmox-console"
  @console_plugin_entrypoint "run_console"
  @default_ticket_ttl_seconds 60
  @default_idle_timeout_seconds 900
  @default_absolute_timeout_seconds 3600
  @max_ticket_ttl_seconds 300
  @max_idle_timeout_seconds 3600
  @max_absolute_timeout_seconds 14_400
  @max_terminal_cols 500
  @max_terminal_rows 200
  @console_permissions ["devices.console.open", "devices.console.credentials.use"]
  @safe_failure_reasons ~w(console_broker_unavailable invalid_size invalid_data invalid_data_size agent_unavailable gateway_unavailable timeout)

  @type create_request :: %{
          optional(:cols) => integer(),
          optional(:rows) => integer()
        }

  @doc """
  Authorizes and creates a console session ticket for a canonical device UID.
  """
  @spec request_open(String.t(), create_request(), keyword()) ::
          {:ok, %{session: ProxmoxConsoleSession.t(), ticket: String.t()}} | {:error, term()}
  def request_open(device_uid, request \\ %{}, opts \\ []) when is_binary(device_uid) do
    system_opts = [actor: SystemActor.system(:proxmox_console_sessions)]

    with {:ok, opts} <- authorize_console_use(opts),
         ash_opts = ash_opts(opts),
         {:ok, requested_by} <- requesting_actor_id(opts),
         {:ok, %Device{} = device} <- Device.get_by_uid(device_uid, false, ash_opts),
         {:ok, target} <- resolve_target(device, request, system_opts),
         {:ok, rule} <- resolve_credential_rule(device, target, request, opts),
         {:ok, target} <- apply_rule_console_mode(target, rule),
         {:ok, agent_id} <- resolve_agent_id(target, rule),
         {:ok, assignment} <- resolve_active_assignment(rule, agent_id, opts),
         {:ok, partition_id} <- assignment_partition_id(assignment),
         :ok <- authenticate_edge_principal(partition_id, agent_id, opts),
         {:ok, ticket, ticket_hash} <- new_ticket(),
         attrs =
           session_attrs(
             device,
             target,
             rule,
             assignment,
             agent_id,
             ticket_hash,
             request,
             requested_by,
             opts
           ),
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

    with {:ok, opts} <- authorize_console_use(opts),
         {:ok, ticket_hash} <- hash_ticket(ticket),
         {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSession.get_by_ticket_hash(ticket_hash, system_opts),
         :ok <- ensure_session_match(session, Keyword.get(opts, :session_id)),
         :ok <- reauthorize_session(session, opts),
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

  defp resolve_target(device, _request, system_opts) do
    RemoteConsoleTargetResolver.resolve_proxmox(device, %{},
      ash_opts: system_opts,
      identity_scope: identity_scope_for_device(device, system_opts)
    )
  end

  defp resolve_credential_rule(_device, target, _request, opts) do
    system_actor = SystemActor.system(:proxmox_console_rule_resolver)
    controller_device = credential_target_device(target)

    resolve_first_matching_rule(controller_device, target, system_actor, opts)
  end

  defp resolve_first_matching_rule(controller_device, target, system_actor, opts) do
    controller_device
    |> rule_scopes()
    |> Enum.reduce_while({:error, :no_console_credential_rule}, fn {scope_type, scope_value},
                                                                   _acc ->
      case NetworkCredentialRule.list_enabled_for_scope(@provider, scope_type, scope_value,
             actor: system_actor
           ) do
        {:ok, rules} ->
          case Enum.find(rules, &matching_console_rule?(&1, target, controller_device, opts)) do
            nil -> {:cont, {:error, :no_console_credential_rule}}
            rule -> {:halt, {:ok, rule}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, :no_console_credential_rule} ->
        resolve_first_targeted_rule(target, controller_device, system_actor, opts)

      result ->
        result
    end
  end

  defp resolve_first_targeted_rule(target, device, system_actor, opts) do
    case enabled_provider_rules(system_actor) do
      {:ok, rules} ->
        case Enum.find(rules, &matching_console_rule?(&1, target, device, opts)) do
          nil -> {:error, :no_console_credential_rule}
          rule -> {:ok, rule}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enabled_provider_rules(system_actor) do
    NetworkCredentialRule
    |> Ash.Query.for_read(:read, %{}, actor: system_actor)
    |> Ash.Query.filter(provider == @provider and enabled == true)
    |> Ash.Query.sort(priority: :asc, inserted_at: :asc)
    |> Ash.read(actor: system_actor)
  end

  defp matching_console_rule?(rule, target, device, opts) do
    ensure_console_rule(rule, target) == :ok and
      ensure_rule_source_binding(rule, target) == :ok and
      ensure_rule_actor_allowed(rule, opts) == :ok and
      ensure_rule_targets_device(rule, device, opts) == :ok
  end

  defp ensure_console_rule(rule, target), do: ensure_explicit_console_rule(rule, target)

  defp ensure_explicit_console_rule(%{provider: @provider} = rule, target) do
    with true <- rule_has_purpose?(rule, :console_access),
         :ok <- ensure_console_transport_policy(rule, target) do
      :ok
    else
      false -> {:error, :not_console_credential_rule}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_explicit_console_rule(_rule, _target), do: {:error, :not_console_credential_rule}

  defp ensure_console_transport_policy(rule, target) do
    case value_string(rule, [:auth_method, "auth_method"]) do
      "proxmox_api_token" ->
        if value_string(rule, [:tls_policy, "tls_policy"]) == "verify",
          do: :ok,
          else: {:error, :proxmox_tls_verification_required}

      "ssh_private_key" ->
        cond do
          target.target_kind != :pve_host ->
            {:error, :unsupported_proxmox_ssh_console_target}

          value_string(rule, [:ssh_host_key_policy, "ssh_host_key_policy"]) not in [
            "known_hosts",
            "trust_on_first_use"
          ] ->
            {:error, :proxmox_ssh_host_key_verification_required}

          true ->
            :ok
        end

      _unsupported_auth_method ->
        {:error, :unsupported_proxmox_console_auth_method}
    end
  end

  # The browser never chooses the transport. It follows the exact current
  # credential rule selected by the server: API-token rules use the native PVE
  # terminal/VNC mode inferred from inventory, while SSH keys may open only the
  # owning PVE host itself. Guest consoles continue through the native PVE API.
  defp apply_rule_console_mode(%{target_kind: :pve_host} = target, rule) do
    case value_string(rule, [:auth_method, "auth_method"]) do
      "proxmox_api_token" -> {:ok, target}
      "ssh_private_key" -> {:ok, Map.put(target, :console_mode, :ssh)}
      _unsupported_auth_method -> {:error, :unsupported_proxmox_console_auth_method}
    end
  end

  defp apply_rule_console_mode(target, rule) do
    case value_string(rule, [:auth_method, "auth_method"]) do
      "proxmox_api_token" -> {:ok, target}
      "ssh_private_key" -> {:error, :unsupported_proxmox_ssh_console_target}
      _unsupported_auth_method -> {:error, :unsupported_proxmox_console_auth_method}
    end
  end

  defp rule_has_purpose?(rule, purpose) do
    rule
    |> rule_purposes()
    |> Enum.member?(Atom.to_string(purpose))
  end

  defp rule_purposes(rule) do
    metadata_purposes =
      rule
      |> ValueUtils.raw_value([:metadata, "metadata"])
      |> case do
        metadata when is_map(metadata) ->
          ValueUtils.list_value(metadata, [:purposes, "purposes"])

        _metadata ->
          []
      end
      |> nil_to_empty_list()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    if metadata_purposes == [] do
      [value_string(rule, [:purpose, "purpose"]) || "inventory_enrichment"]
    else
      metadata_purposes
    end
  end

  defp nil_to_empty_list(nil), do: []
  defp nil_to_empty_list(value), do: value

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

  defp ensure_rule_actor_allowed(rule, opts) do
    {actor, identity_claims} = actor_context(opts)
    CredentialUsePolicy.authorize_rule(rule, actor, identity_claims)
  end

  defp reauthorize_session(%ProxmoxConsoleSession{} = session, opts) do
    system_actor = SystemActor.system(:proxmox_console_attach_policy)
    system_opts = [actor: system_actor]

    with :ok <- ensure_requesting_actor(session, opts),
         {:ok, %Device{} = device} <- Device.get_by_uid(session.device_uid, false, system_opts),
         {:ok, target} <- resolve_target(device, %{}, system_opts),
         {:ok, %NetworkCredentialRule{enabled: true} = rule} <-
           NetworkCredentialRule.get_by_id(session.credential_rule_id, actor: system_actor),
         :ok <- ensure_console_rule(rule, target),
         :ok <- ensure_rule_source_binding(rule, target),
         :ok <- ensure_rule_actor_allowed(rule, opts),
         :ok <- ensure_rule_targets_device(rule, credential_target_device(target), opts),
         {:ok, target} <- apply_rule_console_mode(target, rule),
         :ok <- ensure_target_binding(session, device, target),
         {:ok, agent_id} <- resolve_agent_id(target, rule),
         :ok <- ensure_route_binding(session, target, agent_id),
         {:ok, assignment} <- resolve_active_assignment(rule, agent_id, opts),
         {:ok, partition_id} <- assignment_partition_id(assignment),
         :ok <- authenticate_edge_principal(partition_id, agent_id, opts),
         :ok <- ensure_rule_binding(session, rule, assignment) do
      :ok
    else
      {:ok, %NetworkCredentialRule{}} -> {:error, :console_credential_rule_disabled}
      {:ok, nil} -> {:error, :no_console_credential_rule}
      {:error, reason} -> {:error, reason}
      false -> {:error, :console_authorization_stale}
    end
  end

  defp ensure_requesting_actor(session, opts) do
    case audit_actor(opts) do
      %{id: actor_id} when not is_nil(actor_id) ->
        if to_string(actor_id) == to_string(session.requested_by),
          do: :ok,
          else: {:error, :console_actor_mismatch}

      _actor ->
        {:error, :console_actor_mismatch}
    end
  end

  defp ensure_target_binding(session, device, target) do
    stored = session_metadata_map(session, "target")
    current = target_metadata(device, target)

    if stored == current,
      do: :ok,
      else: {:error, :console_target_binding_changed}
  end

  defp ensure_route_binding(session, target, agent_id) do
    if session.agent_id == agent_id and session.gateway_id == target.controller.gateway_id,
      do: :ok,
      else: {:error, :console_route_binding_changed}
  end

  defp ensure_rule_binding(session, rule, assignment) do
    if session_metadata_map(session, "credential_rule") ==
         credential_rule_binding(rule, assignment),
       do: :ok,
       else: {:error, :console_credential_binding_changed}
  end

  defp ensure_rule_source_binding(rule, target) do
    rule_integration_id = value_string(rule, [:integration_id, "integration_id"])
    rule_controller_id = value_string(rule, [:controller_id, "controller_id"])

    if rule_integration_id == target.integration_id and
         rule_controller_id == target.controller_id,
       do: :ok,
       else: {:error, :console_credential_source_mismatch}
  end

  defp resolve_agent_id(target, rule) do
    case rule_scope_type(rule) do
      :agent -> {:ok, value_string(rule, [:scope_value, "scope_value"])}
      _ -> target |> credential_target_device() |> required_agent_id()
    end
  end

  defp resolve_active_assignment(rule, agent_id, opts) do
    result =
      case Keyword.get(opts, :assignment_resolver) do
        resolver when is_atom(resolver) and not is_nil(resolver) ->
          resolver.resolve(rule, agent_id, opts)

        resolver when is_function(resolver, 3) ->
          resolver.(rule, agent_id, opts)

        nil ->
          read_active_assignment(rule, agent_id)

        _resolver ->
          {:error, :console_assignment_unavailable}
      end

    with {:ok, assignment} <- result,
         {:ok, partition_id} <- assignment_partition_id(assignment),
         {:ok, _source_scope} <-
           validate_active_assignment(assignment, rule, agent_id, partition_id) do
      {:ok, assignment}
    else
      {:error, :ambiguous_console_assignment} = error -> error
      {:error, :console_assignment_unavailable} = error -> error
      {:error, _reason} -> {:error, :console_assignment_unavailable}
    end
  end

  defp validate_active_assignment(assignment, rule, agent_id, partition_id) do
    actor = SystemActor.system(:proxmox_console_assignment_validation)
    rule_id = value_string(rule, [:id, "id"])

    with :ok <- ensure_console_package(assignment),
         {:ok, _policy_binding} <- assignment_policy_binding(assignment) do
      ProxmoxSourceScopeResolver.resolve_assignment(assignment,
        actor: actor,
        agent_id: agent_id,
        partition_id: partition_id,
        assignment_id: value_string(assignment, [:id, "id"]),
        plugin_id: @console_plugin_id,
        rule_loader: fn expected_rule_id, _actor ->
          if expected_rule_id == rule_id,
            do: {:ok, rule},
            else: {:error, :credential_rule_id_mismatch}
        end
      )
    end
  end

  defp ensure_console_package(assignment) do
    package = ValueUtils.raw_value(assignment, [:plugin_package, "plugin_package"])
    assignment_package_id = value_string(assignment, [:plugin_package_id, "plugin_package_id"])

    cond do
      not is_map(package) ->
        {:error, :console_plugin_package_unavailable}

      value_string(package, [:id, "id"]) != assignment_package_id ->
        {:error, :console_plugin_package_mismatch}

      value_string(package, [:plugin_id, "plugin_id"]) != @console_plugin_id ->
        {:error, :console_plugin_package_mismatch}

      value_string(package, [:entrypoint, "entrypoint"]) != @console_plugin_entrypoint ->
        {:error, :console_plugin_package_mismatch}

      value_string(package, [:status, "status"]) != "approved" ->
        {:error, :console_plugin_package_not_approved}

      true ->
        :ok
    end
  end

  defp assignment_policy_version(assignment) do
    case assignment_policy_binding(assignment) do
      {:ok, %{policy_version: version}} -> {:ok, version}
      {:error, _reason} -> {:error, :console_assignment_version_missing}
    end
  end

  defp assignment_policy_fingerprint(assignment) do
    case assignment_policy_binding(assignment) do
      {:ok, %{fingerprint: fingerprint}} -> {:ok, fingerprint}
      {:error, _reason} -> {:error, :console_assignment_policy_binding_missing}
    end
  end

  defp assignment_policy_binding(assignment) do
    params = ValueUtils.map_value(assignment, [:params, "params"])
    assignment_id = value_string(assignment, [:id, "id"])

    ProxmoxHostAuthority.assignment_policy_binding(
      @console_plugin_id,
      @console_plugin_entrypoint,
      params,
      assignment_id
    )
  end

  defp read_active_assignment(rule, agent_id) do
    actor = SystemActor.system(:proxmox_console_assignment)
    policy_id = console_policy_id(rule)

    # This query only enumerates assignment candidates for the exact rule and
    # agent. It cannot authorize a route: exactly one server-bound partition is
    # required, and the subsequent control lookup uses that partition key.
    PluginAssignment
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      agent_uid == ^agent_id and enabled == true and plugin_id == @console_plugin_id and
        source == :policy and policy_id == ^policy_id
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, []} -> {:error, :console_assignment_unavailable}
      {:ok, [assignment]} -> Ash.load(assignment, :plugin_package, actor: actor)
      {:ok, [_first, _second | _rest]} -> {:error, :ambiguous_console_assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp console_policy_id(rule) do
    "network-credential-rule:#{value_string(rule, [:id, "id"])}:console_access"
  end

  defp session_attrs(
         device,
         target,
         rule,
         assignment,
         agent_id,
         ticket_hash,
         request,
         requested_by,
         opts
       ) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    idle_timeout =
      bounded_option(
        opts,
        :idle_timeout_seconds,
        @default_idle_timeout_seconds,
        @max_idle_timeout_seconds
      )

    absolute_timeout =
      bounded_option(
        opts,
        :absolute_timeout_seconds,
        @default_absolute_timeout_seconds,
        @max_absolute_timeout_seconds
      )

    ticket_ttl =
      bounded_option(
        opts,
        :ticket_ttl_seconds,
        @default_ticket_ttl_seconds,
        @max_ticket_ttl_seconds
      )

    %{
      ticket_hash: ticket_hash,
      ticket_expires_at: DateTime.add(now, ticket_ttl, :second),
      device_uid: device.uid,
      target_kind: target.target_kind,
      console_mode: target.console_mode,
      agent_id: agent_id,
      gateway_id: target.controller.gateway_id,
      credential_rule_id: value_string(rule, [:id, "id"]),
      requested_by: requested_by,
      idle_timeout_seconds: idle_timeout,
      absolute_timeout_seconds: absolute_timeout,
      metadata:
        session_metadata(
          device,
          target,
          rule,
          assignment,
          agent_id,
          request,
          requested_by,
          now,
          idle_timeout,
          absolute_timeout
        )
    }
  end

  defp session_metadata(
         device,
         target,
         rule,
         assignment,
         agent_id,
         request,
         requested_by,
         evaluated_at,
         idle_timeout,
         absolute_timeout
       ) do
    terminal =
      %{}
      |> put_bounded_int(
        "cols",
        Map.get(request, :cols) || Map.get(request, "cols"),
        @max_terminal_cols
      )
      |> put_bounded_int(
        "rows",
        Map.get(request, :rows) || Map.get(request, "rows"),
        @max_terminal_rows
      )

    target_metadata = target_metadata(device, target)

    remote_console_target =
      device
      |> RemoteConsoleTarget.proxmox(Map.put(target, :agent_id, agent_id))
      |> RemoteConsoleTarget.to_metadata()

    %{}
    |> maybe_put("terminal", terminal)
    |> maybe_put("plugin_assignment_id", value_string(assignment, [:id, "id"]))
    |> maybe_put(
      "plugin_assignment_version",
      assignment |> assignment_policy_version() |> elem(1)
    )
    |> maybe_put(
      "plugin_assignment_policy_fingerprint",
      assignment |> assignment_policy_fingerprint() |> elem(1)
    )
    |> maybe_put(
      "plugin_assignment_updated_at",
      timestamp_string(ValueUtils.raw_value(assignment, [:updated_at, "updated_at"]))
    )
    |> maybe_put("timeouts", %{
      "idle_seconds" => idle_timeout,
      "absolute_seconds" => absolute_timeout
    })
    |> maybe_put("target", target_metadata)
    |> maybe_put("credential_rule", credential_rule_binding(rule, assignment))
    |> maybe_put("authorization", %{
      "decision_id" => Ecto.UUID.generate(),
      "actor_id" => requested_by,
      "evaluated_at" => DateTime.to_iso8601(evaluated_at),
      "permissions" => @console_permissions
    })
    |> maybe_put("remote_console", remote_console_target)
  end

  defp target_metadata(device, target) do
    controller = target.controller

    %{}
    |> maybe_put("device_uid", value_string(device, [:uid, "uid"]))
    |> maybe_put("controller_device_uid", controller.device_uid)
    |> maybe_put("hostname", controller.hostname)
    |> maybe_put("ip", controller.ip)
    |> maybe_put("base_url", controller.base_url)
    |> maybe_put("controller_ref", controller.provider_ref)
    |> maybe_put("controller_integration_id", controller.integration_id)
    |> maybe_put("controller_id", target.controller_id)
    |> maybe_put("provider_instance_ref", target.provider_instance_ref)
    |> maybe_put("identity_version", target.identity_version)
    |> maybe_put("identity_state", format_atom(target.identity_state))
    |> maybe_put("native_cluster_id", target.native_cluster_id)
    |> maybe_put("object_kind", target.object_kind)
    |> maybe_put("native_object_id", target.native_object_id)
    |> maybe_put("inventory_row_id", target.inventory_row_id)
    |> maybe_put("owner_host_id", target.owner_host_id)
    |> maybe_put("controller_provider_instance_ref", controller.provider_instance_ref)
    |> maybe_put("controller_virtualization_host_id", controller.virtualization_host_id)
    |> maybe_put("controller_native_cluster_id", controller.native_cluster_id)
    |> maybe_put("controller_native_object_id", controller.native_object_id)
    |> maybe_put("integration_id", target.integration_id)
    |> maybe_put("cluster", target.cluster)
    |> maybe_put("node", target.node)
    |> maybe_put("vmid", target.vmid)
    |> put_positive_int("ssh_port", controller.ssh_port)
  end

  defp credential_rule_binding(rule, assignment) do
    %{
      "credential_rule_id" => value_string(rule, [:id, "id"]),
      "credential_rule_updated_at" => timestamp_string(Map.get(rule, :updated_at)),
      "purposes" => Enum.sort(rule_purposes(rule)),
      "scope_type" => rule |> rule_scope_type() |> format_atom(),
      "scope_value" => value_string(rule, [:scope_value, "scope_value"]),
      "assignment_id" => value_string(assignment, [:id, "id"]),
      "assignment_updated_at" =>
        timestamp_string(ValueUtils.raw_value(assignment, [:updated_at, "updated_at"])),
      "assignment_version" => assignment |> assignment_policy_version() |> elem(1),
      "assignment_policy_fingerprint" => assignment |> assignment_policy_fingerprint() |> elem(1),
      "assignment_policy_id" => value_string(assignment, [:policy_id, "policy_id"]),
      "assignment_agent_id" => value_string(assignment, [:agent_uid, "agent_uid"]),
      "assignment_partition_id" => value_string(assignment, [:partition_id, "partition_id"]),
      "assignment_plugin_id" => value_string(assignment, [:plugin_id, "plugin_id"]),
      "assignment_plugin_package_id" =>
        value_string(assignment, [:plugin_package_id, "plugin_package_id"]),
      "assignment_plugin_package_version" =>
        assignment
        |> ValueUtils.raw_value([:plugin_package, "plugin_package"])
        |> value_string([:version, "version"]),
      "assignment_source" => value_string(assignment, [:source, "source"]),
      "assignment_source_key" => value_string(assignment, [:source_key, "source_key"]),
      "assignment_enabled" => ValueUtils.raw_value(assignment, [:enabled, "enabled"]),
      "integration_id" => value_string(rule, [:integration_id, "integration_id"]),
      "controller_id" => value_string(rule, [:controller_id, "controller_id"])
    }
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
        controller_device_uid: session_target_metadata_value(session, "controller_device_uid"),
        controller_ref: session_target_metadata_value(session, "controller_ref"),
        controller_origin: session_target_metadata_value(session, "base_url"),
        cluster: session_target_metadata_value(session, "cluster"),
        node: session_target_metadata_value(session, "node"),
        vmid: session_target_metadata_value(session, "vmid"),
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

  defp session_target_metadata_value(%{metadata: %{"target" => metadata}}, key)
       when is_map(metadata),
       do: Map.get(metadata, key)

  defp session_target_metadata_value(_session, _key), do: nil

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

  defp authorize_console_use(opts) do
    subject = Keyword.get(opts, :scope) || Keyword.get(opts, :actor)
    authority_module = Keyword.get(opts, :current_authority_module, CurrentUserAuthority)

    case authority_module.authorize(subject, @console_permissions) do
      {:ok, %{user: current_user, permissions: current_permissions}} ->
        {:ok, refresh_authority_opts(opts, current_user, current_permissions)}

      _ ->
        {:error, :forbidden}
    end
  end

  defp refresh_authority_opts(opts, current_user, current_permissions) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} when is_map(scope) ->
        refreshed_scope =
          scope
          |> Map.put(:user, current_user)
          |> Map.put(:permissions, current_permissions)

        Keyword.put(opts, :scope, refreshed_scope)

      _ ->
        Keyword.put(opts, :actor, current_user)
    end
  end

  defp actor_context(opts) do
    case Keyword.get(opts, :scope) do
      %{user: user, identity_claims: claims} when is_map(user) and is_map(claims) ->
        {user, claims}

      %{user: user} when is_map(user) ->
        {user, %{}}

      _scope ->
        {Keyword.get(opts, :actor), %{}}
    end
  end

  defp requesting_actor_id(opts) do
    case audit_actor(opts) do
      %{id: id} when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, :console_actor_identity_required}
        end

      _ ->
        {:error, :console_actor_identity_required}
    end
  end

  defp identity_scope_for_device(device, system_opts) do
    actor = Keyword.get(system_opts, :actor, SystemActor.system(:proxmox_console_identity_scope))

    scopes =
      device
      |> rule_scopes()
      |> Enum.flat_map(fn {scope_type, scope_value} ->
        case NetworkCredentialRule.list_enabled_for_scope("proxmox", scope_type, scope_value,
               actor: actor
             ) do
          {:ok, rules} when is_list(rules) -> rules
          _other -> []
        end
      end)
      |> Enum.map(&rule_identity_scope/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case scopes do
      [scope] -> scope
      _other -> nil
    end
  end

  defp rule_identity_scope(rule) do
    integration_id = value_string(rule, [:integration_id, "integration_id"])
    controller_id = value_string(rule, [:controller_id, "controller_id"])

    if present_text?(integration_id) and present_text?(controller_id) do
      %{integration_id: integration_id, controller_id: controller_id}
    end
  end

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

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

  defp assignment_partition_id(assignment) do
    case value_string(assignment, [:partition_id, "partition_id"]) do
      partition_id when is_binary(partition_id) and partition_id != "" -> {:ok, partition_id}
      _partition_id -> {:error, :console_assignment_partition_binding_missing}
    end
  end

  defp authenticate_edge_principal(partition_id, agent_id, opts) do
    configured_resolver =
      Application.get_env(
        :serviceradar_core,
        :proxmox_console_edge_principal_resolver,
        fn expected_partition_id, expected_agent_id ->
          AgentCommandBus.resolve_control_session_evidence(
            expected_partition_id,
            expected_agent_id,
            nil
          )
        end
      )

    resolver =
      Keyword.get(opts, :edge_principal_resolver, configured_resolver)

    result =
      cond do
        is_function(resolver, 2) ->
          resolver.(partition_id, agent_id)

        is_atom(resolver) and function_exported?(resolver, :resolve, 2) ->
          resolver.resolve(partition_id, agent_id)

        true ->
          {:error, :console_edge_principal_unavailable}
      end

    case result do
      {:ok, evidence} when is_map(evidence) ->
        evidence_agent_id =
          value_string(evidence, [:agent_id, "agent_id"])

        evidence_partition_id =
          value_string(evidence, [:partition_id, "partition_id"])

        if evidence_agent_id == agent_id and evidence_partition_id == partition_id,
          do: :ok,
          else: {:error, :console_edge_principal_mismatch}

      _ ->
        {:error, :console_edge_principal_unavailable}
    end
  end

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

  defp bounded_option(opts, key, default, max) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= max -> value
      _value -> default
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

  defp put_bounded_int(map, key, value, max)
       when is_integer(value) and value > 0 and value <= max,
       do: Map.put(map, key, value)

  defp put_bounded_int(map, key, value, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 and int <= max -> Map.put(map, key, int)
      _parse -> map
    end
  end

  defp put_bounded_int(map, _key, _value, _max), do: map

  defp maybe_put(map, _key, value) when value in [nil, "", %{}], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_close_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)
    if reason == "", do: "operator_requested", else: reason
  end

  defp normalize_close_reason(_reason), do: "operator_requested"

  defp format_failure_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> format_failure_reason()

  defp format_failure_reason(reason) when is_binary(reason) do
    normalized = reason |> String.trim() |> String.downcase()

    if normalized in @safe_failure_reasons,
      do: CredentialRedactor.redact(normalized),
      else: "console_internal_error"
  end

  defp format_failure_reason(_reason), do: "console_internal_error"

  defp required_agent_id(device) do
    case device_agent_id(device) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_agent_scope}
    end
  end

  defp credential_target_device(%{controller: %{device: device}}) when is_map(device), do: device

  defp credential_target_device(_target), do: %{}

  defp session_metadata_map(%{metadata: metadata}, key) when is_map(metadata) do
    value =
      Map.get(metadata, key) ||
        Enum.find_value(metadata, fn
          {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
          _entry -> nil
        end)

    case value do
      value when is_map(value) -> stringify_keys(value)
      _value -> %{}
    end
  end

  defp session_metadata_map(_session, _key), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)
      value = if is_map(value), do: stringify_keys(value), else: value
      {key, value}
    end)
  end

  defp timestamp_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_string(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp_string(_value), do: nil

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)

  defp not_found_error?(%NotFound{}), do: true

  defp not_found_error?(%Invalid{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &not_found_error?/1)

  defp not_found_error?(_error), do: false

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(value), do: value
end
