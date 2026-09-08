defmodule ServiceRadarAgentGateway.ReleaseArtifactServer do
  @moduledoc """
  HTTPS artifact download endpoint for mirrored agent releases.
  """

  use Plug.Router

  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Plugins.StorageToken
  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  require Logger

  @download_timeout 30_000
  @upload_timeout 120_000
  @upload_read_length 64 * 1024
  @download_path "/artifacts/releases/download"
  @plugin_download_path "/artifacts/plugins/:id/blob/download"
  @addon_download_path "/artifacts/addons/:id/blob/download"
  @agent_artifact_download_path "/artifacts/agent-artifacts/:id/download"
  @agent_artifact_upload_path "/artifacts/agent-artifacts/upload"
  @target_header "x-serviceradar-release-target-id"
  @command_header "x-serviceradar-release-command-id"
  @plugin_token_header "x-serviceradar-plugin-token"
  @artifact_key_header "x-serviceradar-artifact-key"
  @artifact_assignment_header "x-serviceradar-artifact-assignment-id"
  @artifact_plugin_header "x-serviceradar-artifact-plugin-id"
  @artifact_sha256_header "x-serviceradar-artifact-sha256"
  @artifact_size_header "x-serviceradar-artifact-size"
  @artifact_source_header "x-serviceradar-artifact-source"
  @allowed_component_types [:agent]

  plug(:match)
  plug(:dispatch)

  get @download_path do
    with {:ok, caller_identity} <- resolve_identity(conn),
         :ok <- authorize_caller_identity(caller_identity),
         {:ok, target_id} <- required_header(conn, @target_header),
         {:ok, command_id} <- required_header(conn, @command_header),
         {:ok, download} <- resolve_download(conn, target_id, command_id, caller_identity),
         {:ok, data} <- download_object(conn, download.object_key) do
      conn
      |> Plug.Conn.put_resp_content_type(download.content_type || "application/octet-stream")
      |> Plug.Conn.put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{download.file_name || "serviceradar-agent"}")
      )
      |> send_resp(200, data)
    else
      {:error, :missing_target_id} ->
        send_json_error(conn, 400, "missing release target id")

      {:error, :missing_command_id} ->
        send_json_error(conn, 400, "missing release command id")

      {:error, :unauthenticated} ->
        send_json_error(conn, 401, "invalid client certificate")

      {:error, :unauthorized} ->
        send_json_error(conn, 403, "release artifact access denied")

      # Retryable: the mirror/artifact is not ready to serve on this replica yet
      # (transient/not-staged). 409 lets the agent back off and retry instead of
      # treating it as a terminal failure.
      {:error, :artifact_not_ready} ->
        send_json_error(conn, 409, "release artifact is not ready yet")

      {:error, :artifact_not_mirrored} ->
        send_json_error(conn, 424, "release artifact is not mirrored into internal storage")

      {:error, %GRPC.RPCError{status: 5}} ->
        send_json_error(conn, 404, "release artifact not found")

      {:error, reason} ->
        Logger.warning("Release artifact download failed: #{inspect(reason)}")
        send_json_error(conn, 502, "release artifact download failed")
    end
  end

  get @plugin_download_path do
    serve_token_artifact(conn, id, :resolve_plugin_artifact_download, "plugin artifact")
  end

  post @plugin_download_path do
    serve_token_artifact(conn, id, :resolve_plugin_artifact_download, "plugin artifact")
  end

  get @addon_download_path do
    serve_token_artifact(conn, id, :resolve_addon_artifact_download, "add-on artifact")
  end

  post @addon_download_path do
    serve_token_artifact(conn, id, :resolve_addon_artifact_download, "add-on artifact")
  end

  get @agent_artifact_download_path do
    serve_token_artifact(conn, id, :resolve_agent_artifact_download, "agent artifact")
  end

  post @agent_artifact_download_path do
    serve_token_artifact(conn, id, :resolve_agent_artifact_download, "agent artifact")
  end

  post @agent_artifact_upload_path do
    with {:ok, caller_identity} <- resolve_identity(conn),
         :ok <- authorize_caller_identity(caller_identity),
         {:ok, metadata} <- build_upload_metadata(conn, caller_identity.component_id),
         {:ok, response, conn} <- upload_object(conn, metadata) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(upload_response_body(response, metadata)))
    else
      {:error, :missing_artifact_key} ->
        send_json_error(conn, 400, "missing artifact key")

      {:error, :invalid_artifact_key} ->
        send_json_error(conn, 400, "invalid artifact key")

      {:error, :invalid_artifact_size} ->
        send_json_error(conn, 400, "invalid artifact size")

      {:error, :unauthenticated} ->
        send_json_error(conn, 401, "invalid client certificate")

      {:error, :unauthorized} ->
        send_json_error(conn, 403, "agent artifact upload denied")

      {:error, reason} ->
        Logger.warning("agent artifact upload failed: #{inspect(reason)}")
        send_json_error(conn, 502, "agent artifact upload failed")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  def child_spec(opts) do
    scheme = Keyword.get(opts, :scheme, :https)

    thousand_island_options =
      case scheme do
        :https ->
          [
            transport_options: [
              certfile: opts[:certfile],
              keyfile: opts[:keyfile],
              cacertfile: opts[:cacertfile],
              verify: :verify_peer,
              fail_if_no_peer_cert: true
            ]
          ]

        _ ->
          []
      end

    bandit_opts =
      [
        plug: {__MODULE__, opts},
        scheme: scheme,
        ip: Keyword.get(opts, :ip, {0, 0, 0, 0}),
        port: Keyword.fetch!(opts, :port),
        thousand_island_options: thousand_island_options
      ]

    Supervisor.child_spec(Bandit.child_spec(bandit_opts), id: {__MODULE__, bandit_opts[:port]})
  end

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:release_artifact_server_opts, opts)
    |> super(opts)
  end

  defp required_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] when value != "" -> {:ok, value}
      _ -> {:error, missing_header_reason(header)}
    end
  end

  defp missing_header_reason(@target_header), do: :missing_target_id
  defp missing_header_reason(@command_header), do: :missing_command_id
  defp missing_header_reason(@plugin_token_header), do: :missing_token
  defp missing_header_reason(@artifact_key_header), do: :missing_artifact_key

  defp send_json_error(conn, status, message) do
    body = Jason.encode!(%{"error" => message})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp serve_token_artifact(conn, expected_id, resolver, label) do
    with {:ok, caller_identity} <- resolve_identity(conn),
         :ok <- authorize_caller_identity(caller_identity),
         {:ok, token} <- required_header(conn, @plugin_token_header),
         {:ok, %{id: token_id, key: object_key}} <- StorageToken.verify_token(:download, token),
         true <- token_id == expected_id,
         {:ok, download} <-
           resolve_token_download(conn, resolver, token_id, object_key, caller_identity),
         {:ok, data} <- download_object(conn, download.object_key) do
      conn
      |> Plug.Conn.put_resp_content_type(download.content_type || "application/octet-stream")
      |> Plug.Conn.put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{download.file_name || label}")
      )
      |> send_resp(200, data)
    else
      {:error, :missing_token} ->
        send_json_error(conn, 401, "missing artifact download token")

      {:error, :invalid_token} ->
        send_json_error(conn, 401, "invalid artifact download token")

      {:error, :unauthenticated} ->
        send_json_error(conn, 401, "invalid client certificate")

      {:error, :unauthorized} ->
        send_json_error(conn, 403, "#{label} access denied")

      false ->
        send_json_error(conn, 403, "#{label} access denied")

      {:error, %GRPC.RPCError{status: 5}} ->
        send_json_error(conn, 404, "#{label} not found")

      {:error, reason} ->
        Logger.warning("#{label} download failed: #{inspect(reason)}")
        send_json_error(conn, 502, "#{label} download failed")
    end
  end

  defp core_rpc(function, args) do
    core_nodes()
    |> Enum.reduce_while({:error, :core_unavailable}, fn node, _acc ->
      case :rpc.call(node, ServiceRadar.Edge.AgentGatewaySync, function, args, @download_timeout) do
        {:badrpc, reason} ->
          Logger.warning("Core RPC failed for #{function}: #{inspect(reason)}")
          {:cont, {:error, :core_unavailable}}

        {:error, _reason} = error ->
          {:halt, error}

        result ->
          {:halt, {:ok, result}}
      end
    end)
    |> normalize_core_result()
  end

  defp normalize_core_result({:ok, {:ok, result}}), do: {:ok, result}
  defp normalize_core_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_core_result(other), do: other

  defp resolve_download(conn, target_id, command_id, caller_identity) do
    opts = conn.private[:release_artifact_server_opts] || []

    case Keyword.get(opts, :resolve_download) do
      fun when is_function(fun, 3) ->
        fun.(target_id, command_id, caller_identity.component_id)

      fun when is_function(fun, 2) ->
        fun.(target_id, command_id)

      _ ->
        core_rpc(:resolve_release_artifact_download, [
          target_id,
          command_id,
          caller_identity.component_id
        ])
    end
  end

  defp resolve_token_download(conn, resolver, token_id, object_key, caller_identity) do
    opts = conn.private[:release_artifact_server_opts] || []

    case Keyword.get(opts, resolver) do
      fun when is_function(fun, 3) ->
        fun.(token_id, object_key, caller_identity.component_id)

      _ ->
        core_rpc(resolver, [token_id, object_key, caller_identity.component_id])
    end
  end

  defp download_object(conn, object_key) do
    opts = conn.private[:release_artifact_server_opts] || []

    case Keyword.get(opts, :download_object) do
      fun when is_function(fun, 1) ->
        fun.(object_key)

      _ ->
        Client.with_direct_channel(
          fn channel -> download_object_from_channel(channel, object_key) end,
          timeout: @download_timeout,
          connect_timeout_ms: @download_timeout
        )
    end
  end

  defp upload_object(conn, metadata) do
    opts = conn.private[:release_artifact_server_opts] || []

    case Keyword.get(opts, :upload_object) do
      fun when is_function(fun, 2) ->
        with {:ok, data, conn} <- read_request_body(conn),
             {:ok, response} <- fun.(metadata, data) do
          {:ok, response, conn}
        end

      _ ->
        Client.with_direct_channel(
          fn channel -> upload_object_from_channel(channel, conn, metadata) end,
          timeout: @upload_timeout,
          connect_timeout_ms: @download_timeout
        )
    end
  end

  defp core_nodes do
    nodes = Node.list()

    coordinators =
      Enum.filter(nodes, fn node ->
        case :rpc.call(node, Process, :whereis, [ServiceRadar.ClusterHealth], 5_000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end)

    if coordinators == [] do
      Enum.filter(nodes, &core_node?/1)
    else
      coordinators
    end
  end

  defp core_node?(node) when is_atom(node) do
    String.starts_with?(Atom.to_string(node), "#{core_node_basename()}@")
  end

  defp core_node?(_node), do: false

  defp core_node_basename do
    System.get_env("CLUSTER_CORE_NODE_BASENAME") ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :cluster_core_node_basename,
        "serviceradar_core"
      )
  end

  defp resolve_identity(conn) do
    opts = conn.private[:release_artifact_server_opts] || []

    case Keyword.get(opts, :resolve_identity) do
      fun when is_function(fun, 1) ->
        fun.(conn)

      _ ->
        conn
        |> Plug.Conn.get_peer_data()
        |> Map.get(:ssl_cert)
        |> resolve_identity_from_cert()
    end
  rescue
    _error ->
      {:error, :unauthenticated}
  end

  defp download_object_from_channel(channel, object_key) do
    case ServiceRadar.Sync.Client.download_object(channel, object_key, timeout: @download_timeout) do
      {:ok, {_info, data}} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_object_from_channel(channel, conn, metadata) do
    stream = Proto.DataService.Stub.upload_object(channel, timeout: @upload_timeout)

    case send_upload_chunks(conn, stream, metadata, 0) do
      {:ok, conn} ->
        case GRPC.Stub.recv(stream) do
          {:ok, response} -> {:ok, response, conn}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_upload_chunks(conn, stream, metadata, index) do
    case Plug.Conn.read_body(conn, length: @upload_read_length, read_length: @upload_read_length) do
      {:more, data, conn} ->
        send_upload_chunk(stream, metadata, data, index, false)
        send_upload_chunks(conn, stream, nil, index + 1)

      {:ok, data, conn} ->
        send_upload_chunk(stream, metadata, data, index, true)
        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_upload_chunk(stream, metadata, data, index, final?) do
    chunk = %Proto.ObjectUploadChunk{
      metadata: metadata,
      data: data,
      chunk_index: index,
      is_final: final?
    }

    GRPC.Stub.send_request(stream, chunk, end_stream: final?)
  end

  defp read_request_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn, length: @upload_read_length, read_length: @upload_read_length) do
      {:more, data, conn} -> read_request_body(conn, [data | acc])
      {:ok, data, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([data | acc])), conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_upload_metadata(conn, caller_agent_id) do
    with {:ok, requested_key} <- required_header(conn, @artifact_key_header),
         {:ok, object_key} <-
           scoped_upload_object_key(
             caller_agent_id,
             header_value(conn, @artifact_assignment_header),
             requested_key
           ),
         {:ok, size} <- artifact_size(header_value(conn, @artifact_size_header)),
         {:ok, sha256} <- artifact_sha256(header_value(conn, @artifact_sha256_header)) do
      content_type =
        conn
        |> Plug.Conn.get_req_header("content-type")
        |> List.first()
        |> normalize_string()

      assignment_id = header_value(conn, @artifact_assignment_header)
      plugin_id = header_value(conn, @artifact_plugin_header)
      source = header_value(conn, @artifact_source_header) || "wasm-plugin"

      {:ok,
       %Proto.ObjectMetadata{
         key: object_key,
         content_type: content_type || "application/octet-stream",
         sha256: sha256 || "",
         total_size: size || 0,
         attributes:
           compact_map(%{
             "agent_id" => caller_agent_id,
             "assignment_id" => assignment_id,
             "plugin_id" => plugin_id,
             "source" => source,
             "storage_backend" => "datasvc_object_store"
           })
       }}
    end
  end

  defp upload_response_body(response, metadata) do
    info =
      case response do
        %Proto.UploadObjectResponse{info: %Proto.ObjectInfo{} = object_info} -> object_info
        _ -> nil
      end

    %{
      object_key: metadata.key,
      content_type: metadata.content_type,
      sha256: (info && info.sha256) || metadata.sha256,
      size_bytes: (info && info.size) || metadata.total_size,
      attributes: metadata.attributes
    }
  end

  defp header_value(conn, header) do
    conn
    |> Plug.Conn.get_req_header(header)
    |> List.first()
    |> normalize_string()
  end

  defp scoped_upload_object_key(caller_agent_id, assignment_id, requested_key) do
    with {:ok, caller_segment} <- safe_segment(caller_agent_id),
         {:ok, assignment_segment} <- safe_segment(assignment_id || "unassigned"),
         {:ok, requested_path} <- safe_relative_path(requested_key) do
      {:ok, "agent-artifacts/#{caller_segment}/#{assignment_segment}/#{requested_path}"}
    end
  end

  defp safe_relative_path(value) do
    value = normalize_string(value)

    cond do
      value == nil ->
        {:error, :missing_artifact_key}

      String.starts_with?(value, "/") or String.contains?(value, "..") or
          String.contains?(value, "//") ->
        {:error, :invalid_artifact_key}

      true ->
        segments = String.split(value, "/")

        if Enum.all?(segments, &safe_relative_path_segment?/1) do
          {:ok, Enum.join(segments, "/")}
        else
          {:error, :invalid_artifact_key}
        end
    end
  end

  defp safe_relative_path_segment?(segment) do
    segment != "" and segment not in [".", ".."] and Regex.match?(~r/^[A-Za-z0-9._-]+$/, segment)
  end

  defp safe_segment(value) do
    value = normalize_string(value)

    cond do
      value == nil -> {:error, :invalid_artifact_key}
      Regex.match?(~r/^[A-Za-z0-9._:-]+$/, value) -> {:ok, value}
      true -> {:error, :invalid_artifact_key}
    end
  end

  defp artifact_size(nil), do: {:ok, nil}

  defp artifact_size(value) do
    case Integer.parse(value) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, :invalid_artifact_size}
    end
  end

  defp artifact_sha256(nil), do: {:ok, nil}

  defp artifact_sha256(value) do
    value = String.downcase(value)

    if Regex.match?(~r/^[a-f0-9]{64}$/, value) do
      {:ok, value}
    else
      {:error, :invalid_artifact_key}
    end
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_value), do: nil

  defp resolve_identity_from_cert(cert_der) when is_binary(cert_der) do
    case ComponentIdentityResolver.resolve_from_cert(cert_der) do
      {:ok, identity} -> {:ok, identity}
      {:error, _reason} -> {:error, :unauthenticated}
    end
  end

  defp resolve_identity_from_cert(_), do: {:error, :unauthenticated}

  defp authorize_caller_identity(%{component_id: component_id, component_type: component_type})
       when is_binary(component_id) and component_type in @allowed_component_types, do: :ok

  defp authorize_caller_identity(_identity), do: {:error, :unauthorized}
end
