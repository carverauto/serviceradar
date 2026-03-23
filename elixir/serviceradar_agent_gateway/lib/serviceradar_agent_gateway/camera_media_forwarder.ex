defmodule ServiceRadarAgentGateway.CameraMediaForwarder do
  @moduledoc """
  Forwards gateway-accepted camera media sessions to the core-elx media ingress.

  The gateway remains the edge-facing trust boundary. Core-elx becomes the
  authoritative ingress for relay session ownership and media pipeline startup.
  """

  alias Camera.CameraMediaService.Stub

  require Logger

  @compile {:no_warn_undefined, Stub}

  @default_host "127.0.0.1"
  @default_port 50_062
  @default_timeout 15_000

  def open_relay_session(%Camera.OpenRelaySessionRequest{} = request, opts \\ []) do
    with_channel(opts, fn channel ->
      Stub.open_relay_session(channel, request, timeout: timeout(opts))
    end)
  end

  def upload_media(request_stream, opts \\ []) do
    with_channel(opts, fn channel ->
      stream = Stub.upload_media(channel, timeout: timeout(opts))

      Enum.each(request_stream, fn chunk ->
        GRPC.Stub.send_request(stream, chunk)
      end)

      _ = GRPC.Stub.end_stream(stream)
      GRPC.Stub.recv(stream)
    end)
  end

  def heartbeat(%Camera.RelayHeartbeat{} = request, opts \\ []) do
    with_channel(opts, fn channel ->
      Stub.heartbeat(channel, request, timeout: timeout(opts))
    end)
  end

  def close_relay_session(%Camera.CloseRelaySessionRequest{} = request, opts \\ []) do
    with_channel(opts, fn channel ->
      Stub.close_relay_session(channel, request, timeout: timeout(opts))
    end)
  end

  defp with_channel(opts, fun) when is_function(fun, 1) do
    case connect(opts) do
      {:ok, channel} ->
        try do
          fun.(channel)
        after
          _ = GRPC.Stub.disconnect(channel)
        end

      {:error, reason} = error ->
        Logger.error("Failed to connect to core-elx camera media ingress: #{inspect(reason)}")
        error
    end
  end

  defp connect(opts) do
    endpoint = "#{host(opts)}:#{port(opts)}"
    connect_opts = Keyword.put(credentials(opts), :adapter_opts, connect_timeout: timeout(opts))
    GRPC.Stub.connect(endpoint, connect_opts)
  end

  defp credentials(opts) do
    if ssl?(opts), do: [cred: GRPC.Credential.new(ssl: [])], else: []
  end

  defp host(opts), do: opts[:host] || System.get_env("CORE_ELX_MEDIA_HOST", @default_host)

  defp port(opts) do
    opts[:port] || parse_int(System.get_env("CORE_ELX_MEDIA_GRPC_PORT"), @default_port)
  end

  defp timeout(opts), do: opts[:timeout] || @default_timeout
  defp ssl?(opts), do: opts[:ssl] || System.get_env("CORE_ELX_MEDIA_SSL", "false") in ~w(true 1 yes)

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end
end
