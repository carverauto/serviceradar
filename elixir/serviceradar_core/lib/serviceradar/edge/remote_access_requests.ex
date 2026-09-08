defmodule ServiceRadar.Edge.RemoteAccessRequests do
  @moduledoc """
  Remote-access access-request and approval lifecycle.

  This module is the built-in approval checker used by
  `ServiceRadar.Edge.RemoteAccessSessions`. It verifies an approved request
  against the exact session scope and binds that request to one session.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.RemoteAccessRequest
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Repo

  @default_ttl_seconds 3600
  @default_review_permission "devices.remote_access.requests.review"
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
  @supported_target_kinds [:inventory_device, :provider_console, :freeform_target]
  @supported_custody_modes [
    :ssh_certificate,
    :user_present,
    :centrally_brokered,
    :provider_ticket,
    :none
  ]
  @approval_metadata_scope_keys [
    "desktop_target_id",
    "route_policy",
    "redirection_policy",
    "recording_policy",
    "screen_policy",
    "tls_policy",
    "target"
  ]

  @type request_attrs :: %{
          optional(:requested_by) => String.t(),
          optional(:device_uid) => String.t(),
          optional(:target_kind) => atom() | String.t(),
          optional(:target_host) => String.t(),
          optional(:target_port) => integer() | String.t(),
          optional(:protocol) => atom() | String.t(),
          optional(:adapter) => atom() | String.t(),
          optional(:agent_id) => String.t(),
          optional(:gateway_id) => String.t(),
          optional(:credential_custody_mode) => atom() | String.t(),
          optional(:credential_rule_id) => String.t(),
          optional(:reason) => String.t(),
          optional(:ttl_seconds) => integer() | String.t(),
          optional(:expires_at) => DateTime.t() | String.t(),
          optional(:reviewer_policy) => map(),
          optional(:metadata) => map()
        }

  @spec create(request_attrs(), keyword()) :: {:ok, RemoteAccessRequest.t()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, normalized} <- normalize_create_attrs(attrs, opts),
         {:ok, request} <- RemoteAccessRequest.create_request(normalized, ash_opts(opts)) do
      write_audit(:remote_access_request_created, request, opts)
      {:ok, request}
    end
  end

  @spec get(String.t(), keyword()) ::
          {:ok, RemoteAccessRequest.t()} | {:error, :not_found | term()}
  def get(id, opts \\ []) when is_binary(id) do
    case RemoteAccessRequest.get_by_id(id, ash_opts(opts)) do
      {:ok, %RemoteAccessRequest{} = request} -> {:ok, request}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> if not_found?(reason), do: {:error, :not_found}, else: {:error, reason}
    end
  end

  @spec approve(String.t() | RemoteAccessRequest.t(), keyword()) ::
          {:ok, RemoteAccessRequest.t()} | {:error, term()}
  def approve(request_or_id, opts \\ []) do
    with {:ok, %RemoteAccessRequest{} = request} <- resolve(request_or_id, opts),
         :ok <- ensure_pending(request),
         :ok <- ensure_unexpired(request),
         :ok <- ensure_reviewer_policy(request, opts),
         {:ok, approved} <-
           RemoteAccessRequest.approve(
             request,
             %{
               approved_by: actor_uuid(opts),
               approved_at: RemoteAccessRequest.utc_now(),
               review_note: blank_to_nil(Keyword.get(opts, :note))
             },
             ash_opts(opts)
           ) do
      write_audit(:remote_access_request_approved, approved, opts)
      {:ok, approved}
    end
  end

  @spec deny(String.t() | RemoteAccessRequest.t(), keyword()) ::
          {:ok, RemoteAccessRequest.t()} | {:error, term()}
  def deny(request_or_id, opts \\ []) do
    with {:ok, %RemoteAccessRequest{} = request} <- resolve(request_or_id, opts),
         :ok <- ensure_pending(request),
         :ok <- ensure_reviewer_policy(request, opts),
         {:ok, denied} <-
           RemoteAccessRequest.deny(
             request,
             %{
               denied_by: actor_uuid(opts),
               denied_at: RemoteAccessRequest.utc_now(),
               denial_reason: blank_to_nil(Keyword.get(opts, :reason)) || "denied",
               review_note: blank_to_nil(Keyword.get(opts, :note))
             },
             ash_opts(opts)
           ) do
      write_audit(:remote_access_request_denied, denied, opts)
      {:ok, denied}
    end
  end

  @spec expire(String.t() | RemoteAccessRequest.t(), keyword()) ::
          {:ok, RemoteAccessRequest.t()} | {:error, term()}
  def expire(request_or_id, opts \\ []) do
    with {:ok, %RemoteAccessRequest{} = request} <- resolve(request_or_id, opts),
         {:ok, expired} <-
           RemoteAccessRequest.expire(
             request,
             %{expired_at: RemoteAccessRequest.utc_now()},
             actor: SystemActor.system(:remote_access_request_expire)
           ) do
      write_audit(:remote_access_request_expired, expired, opts)
      {:ok, expired}
    end
  end

  @spec bind_session(String.t(), String.t(), keyword()) ::
          {:ok, RemoteAccessRequest.t()} | {:error, term()}
  def bind_session(request_id, session_id, opts \\ [])
      when is_binary(request_id) and is_binary(session_id) do
    with {:ok, %RemoteAccessRequest{} = bound, side_effects} <-
           bind_session_with_side_effects(request_id, session_id, opts) do
      side_effects.()
      {:ok, bound}
    end
  end

  @doc false
  @spec bind_session_with_side_effects(String.t(), String.t(), keyword()) ::
          {:ok, RemoteAccessRequest.t(), (-> :ok)} | {:error, term()}
  def bind_session_with_side_effects(request_id, session_id, opts \\ [])
      when is_binary(request_id) and is_binary(session_id) do
    fn -> bind_session_locked(request_id, session_id) end
    |> Repo.transaction()
    |> case do
      {:ok, {%RemoteAccessRequest{} = bound, notifications}} ->
        {:ok, bound,
         fn ->
           Ash.Notifier.notify(notifications)
           write_audit(:remote_access_request_consumed, bound, opts)
           :ok
         end}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Approval-checker callback used by `RemoteAccessSessions`.
  """
  @spec authorize_remote_access_approval(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def authorize_remote_access_approval(context, _opts \\ []) when is_map(context) do
    with {:ok, approval_id} <- required_string(value(context, :approval_id), :approval_id),
         {:ok, %RemoteAccessRequest{} = request} <-
           get(approval_id, actor: SystemActor.system(:remote_access_request_authorize)),
         :ok <- ensure_approved(request),
         :ok <- ensure_unexpired(request),
         :ok <- ensure_unbound(request),
         :ok <- ensure_matches_context(request, context) do
      {:ok, %{access_request_id: request.id}}
    else
      {:error, :not_found} -> {:error, :approval_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revalidates a file-transfer approval before terminal agent outcome frames are accepted.
  """
  @spec authorize_file_transfer_completion(map(), keyword()) :: :ok | {:error, term()}
  def authorize_file_transfer_completion(context, _opts \\ []) when is_map(context) do
    with {:ok, approval_id} <- required_string(value(context, :approval_id), :approval_id),
         {:ok, session_id} <- required_string(value(context, :session_id), :session_id),
         {:ok, %RemoteAccessRequest{} = request} <-
           get(approval_id, actor: SystemActor.system(:remote_access_file_transfer_authorize)),
         :ok <- ensure_completion_approved(request),
         :ok <- ensure_unexpired(request),
         :ok <- ensure_completion_bound_to_session(request, session_id) do
      :ok
    else
      {:error, :not_found} -> {:error, :approval_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_create_attrs(attrs, opts) do
    with {:ok, requested_by} <- requested_by(attrs, opts),
         {:ok, device_uid} <- required_string(value(attrs, :device_uid), :device_uid),
         {:ok, target_host} <- required_string(value(attrs, :target_host), :target_host),
         {:ok, target_port} <- target_port(value(attrs, :target_port)),
         {:ok, protocol} <-
           known_atom(
             value(attrs, :protocol) || :ssh,
             @supported_protocols,
             :unsupported_remote_access_protocol
           ),
         {:ok, adapter} <-
           known_atom(
             value(attrs, :adapter) || protocol,
             @supported_protocols,
             :unsupported_remote_access_adapter
           ),
         {:ok, target_kind} <-
           known_atom(
             value(attrs, :target_kind) || :inventory_device,
             @supported_target_kinds,
             :unsupported_remote_access_target
           ),
         {:ok, agent_id} <- required_string(value(attrs, :agent_id), :agent_id),
         {:ok, custody_mode} <-
           known_atom(
             value(attrs, :credential_custody_mode) || :user_present,
             @supported_custody_modes,
             :unsupported_credential_custody_mode
           ),
         {:ok, expires_at} <- expires_at(attrs, opts) do
      {:ok,
       %{
         requested_by: requested_by,
         device_uid: device_uid,
         target_kind: target_kind,
         target_host: target_host,
         target_port: target_port,
         protocol: protocol,
         adapter: adapter,
         agent_id: agent_id,
         gateway_id: blank_to_nil(value(attrs, :gateway_id)),
         credential_custody_mode: custody_mode,
         credential_rule_id: blank_to_nil(value(attrs, :credential_rule_id)),
         reason: blank_to_nil(value(attrs, :reason)),
         expires_at: expires_at,
         reviewer_policy: reviewer_policy(value(attrs, :reviewer_policy)),
         metadata: attrs |> value(:metadata) |> sanitized_map()
       }}
    end
  end

  defp requested_by(attrs, opts) do
    case blank_to_nil(value(attrs, :requested_by)) || actor_uuid(opts) do
      nil -> {:error, :requested_by_required}
      id -> {:ok, id}
    end
  end

  defp expires_at(attrs, opts) do
    case value(attrs, :expires_at) do
      %DateTime{} = dt ->
        {:ok, DateTime.truncate(dt, :second)}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
          _error -> {:error, :invalid_expires_at}
        end

      _other ->
        ttl =
          positive_int(value(attrs, :ttl_seconds)) ||
            Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

        {:ok, DateTime.add(RemoteAccessRequest.utc_now(), ttl, :second)}
    end
  end

  defp reviewer_policy(policy) when is_map(policy) do
    policy
    |> stringify_map()
    |> Map.put_new("required_permission", @default_review_permission)
    |> Map.put_new("allow_self_approval", false)
  end

  defp reviewer_policy(_policy),
    do: %{"required_permission" => @default_review_permission, "allow_self_approval" => false}

  defp ensure_pending(%RemoteAccessRequest{status: :pending}), do: :ok
  defp ensure_pending(_request), do: {:error, :access_request_not_pending}

  defp ensure_approved(%RemoteAccessRequest{status: :approved}), do: :ok
  defp ensure_approved(%RemoteAccessRequest{status: :pending}), do: {:error, :approval_pending}
  defp ensure_approved(%RemoteAccessRequest{status: :denied}), do: {:error, :approval_denied}
  defp ensure_approved(%RemoteAccessRequest{status: :expired}), do: {:error, :approval_expired}
  defp ensure_approved(%RemoteAccessRequest{status: :consumed}), do: {:error, :approval_consumed}
  defp ensure_approved(_request), do: {:error, :approval_denied}

  defp ensure_completion_approved(%RemoteAccessRequest{status: status})
       when status in [:approved, :consumed], do: :ok

  defp ensure_completion_approved(%RemoteAccessRequest{} = request), do: ensure_approved(request)

  defp ensure_completion_bound_to_session(
         %RemoteAccessRequest{status: :approved, session_id: nil},
         _session_id
       ), do: :ok

  defp ensure_completion_bound_to_session(
         %RemoteAccessRequest{session_id: session_id},
         session_id
       ), do: :ok

  defp ensure_completion_bound_to_session(_request, _session_id),
    do: {:error, :approval_session_mismatch}

  defp ensure_unexpired(%RemoteAccessRequest{expires_at: %DateTime{} = expires_at}) do
    if DateTime.after?(expires_at, RemoteAccessRequest.utc_now()),
      do: :ok,
      else: {:error, :approval_expired}
  end

  defp ensure_unexpired(_request), do: {:error, :approval_expired}

  defp ensure_unbound(%RemoteAccessRequest{session_id: nil}), do: :ok
  defp ensure_unbound(_request), do: {:error, :approval_consumed}

  defp bind_session_locked(request_id, session_id) do
    case Repo.query(lock_approved_request_sql(), [request_id]) do
      {:ok, %{num_rows: 1, rows: [[locked_request_id]]}} ->
        system_opts = [actor: SystemActor.system(:remote_access_request_bind)]

        with {:ok, %RemoteAccessRequest{} = request} <-
               RemoteAccessRequest.get_by_id(locked_request_id, system_opts),
             {:ok, %RemoteAccessRequest{} = bound, notifications} <-
               RemoteAccessRequest.bind_session(
                 request,
                 %{session_id: session_id, bound_at: RemoteAccessRequest.utc_now()},
                 Keyword.put(system_opts, :return_notifications?, true)
               ) do
          {bound, notifications}
        else
          {:ok, nil} -> Repo.rollback(:approval_not_found)
          {:error, error} -> Repo.rollback(error)
        end

      {:ok, %{num_rows: 0}} ->
        Repo.rollback(classify_unbindable_request(request_id))

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp lock_approved_request_sql do
    """
    SELECT id::text
    FROM platform.remote_access_requests
    WHERE id = $1::text::uuid
      AND status = 'approved'
      AND expires_at > (now() AT TIME ZONE 'utc')
      AND session_id IS NULL
    FOR UPDATE
    """
  end

  defp classify_unbindable_request(request_id) do
    case get(request_id, actor: SystemActor.system(:remote_access_request_bind)) do
      {:ok, %RemoteAccessRequest{} = request} ->
        cond do
          match?({:error, _reason}, ensure_approved(request)) ->
            unwrap_error(ensure_approved(request))

          match?({:error, _reason}, ensure_unexpired(request)) ->
            :approval_expired

          match?({:error, _reason}, ensure_unbound(request)) ->
            :approval_consumed

          true ->
            :approval_consumed
        end

      {:error, :not_found} ->
        :approval_not_found

      {:error, reason} ->
        reason
    end
  end

  defp unwrap_error({:error, reason}), do: reason

  defp ensure_reviewer_policy(%RemoteAccessRequest{} = request, opts) do
    if self_approval_allowed?(request) or request.requested_by != actor_uuid(opts),
      do: :ok,
      else: {:error, :self_approval_denied}
  end

  defp self_approval_allowed?(%RemoteAccessRequest{reviewer_policy: policy}),
    do: truthy?(Map.get(policy || %{}, "allow_self_approval"))

  defp ensure_matches_context(request, context) do
    with :ok <- ensure_scope_fields_match(request, context) do
      ensure_metadata_scope_matches(request, context)
    end
  end

  defp ensure_scope_fields_match(request, context) do
    expected = %{
      requested_by: request.requested_by,
      device_uid: request.device_uid,
      target_kind: request.target_kind,
      target_host: request.target_host,
      target_port: request.target_port,
      protocol: request.protocol,
      adapter: request.adapter,
      agent_id: request.agent_id,
      gateway_id: request.gateway_id,
      credential_custody_mode: request.credential_custody_mode,
      credential_rule_id: request.credential_rule_id
    }

    mismatches =
      Enum.reject(expected, fn {key, expected_value} ->
        context_value = value(context, key)

        is_nil(expected_value) or is_nil(context_value) or
          normalize_context_value(key, context_value) == expected_value
      end)

    if mismatches == [], do: :ok, else: {:error, :approval_scope_mismatch}
  end

  defp ensure_metadata_scope_matches(request, context) do
    expected_metadata = sanitized_map(request.metadata)
    context_metadata = context |> value(:metadata) |> sanitized_map()

    mismatches =
      Enum.reject(@approval_metadata_scope_keys, fn key ->
        expected_value = Map.get(expected_metadata, key)

        is_nil(expected_value) or Map.get(context_metadata, key) == expected_value
      end)

    if mismatches == [], do: :ok, else: {:error, :approval_scope_mismatch}
  end

  defp normalize_context_value(key, value)
       when key in [:target_kind, :protocol, :adapter, :credential_custody_mode] do
    cond do
      is_atom(value) -> value
      is_binary(value) -> String.to_existing_atom(value)
      true -> value
    end
  rescue
    ArgumentError -> value
  end

  defp normalize_context_value(:target_port, value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} -> port
      _error -> value
    end
  end

  defp normalize_context_value(_key, value), do: value

  defp target_port(nil), do: {:ok, 22}
  defp target_port(value) when is_integer(value) and value in 1..65_535, do: {:ok, value}

  defp target_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} -> target_port(port)
      _error -> {:error, :invalid_target_port}
    end
  end

  defp target_port(_value), do: {:error, :invalid_target_port}

  defp known_atom(value, allowed, error) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, error}
  end

  defp known_atom(value, allowed, error) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, error}
      atom -> {:ok, atom}
    end
  end

  defp known_atom(_value, _allowed, error), do: {:error, error}

  defp resolve(%RemoteAccessRequest{} = request, _opts), do: {:ok, request}
  defp resolve(id, opts) when is_binary(id), do: get(id, opts)

  defp required_string(value, field) do
    case blank_to_nil(value) do
      nil -> {:error, {:missing_required, field}}
      present -> {:ok, present}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp blank_to_nil(_value), do: nil

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _error -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil

  defp actor_uuid(opts) do
    case Keyword.get(opts, :scope) do
      %{user: %{id: id}} when is_binary(id) -> valid_uuid(id)
      _ -> opts |> Keyword.get(:actor) |> actor_uuid_from_actor()
    end
  end

  defp actor_uuid_from_actor(%{id: id}) when is_binary(id), do: valid_uuid(id)
  defp actor_uuid_from_actor(_actor), do: nil

  defp valid_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp ash_opts(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} -> [scope: scope]
      :error -> [actor: Keyword.get(opts, :actor, SystemActor.system(:remote_access_requests))]
    end
  end

  defp audit_actor(opts) do
    case Keyword.get(opts, :scope) do
      %{user: user} when not is_nil(user) -> user
      _ -> Keyword.get(opts, :actor)
    end
  end

  defp write_audit(action, request, opts) do
    audit_writer = Keyword.get(opts, :audit_writer, AuditWriter)

    audit_writer.write_async(
      action: action,
      resource_type: "remote_access_request",
      resource_id: request.id,
      resource_name: request.device_uid,
      actor: audit_actor(opts),
      details:
        request
        |> audit_details()
        |> CredentialRedactor.redact(),
      severity: audit_severity(action),
      message: "Remote access request #{action_suffix(action)}"
    )
  end

  defp audit_details(request) do
    %{
      status: format_atom(request.status),
      requested_by: request.requested_by,
      approved_by: request.approved_by,
      denied_by: request.denied_by,
      device_uid: request.device_uid,
      target_kind: format_atom(request.target_kind),
      target_host: request.target_host,
      target_port: request.target_port,
      protocol: format_atom(request.protocol),
      adapter: format_atom(request.adapter),
      agent_id: request.agent_id,
      gateway_id: request.gateway_id,
      credential_custody_mode: format_atom(request.credential_custody_mode),
      credential_rule_id: request.credential_rule_id,
      session_id: request.session_id,
      expires_at: format_datetime(request.expires_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp audit_severity(:remote_access_request_denied), do: :high
  defp audit_severity(:remote_access_request_expired), do: :medium
  defp audit_severity(_action), do: :medium

  defp action_suffix(:remote_access_request_created), do: "created"
  defp action_suffix(:remote_access_request_approved), do: "approved"
  defp action_suffix(:remote_access_request_denied), do: "denied"
  defp action_suffix(:remote_access_request_expired), do: "expired"
  defp action_suffix(:remote_access_request_consumed), do: "consumed"
  defp action_suffix(action), do: Atom.to_string(action)

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(value), do: value

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(value), do: value

  defp sanitized_map(value) when is_map(value) do
    value
    |> stringify_map()
    |> CredentialRedactor.redact()
  end

  defp sanitized_map(_value), do: %{}

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)

      value =
        cond do
          is_map(value) -> stringify_map(value)
          is_list(value) -> Enum.map(value, &stringify_value/1)
          true -> value
        end

      {key, value}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value), do: value

  defp truthy?(value) when value in [true, "true", "required", "yes", "1", 1], do: true
  defp truthy?(_value), do: false

  defp not_found?(%NotFound{}), do: true

  defp not_found?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &not_found?/1)
  end

  defp not_found?(_reason), do: false
end
