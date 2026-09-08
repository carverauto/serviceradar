defmodule ServiceRadar.Edge.RemoteAccessFileTransfers do
  @moduledoc """
  Remote-access file-transfer orchestration boundary.

  File transfers are bound to an existing remote-access session. Browser/API
  callers submit only bounded transfer intent; route, target, credential,
  custody, approval, quota, and recording decisions are copied from trusted
  session state and policy.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.RemoteAccessFileTransfer
  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessRequests
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.RBAC

  @active_session_statuses [:attached, :opening, :active]
  @default_protocol :sftp
  @frame_type "file_transfer_request"
  @max_path_bytes 4_096
  @delete_permission "devices.remote_access.file_transfers.delete"
  @agent_frame_types [
    "file_transfer_progress",
    "file_transfer_outcome",
    "file_transfer_error"
  ]

  @spec request_transfer(String.t(), map(), keyword()) ::
          {:ok, map() | struct()} | {:error, term()}
  def request_transfer(session_id, request, opts \\ []) do
    system_opts = [actor: SystemActor.system(:remote_access_file_transfer)]

    with {:ok, session_id} <- normalize_uuid(session_id),
         {:ok, %RemoteAccessSession{} = session} <- fetch_session(session_id, opts),
         :ok <- ensure_transferable_session(session),
         :ok <- validate_transfer_paths(request),
         attrs = transfer_attrs(session, request, opts),
         {:ok, transfer} <- transfer_resource(opts).create_transfer(attrs, system_opts),
         :ok <- dispatch_transfer_request(session, transfer, request, opts) do
      emit_transfer_event(
        :transfer_requested,
        :remote_access_file_transfer_allowed,
        transfer,
        %{},
        opts
      )

      {:ok, transfer}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      {:error, :invalid_uuid} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec handle_agent_frame(map(), keyword()) ::
          {:ok, map() | struct()} | :ignore | {:error, term()}
  def handle_agent_frame(frame, opts \\ []) when is_map(frame) do
    frame_type = string_value(frame, :frame_type)

    if frame_type in @agent_frame_types do
      with {:ok, payload} <- decode_agent_frame_payload(frame),
           {:ok, transfer_id} <- payload_transfer_id(payload),
           {:ok, transfer} <-
             transfer_resource(opts).get_by_id(transfer_id, actor: system_actor(:read)),
           :ok <- ensure_agent_frame_matches_transfer(frame, transfer) do
        apply_agent_frame(frame_type, transfer, payload, opts)
      else
        {:error, %NotFound{}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      :ignore
    end
  end

  @spec list_transfers(String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def list_transfers(session_id, opts \\ []) do
    with {:ok, session_id} <- normalize_uuid(session_id),
         {:ok, transfers} <- transfer_resource(opts).list_by_session(session_id, ash_opts(opts)) do
      {:ok, page_results(transfers)}
    else
      {:error, :invalid_uuid} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_transfer(RemoteAccessFileTransfer.t() | binary(), keyword()) ::
          {:ok, RemoteAccessFileTransfer.t()} | {:error, term()}
  def delete_transfer(transfer_or_id, opts \\ [])

  def delete_transfer(%RemoteAccessFileTransfer{} = transfer, opts) do
    with :ok <- authorize_delete(opts),
         :ok <- transfer_resource(opts).destroy_transfer(transfer, actor: system_actor(:delete)) do
      write_audit_event(:remote_access_file_transfer_deleted, transfer, %{}, opts)
      {:ok, transfer}
    end
  end

  def delete_transfer(transfer_id, opts) when is_binary(transfer_id) do
    with :ok <- authorize_delete(opts),
         {:ok, %RemoteAccessFileTransfer{} = transfer} <-
           transfer_resource(opts).get_by_id(transfer_id, actor: system_actor(:delete_lookup)),
         :ok <- transfer_resource(opts).destroy_transfer(transfer, actor: system_actor(:delete)) do
      write_audit_event(:remote_access_file_transfer_deleted, transfer, %{}, opts)
      {:ok, transfer}
    end
  end

  @spec mark_started(map() | struct(), keyword()) :: {:ok, map() | struct()} | {:error, term()}
  def mark_started(transfer, opts \\ []) do
    update_transfer(:mark_started, transfer, %{}, :transfer_started, nil, opts)
  end

  @spec record_progress(map() | struct(), map(), keyword()) ::
          {:ok, map() | struct()} | {:error, term()}
  def record_progress(transfer, attrs, opts \\ []) when is_map(attrs) do
    update_transfer(:record_progress, transfer, attrs, :transfer_progress, nil, opts)
  end

  @spec finish(map() | struct(), map(), keyword()) :: {:ok, map() | struct()} | {:error, term()}
  def finish(transfer, attrs, opts \\ []) when is_map(attrs) do
    attrs = Map.put_new(attrs, :completed_at, RemoteAccessFileTransfer.utc_now())

    update_transfer(
      :finish,
      transfer,
      attrs,
      :transfer_completed,
      :remote_access_file_transfer_completed,
      opts
    )
  end

  @spec deny(map() | struct(), term(), keyword()) :: {:ok, map() | struct()} | {:error, term()}
  def deny(transfer, reason, opts \\ []) do
    attrs = finish_attrs(reason, opts)

    update_transfer(
      :deny,
      transfer,
      attrs,
      :transfer_denied,
      :remote_access_file_transfer_denied,
      opts
    )
  end

  @spec fail(map() | struct(), term(), keyword()) :: {:ok, map() | struct()} | {:error, term()}
  def fail(transfer, reason, opts \\ []) do
    attrs = finish_attrs(reason, opts)

    update_transfer(
      :fail,
      transfer,
      attrs,
      :transfer_failed,
      :remote_access_file_transfer_failed,
      opts
    )
  end

  @spec cancel(map() | struct(), term(), keyword()) :: {:ok, map() | struct()} | {:error, term()}
  def cancel(transfer, reason, opts \\ []) do
    attrs = finish_attrs(reason, opts)

    update_transfer(
      :cancel,
      transfer,
      attrs,
      :transfer_canceled,
      :remote_access_file_transfer_canceled,
      opts
    )
  end

  @spec quota_exhausted(map() | struct(), term(), keyword()) ::
          {:ok, map() | struct()} | {:error, term()}
  def quota_exhausted(transfer, reason, opts \\ []) do
    attrs = finish_attrs(reason, opts)

    update_transfer(
      :quota_exhausted,
      transfer,
      attrs,
      :transfer_quota_exhausted,
      :remote_access_file_transfer_quota_exhausted,
      opts
    )
  end

  defp update_transfer(action, transfer, attrs, replay_event, audit_action, opts) do
    with {:ok, updated} <-
           apply(transfer_resource(opts), action, [
             transfer,
             attrs,
             [actor: system_actor(action)]
           ]) do
      emit_transfer_event(replay_event, audit_action, updated, attrs, opts)
      {:ok, updated}
    end
  end

  defp apply_agent_frame("file_transfer_progress", transfer, payload, opts) do
    case normalize_transfer_status(value(payload, :status)) do
      :started -> mark_started(transfer, opts)
      _status -> record_progress(transfer, progress_attrs(payload), opts)
    end
  end

  defp apply_agent_frame("file_transfer_outcome", transfer, payload, opts) do
    apply_terminal_agent_frame(transfer, payload, opts)
  end

  defp apply_agent_frame("file_transfer_error", transfer, payload, opts) do
    status = normalize_transfer_status(value(payload, :status)) || :failed
    reason = string_value(payload, :message) || string_value(payload, :failure_reason) || status

    apply_terminal_agent_frame(transfer, Map.put(payload, "status", Atom.to_string(status)), opts,
      reason: reason
    )
  end

  defp apply_terminal_agent_frame(transfer, payload, opts, extra_opts \\ []) do
    attrs = lifecycle_attrs(payload)

    reason =
      Keyword.get(extra_opts, :reason) || string_value(payload, :failure_reason) || :completed

    opts = Keyword.put(opts, :finish_attrs, attrs)

    with :ok <- ensure_terminal_approval_echo(transfer, payload),
         :ok <- revalidate_transfer_approval(transfer, opts) do
      case normalize_transfer_status(value(payload, :status)) do
        :completed -> finish(transfer, attrs, opts)
        :denied -> deny(transfer, reason, opts)
        :failed -> fail(transfer, reason, opts)
        :canceled -> cancel(transfer, reason, opts)
        :quota_exhausted -> quota_exhausted(transfer, reason, opts)
        :started -> mark_started(transfer, opts)
        :in_progress -> record_progress(transfer, progress_attrs(payload), opts)
        _status -> fail(transfer, reason, opts)
      end
    end
  end

  defp decode_agent_frame_payload(frame) do
    case value(frame, :data) do
      data when is_binary(data) ->
        case Jason.decode(data) do
          {:ok, %{} = payload} -> {:ok, payload}
          {:ok, _value} -> {:error, :invalid_file_transfer_frame_payload}
          {:error, _reason} -> {:error, :invalid_file_transfer_frame_payload}
        end

      %{} = payload ->
        {:ok, payload}

      _value ->
        {:error, :invalid_file_transfer_frame_payload}
    end
  end

  defp payload_transfer_id(payload) do
    case string_value(payload, :transfer_id) do
      nil -> {:error, :invalid_file_transfer_frame_payload}
      transfer_id -> {:ok, transfer_id}
    end
  end

  defp ensure_agent_frame_matches_transfer(frame, transfer) do
    frame_session_id = string_value(frame, :session_id)
    transfer_session_id = string_value(transfer, :session_id)

    if frame_session_id in [nil, transfer_session_id] do
      :ok
    else
      {:error, :file_transfer_session_mismatch}
    end
  end

  defp ensure_terminal_approval_echo(transfer, payload) do
    case string_value(transfer, :approval_id) do
      nil ->
        :ok

      approval_id ->
        if string_value(payload, :approval_id) == approval_id do
          :ok
        else
          {:error, :file_transfer_approval_mismatch}
        end
    end
  end

  defp revalidate_transfer_approval(transfer, opts) do
    case string_value(transfer, :approval_id) do
      nil ->
        :ok

      approval_id ->
        approval_checker(opts).authorize_file_transfer_completion(
          %{
            approval_id: approval_id,
            session_id: string_value(transfer, :session_id),
            transfer_id: string_value(transfer, :id)
          },
          opts
        )
    end
  end

  defp lifecycle_attrs(payload) do
    reject_blank(%{
      byte_count: value(payload, :byte_count) || value(payload, :bytes_transferred),
      file_count: value(payload, :file_count) || value(payload, :files_transferred),
      sha256: string_value(payload, :sha256),
      failure_reason: string_value(payload, :failure_reason) || string_value(payload, :message),
      quota_snapshot: safe_map(value(payload, :quota_snapshot)),
      content_audit_retained: truthy?(value(payload, :content_audit_retained)),
      content_artifact_ref: safe_map(value(payload, :content_artifact_ref)),
      completed_at: RemoteAccessFileTransfer.utc_now()
    })
  end

  defp progress_attrs(payload) do
    reject_blank(%{
      byte_count: value(payload, :byte_count) || value(payload, :bytes_transferred),
      file_count: value(payload, :file_count) || value(payload, :files_transferred),
      quota_snapshot: safe_map(value(payload, :quota_snapshot))
    })
  end

  defp normalize_transfer_status(status) when is_atom(status), do: status
  defp normalize_transfer_status("started"), do: :started
  defp normalize_transfer_status("in_progress"), do: :in_progress
  defp normalize_transfer_status("completed"), do: :completed
  defp normalize_transfer_status("denied"), do: :denied
  defp normalize_transfer_status("failed"), do: :failed
  defp normalize_transfer_status("canceled"), do: :canceled
  defp normalize_transfer_status("cancelled"), do: :canceled
  defp normalize_transfer_status("quota_exhausted"), do: :quota_exhausted
  defp normalize_transfer_status(_status), do: nil

  defp fetch_session(session_id, opts) do
    session_resource(opts).get_by_id(session_id, ash_opts(opts))
  end

  defp ensure_transferable_session(%RemoteAccessSession{status: status})
       when status in @active_session_statuses, do: :ok

  defp ensure_transferable_session(_session), do: {:error, :remote_access_session_not_active}

  defp validate_transfer_paths(request) do
    with :ok <- validate_transfer_path(value(request, :path)) do
      validate_optional_transfer_path(value(request, :destination_path))
    end
  end

  defp validate_optional_transfer_path(nil), do: :ok
  defp validate_optional_transfer_path(path), do: validate_transfer_path(path)

  defp validate_transfer_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :invalid_file_transfer_path}
      byte_size(path) > @max_path_bytes -> {:error, :invalid_file_transfer_path}
      path_has_control_byte?(path) -> {:error, :invalid_file_transfer_path}
      not String.starts_with?(path, "/") -> {:error, :invalid_file_transfer_path}
      path_has_dot_segment?(path) -> {:error, :invalid_file_transfer_path}
      true -> :ok
    end
  end

  defp validate_transfer_path(_path), do: {:error, :invalid_file_transfer_path}

  defp path_has_control_byte?(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 < 32 or &1 == 127))
  end

  defp path_has_dot_segment?(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp transfer_attrs(session, request, opts) do
    direction = normalize_atom(value(request, :direction))
    operation = normalize_atom(value(request, :operation))
    path = value(request, :path)
    destination_path = value(request, :destination_path)
    redacted_path = redacted_path(path, opts)
    destination_redacted_path = redacted_destination_path(destination_path, opts)

    %{
      session_id: session.id,
      requested_by: requested_by(opts),
      device_uid: session.device_uid,
      target_kind: session.target_kind,
      target_host: session.target_host,
      target_port: session.target_port,
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      operation: operation,
      direction: direction,
      protocol: @default_protocol,
      credential_custody_mode: session.credential_custody_mode,
      target_path: path,
      redacted_path: redacted_path,
      path_hash: path_hash(path),
      destination_path: destination_path,
      destination_redacted_path: destination_redacted_path,
      destination_path_hash: optional_path_hash(destination_path),
      policy_snapshot: policy_snapshot(session, opts),
      policy_decision: policy_decision(redacted_path, path),
      quota_snapshot: quota_snapshot(session, opts),
      approval_id: session.approval_id,
      retention_expires_at: retention_expires_at(opts)
    }
  end

  defp dispatch_transfer_request(session, transfer, request, opts) do
    frame = %{
      session_id: session.id,
      frame_type: @frame_type,
      data: Jason.encode!(transfer_request_payload(session, transfer, request)),
      timestamp: System.system_time(:second)
    }

    command_bus(opts).send_console_frame(session.agent_id, frame,
      required_gateway_node: Keyword.get(opts, :required_gateway_node)
    )
  end

  defp emit_transfer_event(replay_event, audit_action, transfer, attrs, opts) do
    _ = write_replay_event(replay_event, transfer, attrs, opts)
    _ = write_audit_event(audit_action, transfer, attrs, opts)
    :ok
  end

  defp write_replay_event(replay_event, transfer, attrs, opts) do
    with {:ok, recording} <- transfer_recording(transfer, opts),
         {:ok, _event} <-
           recordings(opts).record_event(
             recording,
             %{
               stream: :event,
               event_type: Atom.to_string(replay_event),
               payload: transfer_replay_payload(replay_event, transfer, attrs),
               byte_count:
                 nonnegative_int(value(attrs, :byte_count) || value(transfer, :byte_count)),
               metadata: transfer_replay_metadata(replay_event, transfer, attrs)
             },
             recording_opts(opts)
           ) do
      :ok
    else
      {:ok, nil} -> :ok
      {:error, %NotFound{}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp transfer_recording(transfer, opts) do
    case Keyword.fetch(opts, :recording) do
      {:ok, recording} ->
        {:ok, recording}

      :error ->
        case string_value(transfer, :session_id) do
          nil ->
            {:ok, nil}

          session_id ->
            recording_resource(opts).get_by_session(session_id, actor: system_actor(:recording))
        end
    end
  end

  defp write_audit_event(nil, _transfer, _attrs, _opts), do: :ok

  defp write_audit_event(action, transfer, attrs, opts) do
    audit_writer(opts).write_async(
      action: action,
      resource_type: "remote_access_file_transfer",
      resource_id: string_value(transfer, :id) || string_value(attrs, :id),
      resource_name: string_value(transfer, :session_id),
      actor: audit_actor(opts),
      details: audit_details(transfer, attrs),
      severity: audit_severity(action),
      message: "Remote access file transfer #{action_suffix(action)}"
    )
  end

  defp transfer_replay_payload(replay_event, transfer, attrs) do
    %{
      "event" => Atom.to_string(replay_event),
      "transfer_id" => string_value(transfer, :id),
      "session_id" => string_value(transfer, :session_id),
      "status" => string_value(transfer, :status),
      "operation" => string_value(transfer, :operation),
      "direction" => string_value(transfer, :direction),
      "protocol" => string_value(transfer, :protocol),
      "redacted_path" => string_value(transfer, :redacted_path),
      "path_hash" => string_value(transfer, :path_hash),
      "destination_redacted_path" => string_value(transfer, :destination_redacted_path),
      "destination_path_hash" => string_value(transfer, :destination_path_hash),
      "byte_count" => nonnegative_int(value(transfer, :byte_count) || value(attrs, :byte_count)),
      "file_count" => nonnegative_int(value(transfer, :file_count) || value(attrs, :file_count)),
      "sha256" => string_value(transfer, :sha256) || string_value(attrs, :sha256),
      "failure_reason" =>
        string_value(transfer, :failure_reason) || string_value(attrs, :failure_reason),
      "content_audit_retained" => truthy?(value(transfer, :content_audit_retained)),
      "content_artifact_ref" => content_artifact_ref(transfer)
    }
    |> reject_blank()
    |> CredentialRedactor.redact()
  end

  defp transfer_replay_metadata(replay_event, transfer, attrs) do
    %{
      "event_family" => "remote_access_file_transfer",
      "event" => Atom.to_string(replay_event),
      "agent_id" => string_value(transfer, :agent_id),
      "gateway_id" => string_value(transfer, :gateway_id),
      "target_kind" => string_value(transfer, :target_kind),
      "target_host" => string_value(transfer, :target_host),
      "target_port" => nonnegative_int(value(transfer, :target_port)),
      "credential_custody_mode" => string_value(transfer, :credential_custody_mode),
      "policy_decision" => safe_map(value(transfer, :policy_decision)),
      "quota_snapshot" =>
        safe_map(value(transfer, :quota_snapshot) || value(attrs, :quota_snapshot)),
      "approval_id" => string_value(transfer, :approval_id)
    }
    |> reject_blank()
    |> CredentialRedactor.redact()
  end

  defp audit_details(transfer, attrs) do
    %{
      transfer_id: string_value(transfer, :id),
      session_id: string_value(transfer, :session_id),
      requested_by: string_value(transfer, :requested_by),
      device_uid: string_value(transfer, :device_uid),
      agent_id: string_value(transfer, :agent_id),
      gateway_id: string_value(transfer, :gateway_id),
      target_kind: string_value(transfer, :target_kind),
      target_host: string_value(transfer, :target_host),
      target_port: nonnegative_int(value(transfer, :target_port)),
      operation: string_value(transfer, :operation),
      direction: string_value(transfer, :direction),
      protocol: string_value(transfer, :protocol),
      credential_custody_mode: string_value(transfer, :credential_custody_mode),
      status: string_value(transfer, :status),
      redacted_path: string_value(transfer, :redacted_path),
      path_hash: string_value(transfer, :path_hash),
      destination_redacted_path: string_value(transfer, :destination_redacted_path),
      destination_path_hash: string_value(transfer, :destination_path_hash),
      byte_count: nonnegative_int(value(transfer, :byte_count) || value(attrs, :byte_count)),
      file_count: nonnegative_int(value(transfer, :file_count) || value(attrs, :file_count)),
      sha256: string_value(transfer, :sha256) || string_value(attrs, :sha256),
      policy_decision: safe_map(value(transfer, :policy_decision)),
      quota_snapshot: safe_map(value(transfer, :quota_snapshot) || value(attrs, :quota_snapshot)),
      approval_id: string_value(transfer, :approval_id),
      content_audit_retained: truthy?(value(transfer, :content_audit_retained)),
      content_artifact_ref: content_artifact_ref(transfer),
      failure_reason:
        string_value(transfer, :failure_reason) || string_value(attrs, :failure_reason)
    }
    |> reject_blank()
    |> CredentialRedactor.redact()
  end

  defp transfer_request_payload(session, transfer, request) do
    %{
      protocol: "sftp",
      transfer_id: value(transfer, :id),
      session_id: session.id,
      operation: string_value(request, :operation),
      direction: string_value(request, :direction),
      path: value(request, :path),
      destination_path: value(request, :destination_path),
      display_name: value(request, :display_name),
      policy: safe_map(value(transfer, :policy_snapshot)),
      approval_id: string_value(transfer, :approval_id),
      approved: not blank?(value(transfer, :approval_id))
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp policy_decision(redacted_path, path) do
    %{
      allowed: true,
      status: "requested",
      redacted_path: redacted_path,
      path_hash: path_hash(path),
      content_audit_retain: false
    }
  end

  defp finish_attrs(reason, opts) do
    Map.merge(
      %{failure_reason: format_reason(reason), completed_at: RemoteAccessFileTransfer.utc_now()},
      Keyword.get(opts, :finish_attrs, %{})
    )
  end

  defp policy_snapshot(session, opts) do
    session
    |> metadata_value("file_transfer_policy", %{})
    |> safe_map()
    |> Map.merge(Keyword.get(opts, :policy_snapshot, %{}))
  end

  defp quota_snapshot(session, opts) do
    session
    |> metadata_value("file_transfer_quota", %{})
    |> safe_map()
    |> Map.merge(Keyword.get(opts, :quota_snapshot, %{}))
  end

  defp safe_map(value) when is_map(value), do: value
  defp safe_map(_value), do: %{}

  defp page_results(%Ash.Page.Keyset{results: results}), do: results
  defp page_results(%Ash.Page.Offset{results: results}), do: results
  defp page_results(results) when is_list(results), do: results

  defp redacted_path(path, opts) do
    if Keyword.get(opts, :redact_paths?, false) do
      "REDACTED"
    else
      path
    end
  end

  defp redacted_destination_path(nil, _opts), do: nil
  defp redacted_destination_path(path, opts), do: redacted_path(path, opts)

  defp optional_path_hash(nil), do: nil
  defp optional_path_hash(""), do: nil
  defp optional_path_hash(path), do: path_hash(path)

  defp path_hash(path) when is_binary(path) do
    :sha256 |> :crypto.hash(path) |> Base.encode16(case: :lower)
  end

  defp path_hash(_path), do: nil

  defp normalize_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp normalize_uuid(_value), do: {:error, :invalid_uuid}

  defp normalize_atom(value) when is_atom(value), do: value
  defp normalize_atom("list"), do: :list
  defp normalize_atom("stat"), do: :stat
  defp normalize_atom("download"), do: :download
  defp normalize_atom("upload"), do: :upload
  defp normalize_atom("mkdir"), do: :mkdir
  defp normalize_atom("rename"), do: :rename
  defp normalize_atom("remove"), do: :remove
  defp normalize_atom("chmod"), do: :chmod
  defp normalize_atom("chown"), do: :chown
  defp normalize_atom("read"), do: :read
  defp normalize_atom("write"), do: :write
  defp normalize_atom("manage"), do: :manage

  defp string_value(map, key) do
    case value(map, key) do
      nil -> nil
      atom when is_atom(atom) -> Atom.to_string(atom)
      int when is_integer(int) -> Integer.to_string(int)
      other -> other
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, string_key(key)) || map_struct_value(map, key)
  end

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key) when is_binary(key), do: key

  defp metadata_value(session, key, default) do
    metadata =
      case session do
        %{metadata: metadata} when is_map(metadata) -> metadata
        _ -> %{}
      end

    Map.get(metadata, key) || Map.get(metadata, atom_metadata_key(key)) || default
  end

  defp atom_metadata_key("file_transfer_policy"), do: :file_transfer_policy
  defp atom_metadata_key("file_transfer_quota"), do: :file_transfer_quota

  defp requested_by(opts) do
    case Keyword.get(opts, :scope) do
      %{user: %{id: id}} when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> uuid
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp retention_expires_at(opts), do: Keyword.get(opts, :retention_expires_at)

  defp content_artifact_ref(transfer) do
    if truthy?(value(transfer, :content_audit_retained)) do
      safe_map(value(transfer, :content_artifact_ref))
    else
      %{}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp nonnegative_int(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_int(value) when is_binary(value), do: value |> Integer.parse() |> parsed_int()
  defp nonnegative_int(_value), do: 0

  defp parsed_int({value, ""}) when value >= 0, do: value
  defp parsed_int(_value), do: 0

  defp reject_blank(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) or value == %{} end)
    |> Map.new()
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason, printable_limit: 200, limit: 20)

  defp audit_actor(opts) do
    Keyword.get(opts, :audit_actor) ||
      Keyword.get(opts, :actor) ||
      (Keyword.get(opts, :scope) && Map.get(Keyword.get(opts, :scope), :user))
  end

  defp authorize_delete(opts) do
    case audit_actor(opts) do
      %{role: :system} ->
        :ok

      %{role: "system"} ->
        :ok

      nil ->
        {:error, :forbidden}

      actor ->
        if RBAC.has_permission?(actor, @delete_permission), do: :ok, else: {:error, :forbidden}
    end
  end

  defp audit_severity(action)
       when action in [
              :remote_access_file_transfer_denied,
              :remote_access_file_transfer_failed,
              :remote_access_file_transfer_quota_exhausted
            ],
       do: :high

  defp audit_severity(:remote_access_file_transfer_canceled), do: :medium
  defp audit_severity(:remote_access_file_transfer_deleted), do: :high
  defp audit_severity(_action), do: :medium

  defp action_suffix(:remote_access_file_transfer_allowed), do: "allowed"
  defp action_suffix(:remote_access_file_transfer_completed), do: "completed"
  defp action_suffix(:remote_access_file_transfer_denied), do: "denied"
  defp action_suffix(:remote_access_file_transfer_failed), do: "failed"
  defp action_suffix(:remote_access_file_transfer_canceled), do: "canceled"
  defp action_suffix(:remote_access_file_transfer_quota_exhausted), do: "quota exhausted"
  defp action_suffix(:remote_access_file_transfer_deleted), do: "deleted"
  defp action_suffix(action), do: Atom.to_string(action)

  defp recording_opts(opts) do
    [
      audit_actor: audit_actor(opts),
      audit_writer: audit_writer(opts)
    ]
  end

  defp ash_opts(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} ->
        [scope: scope]

      :error ->
        [actor: Keyword.get(opts, :actor, SystemActor.system(:remote_access_file_transfer))]
    end
  end

  defp system_actor(suffix), do: SystemActor.system(:"remote_access_file_transfer_#{suffix}")

  defp command_bus(opts), do: Keyword.get(opts, :command_bus, AgentCommandBus)
  defp audit_writer(opts), do: Keyword.get(opts, :audit_writer, AuditWriter)
  defp recordings(opts), do: Keyword.get(opts, :recordings, RemoteAccessRecordings)
  defp recording_resource(opts), do: Keyword.get(opts, :recording_resource, RemoteAccessRecording)
  defp session_resource(opts), do: Keyword.get(opts, :session_resource, RemoteAccessSession)
  defp approval_checker(opts), do: Keyword.get(opts, :approval_checker, RemoteAccessRequests)

  defp transfer_resource(opts),
    do: Keyword.get(opts, :transfer_resource, RemoteAccessFileTransfer)

  defp map_struct_value(%struct{} = map, key) when is_atom(key) and struct != Map do
    if Map.has_key?(map, key), do: Map.get(map, key)
  end

  defp map_struct_value(_map, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false
end
