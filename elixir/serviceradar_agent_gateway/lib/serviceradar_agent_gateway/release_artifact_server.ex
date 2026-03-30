defmodule ServiceRadarAgentGateway.ReleaseArtifactServer do
  @moduledoc """
  HTTPS artifact download endpoint for mirrored agent releases.
  """

  use Plug.Router

  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  require Logger

  @download_timeout 30_000
  @download_path "/artifacts/releases/download"
  @target_header "x-serviceradar-release-target-id"
  @command_header "x-serviceradar-release-command-id"
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

      {:error, :artifact_not_mirrored} ->
        send_json_error(conn, 424, "release artifact is not mirrored into internal storage")

      {:error, %GRPC.RPCError{status: 5}} ->
        send_json_error(conn, 404, "release artifact not found")

      {:error, reason} ->
        Logger.warning("Release artifact download failed: #{inspect(reason)}")
        send_json_error(conn, 502, "release artifact download failed")
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

  defp send_json_error(conn, status, message) do
    body = Jason.encode!(%{"error" => message})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(status, body)
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
      fun when is_function(fun, 3) -> fun.(target_id, command_id, caller_identity.component_id)
      fun when is_function(fun, 2) -> fun.(target_id, command_id)
      _ -> core_rpc(:resolve_release_artifact_download, [target_id, command_id, caller_identity.component_id])
    end
  end

  defp download_object(conn, object_key) do
    opts = conn.private[:release_artifact_server_opts] || []

    case Keyword.get(opts, :download_object) do
      fun when is_function(fun, 1) ->
        fun.(object_key)

      _ ->
        ServiceRadar.DataService.Client.with_channel(
          fn channel -> download_object_from_channel(channel, object_key) end,
          timeout: @download_timeout
        )
    end
  end

  defp core_nodes do
    Enum.filter(Node.list(), fn node ->
      case :rpc.call(node, Process, :whereis, [ServiceRadar.ClusterHealth], 5_000) do
        pid when is_pid(pid) -> true
        _ -> false
      end
    end)
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
