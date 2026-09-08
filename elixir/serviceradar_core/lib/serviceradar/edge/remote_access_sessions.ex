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
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Edge.RemoteAccessApplicationTarget
  alias ServiceRadar.Edge.RemoteAccessDialTarget
  alias ServiceRadar.Edge.RemoteAccessRequests
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessTargetPolicy
  alias ServiceRadar.Edge.RemoteAccessTcpTarget
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Plugins.ValueUtils
  alias ServiceRadar.Repo

  @default_attach_ttl_seconds 60
  @default_idle_timeout_seconds 900
  @default_absolute_timeout_seconds 3600
  @supported_protocols [
    :ssh,
    :proxmox_console,
    :vsphere_console,
    :rdp,
    :app,
    :tcp,
    :database,
    :kubernetes,
    :desktop,
    :ot
  ]
  @supported_adapters @supported_protocols ++ [:application]
  @supported_target_kinds [
    :inventory_device,
    :provider_console,
    :freeform_target,
    :registered_application_target,
    :registered_tcp_target
  ]
  @supported_custody_modes [
    :ssh_certificate,
    :user_present,
    :centrally_brokered,
    :provider_ticket,
    :none
  ]
  @ssh_certificate_policy_metadata_keys ~w(
    accounts
    allowed_principals
    principal_mappings
    principals
    requested_principals
    ssh_accounts
    ssh_allowed_principals
    ssh_certificate_ttl_seconds
    ssh_principal_mappings
  )

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
          optional(:approval_required) => boolean() | String.t(),
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
         {:ok, request} <- resolve_registered_target_request(device_uid, request),
         {:ok, %Device{} = device} <- resolve_device(value(request, :device_uid) || device_uid),
         {:ok, attrs} <- session_attrs(device, request, opts),
         ticket = Map.fetch!(attrs, :__attach_ticket__),
         approval = Map.fetch!(attrs, :__approval__),
         session_attrs =
           attrs
           |> Map.delete(:__attach_ticket__)
           |> Map.delete(:__approval__),
         {:ok, session} <- create_session_and_maybe_bind(session_attrs, approval, opts) do
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
  Returns browser-safe SSH console options for a device.

  Account names come from the configured certificate policy. Opaque principals
  are never returned to the client.
  """
  @spec ssh_console_options(String.t() | map() | Device.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ssh_console_options(device_or_uid, opts \\ [])

  def ssh_console_options(device_uid, opts) when is_binary(device_uid) do
    case resolve_device(device_uid) do
      {:ok, %Device{} = device} ->
        ssh_console_options(device, opts)

      {:ok, nil} ->
        {:error, :device_not_found}

      {:error, error} = result ->
        if not_found_error?(error), do: {:error, :device_not_found}, else: result

      other ->
        other
    end
  end

  def ssh_console_options(%Device{} = device, _opts) do
    policy = configured_ssh_certificate_policy(device)

    accounts =
      policy
      |> policy_value("accounts")
      |> account_list()
      |> List.wrap()
      |> Enum.flat_map(&public_ssh_account/1)

    {:ok,
     %{
       "default_credential_mode" => "ssh_certificate",
       "accounts" => accounts,
       "ttl_seconds" => positive_int(policy_value(policy, "ttl_seconds")),
       "device_uid" => value_string(device, [:uid, "uid"])
     }}
  end

  def ssh_console_options(device, opts) when is_map(device) do
    case value_string(device, [:uid, "uid"]) do
      uid when is_binary(uid) and uid != "" ->
        ssh_console_options(uid, opts)

      _ ->
        # Allow tests/stubs to pass a map shaped like a device without a DB round-trip.
        policy = configured_ssh_certificate_policy(device)

        accounts =
          policy
          |> policy_value("accounts")
          |> account_list()
          |> List.wrap()
          |> Enum.flat_map(&public_ssh_account/1)

        {:ok,
         %{
           "default_credential_mode" => "ssh_certificate",
           "accounts" => accounts,
           "ttl_seconds" => positive_int(policy_value(policy, "ttl_seconds")),
           "device_uid" => nil
         }}
    end
  end

  def ssh_console_options(_device, _opts), do: {:error, :device_not_found}

  defp public_ssh_account(account) when is_map(account) do
    name =
      account
      |> normalize_policy_map()
      |> policy_value("name")
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    if name == "" do
      []
    else
      [%{"name" => name}]
    end
  end

  defp public_ssh_account(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: [], else: [%{"name" => trimmed}]
  end

  defp public_ssh_account(_account), do: []

  @doc """
  Consumes a single-use browser attach ticket and marks the session attached.
  """
  @spec attach_with_ticket(String.t(), keyword()) ::
          {:ok, RemoteAccessSession.t()} | {:error, term()}
  def attach_with_ticket(ticket, opts \\ []) when is_binary(ticket) do
    system_opts = [actor: SystemActor.system(:remote_access_ticket)]

    with {:ok, ticket_hash} <- hash_ticket(ticket),
         {:ok, expected_session_id} <-
           normalize_expected_session_id(Keyword.get(opts, :session_id)),
         {:ok, expected_owner_id} <- expected_scope_owner_id(opts),
         {:ok, attached} <-
           consume_attach_ticket(
             ticket_hash,
             expected_session_id,
             expected_owner_id,
             system_opts,
             opts
           ) do
      write_audit(:remote_access_session_attach, attached, opts,
        terminal_outcome: nil,
        close_reason: nil,
        failure_reason: nil
      )

      {:ok, attached}
    else
      {:error, error} ->
        if invalid_attach_ticket_error?(error) do
          write_attach_denial_audit(:invalid_or_expired_ticket, opts)
          {:error, :invalid_or_expired_ticket}
        else
          {:error, error}
        end

      error ->
        error
    end
  end

  defp consume_attach_ticket(
         ticket_hash,
         expected_session_id,
         expected_owner_id,
         system_opts,
         opts
       ) do
    case Repo.transaction(fn ->
           case lock_attach_session(
                  ticket_hash,
                  expected_session_id,
                  expected_owner_id,
                  system_opts
                ) do
             {:ok, session} ->
               case authorize_current_attach(session, opts) do
                 :ok ->
                   attach_opts = Keyword.put(system_opts, :return_notifications?, true)

                   case RemoteAccessSession.attach(session, %{}, attach_opts) do
                     {:ok, attached, notifications} -> {attached, notifications}
                     {:error, error} -> Repo.rollback(error)
                   end

                 {:error, error} ->
                   Repo.rollback(error)
               end

             {:error, error} ->
               Repo.rollback(error)
           end
         end) do
      {:ok, {%RemoteAccessSession{} = attached, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, attached}

      {:error, error} ->
        {:error, error}
    end
  end

  defp authorize_current_attach(session, opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} ->
        authority_module =
          Keyword.get(opts, :current_authority_module, CurrentUserAuthority)

        case authority_module.authorize(scope, attach_permission(session)) do
          {:ok, _authority} -> :ok
          _ -> {:error, :current_authority_denied}
        end

      :error ->
        authorize_trusted_internal_attach(opts)
    end
  end

  defp authorize_trusted_internal_attach(opts) do
    case {Keyword.get(opts, :trusted_internal_attach?, false), Keyword.get(opts, :actor)} do
      {true, %{role: :system}} -> :ok
      _ -> {:error, :current_authority_denied}
    end
  end

  defp attach_permission(%{protocol: protocol}) when protocol in [:rdp, "rdp"],
    do: "devices.remote_access.rdp.open"

  defp attach_permission(_session), do: "devices.remote_access.ssh.open"

  defp lock_attach_session(ticket_hash, expected_session_id, expected_owner_id, system_opts) do
    query =
      RemoteAccessSession
      |> Ash.Query.for_read(
        :by_attach_ticket_hash,
        %{attach_ticket_hash: ticket_hash},
        system_opts
      )
      |> Ash.Query.lock(:for_update)

    case Ash.read_one(query, system_opts) do
      {:ok, nil} ->
        {:error, :invalid_or_expired_ticket}

      {:ok, %RemoteAccessSession{} = session} ->
        with :ok <- ensure_session_match(session, expected_session_id),
             :ok <- ensure_session_owner(session, expected_owner_id) do
          {:ok, session}
        end

      {:error, error} ->
        if not_found_error?(error),
          do: {:error, :invalid_or_expired_ticket},
          else: {:error, error}
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
  Refreshes durable activity for an owner-bound active browser session.

  Callers must rate-limit this signal. It intentionally does not write an
  audit event or paper-trail version for each heartbeat.
  """
  @spec record_activity(String.t(), keyword()) ::
          {:ok, RemoteAccessSession.t()} | {:error, term()}
  def record_activity(session_id, opts \\ []) when is_binary(session_id) do
    system_opts = [actor: SystemActor.system(:remote_access_activity)]

    with {:ok, %RemoteAccessSession{} = session} <-
           RemoteAccessSession.get_by_id(session_id, system_opts),
         :ok <- ensure_scope_owner(session, opts),
         true <- session.status in [:attached, :opening, :active],
         {:ok, updated} <-
           RemoteAccessSession.record_activity(session, %{},
             actor: SystemActor.system(:remote_access_activity)
           ) do
      {:ok, updated}
    else
      {:ok, nil} ->
        {:error, :not_found}

      false ->
        {:error, :not_found}

      {:error, error} ->
        if(not_found_error?(error), do: {:error, :not_found}, else: {:error, error})

      error ->
        error
    end
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
         :ok <- ensure_scope_owner(session, opts),
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

  defp resolve_registered_target_request(target_id, request) do
    case normalize_target_kind(value(request, :target_kind) || :inventory_device) do
      {:ok, :registered_application_target} ->
        resolve_application_target_request(target_id, request)

      {:ok, :registered_tcp_target} ->
        resolve_tcp_target_request(target_id, request)

      {:ok, _target_kind} ->
        {:ok, request}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_application_target_request(target_id, request) do
    case RemoteAccessApplicationTarget.get_by_id(target_id,
           actor: SystemActor.system(:remote_access_application_target_resolver)
         ) do
      {:ok, %RemoteAccessApplicationTarget{enabled: true} = target} ->
        with {:ok, policy} <- RemoteAccessTargetPolicy.evaluate_application(target) do
          quota_policy = Map.fetch!(policy, "quota_policy")
          approval_policy = Map.fetch!(policy, "approval_policy")
          recording_policy = Map.fetch!(policy, "recording_policy")
          enhanced_policy = Map.fetch!(policy, "enhanced_recording_policy")

          {:ok,
           Map.merge(request, %{
             device_uid: target.device_uid,
             target_kind: :registered_application_target,
             target_host: target.upstream_host,
             target_port: target.upstream_port,
             protocol: :app,
             adapter: :application,
             agent_id: target.agent_id,
             gateway_id: target.gateway_id,
             credential_custody_mode: :none,
             credential_rule_id: nil,
             approval_required: approval_required_from_policy(approval_policy),
             idle_timeout_seconds:
               positive_policy_int(quota_policy, "idle_timeout_seconds") ||
                 @default_idle_timeout_seconds,
             absolute_timeout_seconds:
               positive_policy_int(quota_policy, "absolute_timeout_seconds") ||
                 @default_absolute_timeout_seconds,
             recording_policy: recording_policy,
             enhanced_recording_policy: enhanced_policy,
             metadata:
               target_metadata(request, %{
                 "target_id" => target.id,
                 "target_type" => "application",
                 "target_name" => target.name,
                 "upstream_scheme" => Atom.to_string(target.upstream_scheme),
                 "upstream_host_header" => target.upstream_host_header,
                 "upstream_sni" => target.upstream_sni,
                 "tls_policy" => Map.fetch!(policy, "tls_policy"),
                 "ca_bundle_ref" => target.ca_bundle_ref,
                 "allowed_methods" => Map.fetch!(policy, "allowed_methods"),
                 "allowed_path_prefixes" => Map.fetch!(policy, "allowed_path_prefixes"),
                 "redirect_policy" => Map.fetch!(policy, "redirect_policy"),
                 "header_policy" => Map.fetch!(policy, "header_policy"),
                 "cookie_policy" => Map.fetch!(policy, "cookie_policy"),
                 "quota_policy" => quota_policy,
                 "approval_policy" => approval_policy,
                 "recording_policy" => recording_policy,
                 "enhanced_recording_policy" => enhanced_policy,
                 "policy_snapshot" => policy,
                 "target_metadata" => target.metadata
               })
           })}
        end

      {:ok, %RemoteAccessApplicationTarget{enabled: false}} ->
        {:error, :remote_access_target_disabled}

      {:ok, nil} ->
        {:error, :missing_remote_access_target}

      {:error, %NotFound{}} ->
        {:error, :missing_remote_access_target}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_tcp_target_request(target_id, request) do
    case RemoteAccessTcpTarget.get_by_id(target_id,
           actor: SystemActor.system(:remote_access_tcp_target_resolver)
         ) do
      {:ok, %RemoteAccessTcpTarget{enabled: true} = target} ->
        with {:ok, policy} <- RemoteAccessTargetPolicy.evaluate_tcp(target) do
          approval_policy = Map.fetch!(policy, "approval_policy")
          recording_policy = Map.fetch!(policy, "recording_policy")
          enhanced_policy = Map.fetch!(policy, "enhanced_recording_policy")

          {:ok,
           Map.merge(request, %{
             device_uid: target.device_uid,
             target_kind: :registered_tcp_target,
             target_host: target.upstream_host,
             target_port: target.upstream_port,
             protocol: :tcp,
             adapter: :tcp,
             agent_id: target.agent_id,
             gateway_id: target.gateway_id,
             credential_custody_mode: :none,
             credential_rule_id: nil,
             approval_required: approval_required_from_policy(approval_policy),
             idle_timeout_seconds: target.idle_timeout_seconds,
             absolute_timeout_seconds: target.absolute_timeout_seconds,
             recording_policy: recording_policy,
             enhanced_recording_policy: enhanced_policy,
             metadata:
               target_metadata(request, %{
                 "target_id" => target.id,
                 "target_type" => "tcp",
                 "target_name" => target.name,
                 "protocol_name" => target.protocol_name,
                 "quota_policy" => Map.fetch!(policy, "quota_policy"),
                 "approval_policy" => approval_policy,
                 "recording_policy" => recording_policy,
                 "enhanced_recording_policy" => enhanced_policy,
                 "policy_snapshot" => policy,
                 "target_metadata" => target.metadata
               })
           })}
        end

      {:ok, %RemoteAccessTcpTarget{enabled: false}} ->
        {:error, :remote_access_target_disabled}

      {:ok, nil} ->
        {:error, :missing_remote_access_target}

      {:error, %NotFound{}} ->
        {:error, :missing_remote_access_target}

      {:error, error} ->
        {:error, error}
    end
  end

  defp approval_required_from_policy(policy) when is_map(policy) do
    truthy?(value(policy, :required)) or truthy?(value(policy, :approval_required))
  end

  defp approval_required_from_policy(_policy), do: false

  defp positive_policy_int(policy, key) when is_map(policy),
    do: policy |> value(key) |> positive_int()

  defp positive_policy_int(_policy, _key), do: nil

  defp target_metadata(request, target_metadata) do
    request_metadata = sanitized_map(value(request, :metadata))

    target_metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> then(&Map.merge(request_metadata, &1))
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
         target_port = int_request(request, :target_port, 22),
         gateway_id =
           value(request, :gateway_id) || value_string(device, [:gateway_id, "gateway_id"]),
         credential_rule_id = blank_to_nil(value(request, :credential_rule_id)),
         :ok <-
           ensure_central_credential_rule(
             custody_mode,
             credential_rule_id,
             protocol,
             agent_id,
             request,
             device
           ),
         scoped_request =
           Map.merge(request, %{
             device_uid: device.uid,
             target_kind: target_kind,
             target_host: target_host,
             target_port: target_port,
             protocol: protocol,
             adapter: adapter,
             agent_id: agent_id,
             gateway_id: gateway_id,
             credential_custody_mode: custody_mode,
             credential_rule_id: credential_rule_id
           }),
         {:ok, approval} <- authorize_approval(scoped_request, protocol, custody_mode, opts),
         metadata = session_metadata(device, request, protocol, custody_mode),
         :ok <- ensure_ssh_certificate_principal_policy(protocol, custody_mode, metadata),
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
            target_port: target_port,
            protocol: protocol,
            adapter: adapter,
            agent_id: agent_id,
            gateway_id: gateway_id,
            credential_custody_mode: custody_mode,
            credential_rule_id: credential_rule_id,
            requested_by: requested_by(opts),
            approval_id: approval.approval_id,
            rbac_decision: approval.rbac_decision,
            idle_timeout_seconds:
              int_request(request, :idle_timeout_seconds, @default_idle_timeout_seconds),
            absolute_timeout_seconds:
              int_request(request, :absolute_timeout_seconds, @default_absolute_timeout_seconds),
            recording_policy: sanitized_map(value(request, :recording_policy)),
            enhanced_recording_policy: sanitized_map(value(request, :enhanced_recording_policy)),
            metadata: metadata,
            __approval__: approval
          },
          :__attach_ticket__,
          ticket
        )

      {:ok, attrs}
    end
  end

  defp ensure_central_credential_rule(
         :centrally_brokered,
         nil,
         _protocol,
         _agent_id,
         _request,
         _device
       ),
       do: {:error, :credential_rule_required}

  defp ensure_central_credential_rule(
         :centrally_brokered,
         credential_rule_id,
         protocol,
         agent_id,
         request,
         device
       ) do
    with {:ok, %NetworkCredentialRule{} = rule} <-
           NetworkCredentialRule.get_by_id(credential_rule_id,
             actor: SystemActor.system(:remote_access_credential_rule)
           ),
         :ok <- ensure_rule_enabled(rule),
         :ok <- ensure_rule_protocol(rule, protocol),
         :ok <- ensure_rule_purpose(rule),
         :ok <- ensure_rule_scope(rule, agent_id, request, device) do
      :ok
    else
      {:ok, nil} -> {:error, :credential_rule_not_found}
      {:error, %NotFound{}} -> {:error, :credential_rule_not_found}
      {:error, error} -> {:error, error}
      error -> error
    end
  end

  defp ensure_central_credential_rule(
         _custody_mode,
         _credential_rule_id,
         _protocol,
         _agent_id,
         _request,
         _device
       ),
       do: :ok

  defp ensure_rule_enabled(%NetworkCredentialRule{enabled: true}), do: :ok
  defp ensure_rule_enabled(_rule), do: {:error, :credential_rule_disabled}

  defp ensure_rule_protocol(%NetworkCredentialRule{provider: provider}, protocol) do
    if provider == Atom.to_string(protocol),
      do: :ok,
      else: {:error, :credential_rule_protocol_mismatch}
  end

  defp ensure_rule_purpose(%NetworkCredentialRule{purpose: purpose})
       when purpose in ["console_access", "generic"],
       do: :ok

  defp ensure_rule_purpose(_rule), do: {:error, :credential_rule_purpose_mismatch}

  defp ensure_rule_scope(
         %NetworkCredentialRule{scope_type: :agent, scope_value: scope_value},
         agent_id,
         _request,
         _device
       ) do
    if scope_value == agent_id,
      do: :ok,
      else: {:error, :credential_rule_scope_mismatch}
  end

  defp ensure_rule_scope(
         %NetworkCredentialRule{scope_type: :gateway, scope_value: scope_value},
         _agent_id,
         request,
         device
       ) do
    gateway_id = value(request, :gateway_id) || value_string(device, [:gateway_id, "gateway_id"])

    if scope_value == gateway_id,
      do: :ok,
      else: {:error, :credential_rule_scope_mismatch}
  end

  defp ensure_rule_scope(_rule, _agent_id, _request, _device),
    do: {:error, :credential_rule_scope_mismatch}

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

  defp normalize_custody_mode(value, protocol)
       when is_atom(value) and value in @supported_custody_modes do
    if value in allowed_custody_modes(protocol) do
      {:ok, value}
    else
      {:error, :unsupported_credential_custody_mode}
    end
  end

  defp normalize_custody_mode(value, protocol) when is_binary(value) do
    case to_known_atom(value, @supported_custody_modes) do
      nil -> {:error, :unsupported_credential_custody_mode}
      mode -> normalize_custody_mode(mode, protocol)
    end
  end

  defp normalize_custody_mode(_value, _protocol),
    do: {:error, :unsupported_credential_custody_mode}

  defp allowed_custody_modes(:ssh), do: [:ssh_certificate, :user_present, :centrally_brokered]
  defp allowed_custody_modes(:proxmox_console), do: [:provider_ticket]
  defp allowed_custody_modes(:rdp), do: [:user_present, :centrally_brokered, :none]
  defp allowed_custody_modes(:desktop), do: [:user_present, :centrally_brokered, :none]
  defp allowed_custody_modes(_protocol), do: [:none, :centrally_brokered]

  defp to_known_atom(value, allowed) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp resolve_agent_id(device, request) do
    case blank_to_nil(
           value(request, :agent_id) || value_string(device, [:agent_id, "agent_id"]) ||
             device_metadata_agent_id(device)
         ) do
      nil -> {:error, :missing_agent_scope}
      agent_id -> {:ok, agent_id}
    end
  end

  # Devices inventoried by sync (SNMP/mapper) carry no owning agent_id
  # column; route via the sync service that discovered them — the same
  # scope the Proxmox console path uses. Request-supplied agent ids are
  # rejected upstream, so this only selects the default route.
  defp device_metadata_agent_id(%{metadata: metadata}) when is_map(metadata) do
    value_string(metadata, [
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

  defp device_metadata_agent_id(_device), do: nil

  defp resolve_target_host(device, request) do
    RemoteAccessDialTarget.resolve(device, blank_to_nil(value(request, :target_host)))
  end

  defp authorize_approval(request, protocol, custody_mode, opts) do
    approval_id = blank_to_nil(value(request, :approval_id))
    required? = approval_required?(request, protocol, custody_mode)

    if required? and is_nil(approval_id) do
      {:error, :approval_required}
    else
      context = %{
        approval_id: approval_id,
        approval_required?: required?,
        device_uid: value(request, :device_uid),
        target_host: value(request, :target_host),
        target_port: value(request, :target_port),
        agent_id: value(request, :agent_id),
        gateway_id: value(request, :gateway_id),
        protocol: protocol,
        adapter: value(request, :adapter) || protocol,
        credential_custody_mode: custody_mode,
        target_kind: value(request, :target_kind),
        credential_rule_id: blank_to_nil(value(request, :credential_rule_id)),
        requested_by: requested_by(opts),
        metadata: request |> value(:metadata) |> sanitized_map()
      }

      case run_approval_checker(context, opts) do
        :ok ->
          {:ok, %{approval_id: approval_id, rbac_decision: :allowed, access_request_id: nil}}

        {:ok, result} when is_map(result) ->
          {:ok,
           %{
             approval_id: approval_id,
             rbac_decision: :allowed,
             access_request_id: Map.get(result, :access_request_id)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp approval_required?(_request, _protocol, :centrally_brokered), do: true

  defp approval_required?(request, _protocol, _custody_mode) do
    truthy?(value(request, :approval_required)) or
      request
      |> value(:recording_policy)
      |> policy_requires_approval?() or
      request
      |> value(:enhanced_recording_policy)
      |> policy_requires_approval?()
  end

  defp policy_requires_approval?(policy) when is_map(policy),
    do: truthy?(value(policy, :approval_required))

  defp policy_requires_approval?(_policy), do: false

  defp truthy?(value) when value in [true, "true", "required", "yes", "1", 1], do: true
  defp truthy?(_value), do: false

  defp run_approval_checker(context, opts) do
    checker =
      Keyword.get(opts, :approval_checker) ||
        Application.get_env(:serviceradar_core, :remote_access_approval_checker) ||
        RemoteAccessRequests

    cond do
      not context.approval_required? and is_nil(context.approval_id) ->
        :ok

      Code.ensure_loaded?(checker) and
          function_exported?(checker, :authorize_remote_access_approval, 2) ->
        checker.authorize_remote_access_approval(context, opts)

      true ->
        {:error, :approval_denied}
    end
  end

  defp session_metadata(device, request, protocol, custody_mode) do
    terminal =
      %{}
      |> put_positive_int("cols", value(request, :cols))
      |> put_positive_int("rows", value(request, :rows))

    request_metadata =
      request
      |> value(:metadata)
      |> sanitized_map()
      |> drop_client_ssh_certificate_policy()

    target_metadata =
      %{}
      |> maybe_put("device_uid", value_string(device, [:uid, "uid"]))
      |> maybe_put("hostname", value_string(device, [:hostname, "hostname", :name, "name"]))
      |> maybe_put("ip", value_string(device, [:ip, "ip"]))

    %{}
    |> maybe_put("terminal", terminal)
    |> maybe_put("target", target_metadata)
    |> Map.merge(request_metadata)
    |> Map.merge(ssh_certificate_policy_metadata(device, protocol, custody_mode))
    |> CredentialRedactor.redact()
  end

  defp ensure_ssh_certificate_principal_policy(:ssh, :ssh_certificate, metadata) do
    accounts =
      metadata
      |> policy_value("ssh_accounts")
      |> account_list()

    if accounts do
      :ok
    else
      {:error, :ssh_principal_policy_required}
    end
  end

  defp ensure_ssh_certificate_principal_policy(_protocol, _custody_mode, _metadata), do: :ok

  defp ssh_certificate_policy_metadata(device, :ssh, :ssh_certificate) do
    case configured_ssh_certificate_policy(device) do
      policy when map_size(policy) == 0 ->
        %{}

      policy ->
        %{}
        |> maybe_put(
          "ssh_accounts",
          account_list(policy_value(policy, "accounts"))
        )
        |> maybe_put(
          "ssh_principal_mappings",
          mapping_list(policy_value(policy, "principal_mappings"))
        )
        |> maybe_put(
          "ssh_certificate_ttl_seconds",
          positive_int(policy_value(policy, "ttl_seconds"))
        )
    end
  end

  defp ssh_certificate_policy_metadata(_device, _protocol, _custody_mode), do: %{}

  defp configured_ssh_certificate_policy(device) do
    config =
      :serviceradar_core
      |> Application.get_env(:remote_access_ssh_certificate_policy, %{})
      |> normalize_policy_map()

    target_policy =
      config
      |> policy_value("targets")
      |> target_policy(device)
      |> normalize_policy_map()

    config
    |> Map.delete("targets")
    |> Map.merge(target_policy)
  end

  defp target_policy(targets, device) when is_map(targets) do
    uid = value_string(device, [:uid, "uid"])
    hostname = value_string(device, [:hostname, "hostname", :name, "name"])
    ip = value_string(device, [:ip, "ip"])

    Enum.find_value([uid, hostname, ip], %{}, fn key ->
      if key, do: policy_value(targets, key)
    end)
  end

  defp target_policy(_targets, _device), do: %{}

  defp normalize_policy_map(policy) when is_list(policy),
    do: policy |> Map.new() |> normalize_policy_map()

  defp normalize_policy_map(policy) when is_map(policy) do
    Map.new(policy, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_policy_map(_policy), do: %{}

  defp policy_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, safe_existing_atom(key))

  defp policy_value(_map, _key), do: nil

  defp account_list(values) when is_list(values) do
    values
    |> Enum.map(fn
      account when is_map(account) -> normalize_policy_map(account)
      account -> account
    end)
    |> empty_to_nil()
  end

  defp account_list(_values), do: nil

  defp mapping_list(values) when is_list(values) do
    values
    |> Enum.map(fn
      mapping when is_map(mapping) -> normalize_policy_map(mapping)
      mapping -> mapping
    end)
    |> empty_to_nil()
  end

  defp mapping_list(_values), do: nil

  defp drop_client_ssh_certificate_policy(metadata) when is_map(metadata) do
    Map.reject(metadata, fn {key, _value} ->
      key
      |> to_string()
      |> String.downcase()
      |> Kernel.in(@ssh_certificate_policy_metadata_keys)
    end)
  end

  defp drop_client_ssh_certificate_policy(_metadata), do: %{}

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(value), do: value

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

  defp normalize_expected_session_id(nil), do: {:ok, nil}

  defp normalize_expected_session_id(expected_id) do
    case Ecto.UUID.cast(to_string(expected_id)) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_or_expired_ticket}
    end
  end

  defp ensure_session_match(_session, nil), do: :ok

  defp ensure_session_match(%{id: id}, expected_id) do
    if to_string(id) == to_string(expected_id),
      do: :ok,
      else: {:error, :invalid_or_expired_ticket}
  end

  defp ensure_session_owner(_session, nil), do: :ok

  defp ensure_session_owner(%{requested_by: requested_by}, expected_owner_id) do
    if normalize_owner_id(requested_by) == expected_owner_id,
      do: :ok,
      else: {:error, :invalid_or_expired_ticket}
  end

  defp ensure_scope_owner(session, opts) do
    with {:ok, expected_owner_id} <- expected_scope_owner_id(opts) do
      case ensure_session_owner(session, expected_owner_id) do
        :ok -> :ok
        {:error, :invalid_or_expired_ticket} -> {:error, :not_found}
      end
    end
  end

  defp expected_scope_owner_id(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, %{user: %{id: id}}} ->
        case normalize_owner_id(id) do
          nil -> {:error, :invalid_or_expired_ticket}
          owner_id -> {:ok, owner_id}
        end

      {:ok, _scope} ->
        {:error, :invalid_or_expired_ticket}

      :error ->
        {:ok, nil}
    end
  end

  defp normalize_owner_id(nil), do: nil
  defp normalize_owner_id(id) when is_binary(id), do: id
  defp normalize_owner_id(id), do: to_string(id)

  defp invalid_attach_ticket_error?(:invalid_ticket), do: true
  defp invalid_attach_ticket_error?(:invalid_or_expired_ticket), do: true

  defp invalid_attach_ticket_error?(error) do
    not_found_error?(error)
  end

  defp create_session_and_maybe_bind(session_attrs, approval, opts) do
    create_opts =
      opts
      |> ash_opts()
      |> Keyword.put(:return_notifications?, true)

    fn ->
      with {:ok, %RemoteAccessSession{} = session, session_notifications} <-
             RemoteAccessSession.create_session(session_attrs, create_opts),
           {:ok, _bound_request, approval_side_effects} <-
             bind_access_request_with_side_effects(approval, session, opts) do
        {session, session_notifications, approval_side_effects}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, {%RemoteAccessSession{} = session, session_notifications, approval_side_effects}} ->
        Ash.Notifier.notify(session_notifications)
        approval_side_effects.()
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bind_access_request_with_side_effects(%{access_request_id: nil}, _session, _opts) do
    {:ok, nil, fn -> :ok end}
  end

  defp bind_access_request_with_side_effects(
         %{access_request_id: access_request_id},
         session,
         opts
       )
       when is_binary(access_request_id) do
    RemoteAccessRequests.bind_session_with_side_effects(access_request_id, session.id,
      audit_writer: Keyword.get(opts, :audit_writer, AuditWriter),
      actor: audit_actor(opts)
    )
  end

  defp bind_access_request_with_side_effects(_approval, _session, _opts) do
    {:ok, nil, fn -> :ok end}
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
          rbac_decision: denial_decision(error),
          failure_reason: format_failure_reason(error)
        }),
      severity: :high,
      message: "Remote access session denied"
    )
  end

  defp write_attach_denial_audit(reason, opts) do
    session_id = Keyword.get(opts, :session_id)
    resource_id = if is_nil(session_id), do: "unknown", else: to_string(session_id)
    audit_writer = Keyword.get(opts, :audit_writer, AuditWriter)

    audit_writer.write_async(
      action: :remote_access_session_attach_denied,
      resource_type: "remote_access_session",
      resource_id: resource_id,
      resource_name: resource_id,
      actor: audit_actor(opts),
      details:
        CredentialRedactor.redact(%{
          session_id: session_id,
          failure_reason: format_atom(reason)
        }),
      severity: :high,
      message: "Remote access session attach denied"
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
  defp audit_severity(:remote_access_session_attach_denied), do: :high
  defp audit_severity(_action), do: :medium

  defp denial_decision(:approval_required), do: "approval_required"
  defp denial_decision(:approval_pending), do: "approval_pending"
  defp denial_decision(:approval_not_found), do: "approval_not_found"
  defp denial_decision(:approval_expired), do: "approval_expired"
  defp denial_decision(:approval_consumed), do: "approval_consumed"
  defp denial_decision(:approval_scope_mismatch), do: "approval_scope_mismatch"
  defp denial_decision(_error), do: "denied"

  defp action_suffix(:remote_access_session_create), do: "created"
  defp action_suffix(:remote_access_session_attach), do: "attached"
  defp action_suffix(:remote_access_session_attach_denied), do: "attach denied"
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

  defp value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || maybe_existing_atom_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp maybe_existing_atom_value(map, key) do
    case safe_existing_atom(key) do
      nil -> nil
      atom -> Map.get(map, atom)
    end
  end

  defp value_string(source, keys) do
    source
    |> ValueUtils.string_value(keys)
    |> blank_to_nil()
  rescue
    _ -> nil
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
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
