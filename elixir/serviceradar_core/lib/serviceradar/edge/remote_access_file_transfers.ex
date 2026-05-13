defmodule ServiceRadar.Edge.RemoteAccessFileTransfers do
  @moduledoc """
  Remote-access file-transfer orchestration boundary.

  File transfers are bound to an existing remote-access session. Browser/API
  callers submit only bounded transfer intent; route, target, credential,
  custody, approval, quota, and recording decisions are copied from trusted
  session state and policy.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.RemoteAccessFileTransfer
  alias ServiceRadar.Edge.RemoteAccessSession

  @active_session_statuses [:attached, :opening, :active]
  @default_protocol :sftp
  @frame_type "file_transfer_request"

  @spec request_transfer(String.t(), map(), keyword()) ::
          {:ok, map() | struct()} | {:error, term()}
  def request_transfer(session_id, request, opts \\ []) do
    system_opts = [actor: SystemActor.system(:remote_access_file_transfer)]

    with {:ok, session_id} <- normalize_uuid(session_id),
         {:ok, %RemoteAccessSession{} = session} <- fetch_session(session_id, opts),
         :ok <- ensure_transferable_session(session),
         attrs = transfer_attrs(session, request, opts),
         {:ok, transfer} <- transfer_resource(opts).create_transfer(attrs, system_opts),
         :ok <- dispatch_transfer_request(session, transfer, request, opts) do
      {:ok, transfer}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, :invalid_uuid} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_session(session_id, opts) do
    session_resource(opts).get_by_id(session_id, ash_opts(opts))
  end

  defp ensure_transferable_session(%RemoteAccessSession{status: status})
       when status in @active_session_statuses, do: :ok

  defp ensure_transferable_session(_session), do: {:error, :remote_access_session_not_active}

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

  defp transfer_request_payload(session, transfer, request) do
    %{
      protocol: "sftp",
      transfer_id: value(transfer, :id),
      session_id: session.id,
      operation: string_value(request, :operation),
      direction: string_value(request, :direction),
      path: value(request, :path),
      destination_path: value(request, :destination_path),
      display_name: value(request, :display_name)
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
      atom when is_atom(atom) -> Atom.to_string(atom)
      other -> other
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

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

  defp ash_opts(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} ->
        [scope: scope]

      :error ->
        [actor: Keyword.get(opts, :actor, SystemActor.system(:remote_access_file_transfer))]
    end
  end

  defp command_bus(opts), do: Keyword.get(opts, :command_bus, AgentCommandBus)
  defp session_resource(opts), do: Keyword.get(opts, :session_resource, RemoteAccessSession)

  defp transfer_resource(opts),
    do: Keyword.get(opts, :transfer_resource, RemoteAccessFileTransfer)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
