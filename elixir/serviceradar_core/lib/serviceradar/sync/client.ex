defmodule ServiceRadar.Sync.Client do
  @moduledoc """
  gRPC client for communicating with the serviceradar-sync Go service.

  This client wraps the generated gRPC stubs and provides a clean interface
  for the Agent processes to report status and upload/download data.

  ## Configuration

  Configure the sync service endpoint in your config:

      config :serviceradar_core, ServiceRadar.Sync.Client,
        host: "localhost",
        port: 50051,
        ssl: false

  ## Usage

  The client is typically used by Agent processes to:
  1. Push gateway status to the sync service
  2. Upload/download data objects
  3. Query canonical device information
  """

  require Logger

  @default_host "localhost"
  @default_port 50_051
  @default_timeout 30_000

  @type connection_opts :: [
          host: String.t(),
          port: non_neg_integer(),
          ssl: boolean(),
          timeout: non_neg_integer()
        ]

  @doc """
  Connect to the sync service.

  Returns a channel that can be used for subsequent calls.
  """
  @spec connect(connection_opts()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def connect(opts \\ []) do
    host = opts[:host] || config(:host, @default_host)
    port = opts[:port] || config(:port, @default_port)
    ssl = opts[:ssl] || config(:ssl, false)

    endpoint = "#{host}:#{port}"

    cred_opts = if ssl, do: GRPC.Credential.new([]), else: []

    case GRPC.Stub.connect(endpoint, cred_opts) do
      {:ok, channel} ->
        Logger.debug("Connected to sync service at #{endpoint}")
        {:ok, channel}

      {:error, reason} = error ->
        Logger.error("Failed to connect to sync service at #{endpoint}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Disconnect from the sync service.
  """
  @spec disconnect(GRPC.Channel.t()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def disconnect(channel) do
    GRPC.Stub.disconnect(channel)
  end

  @doc """
  Push gateway status to the sync service.

  This is the primary method for pushing monitoring data from the
  agent to the sync service.
  """
  @spec push_status(GRPC.Channel.t(), Monitoring.GatewayStatusRequest.t(), keyword()) ::
          {:ok, Monitoring.GatewayStatusResponse.t()} | {:error, term()}
  def push_status(channel, request, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    case Monitoring.AgentGatewayService.Stub.push_status(channel, request, timeout: timeout) do
      {:ok, response} ->
        Logger.debug("Status reported successfully for gateway #{request.gateway_id}")
        {:ok, response}

      {:error, %GRPC.RPCError{} = error} ->
        Logger.error("gRPC error reporting status: #{GRPC.RPCError.message(error)}")
        {:error, error}

      {:error, reason} = error ->
        Logger.error("Error reporting status: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stream status updates to the sync service.

  This is useful for large batches of service status updates that
  need to be chunked.
  """
  @spec stream_status(GRPC.Channel.t(), Enumerable.t(Monitoring.GatewayStatusChunk.t()), keyword()) ::
          {:ok, Monitoring.GatewayStatusResponse.t()} | {:error, term()}
  def stream_status(channel, chunks, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    stream = Monitoring.AgentGatewayService.Stub.stream_status(channel, timeout: timeout)

    Enum.each(chunks, fn chunk ->
      GRPC.Stub.send_request(stream, chunk)
    end)

    case GRPC.Stub.recv(stream) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Error streaming status: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Get canonical device information from the sync service.
  """
  @spec get_canonical_device(GRPC.Channel.t(), Core.GetCanonicalDeviceRequest.t(), keyword()) ::
          {:ok, Core.GetCanonicalDeviceResponse.t()} | {:error, term()}
  def get_canonical_device(channel, request, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    case Core.CoreService.Stub.get_canonical_device(channel, request, timeout: timeout) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Error getting canonical device: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Upload a data object to the sync service.

  The data is streamed in chunks to handle large objects efficiently.
  """
  @spec upload_object(GRPC.Channel.t(), Proto.ObjectMetadata.t(), binary(), keyword()) ::
          {:ok, Proto.UploadObjectResponse.t()} | {:error, term()}
  def upload_object(channel, metadata, data, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout
    # 64KB chunks
    chunk_size = opts[:chunk_size] || 64 * 1024

    stream = Proto.DataService.Stub.upload_object(channel, timeout: timeout)

    # Split data into chunks
    chunks = chunk_binary(data, chunk_size)
    total_chunks = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk_data, index} ->
      chunk = %Proto.ObjectUploadChunk{
        metadata: if(index == 0, do: metadata, else: nil),
        data: chunk_data,
        chunk_index: index,
        is_final: index == total_chunks - 1
      }

      GRPC.Stub.send_request(stream, chunk)
    end)

    case GRPC.Stub.recv(stream) do
      {:ok, response} ->
        Logger.debug("Object uploaded: #{metadata.key}")
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Error uploading object: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Download a data object from the sync service.

  Returns the complete binary data after receiving all chunks.
  """
  @spec download_object(GRPC.Channel.t(), String.t(), keyword()) ::
          {:ok, {Proto.ObjectInfo.t(), binary()}} | {:error, term()}
  def download_object(channel, key, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout
    request = %Proto.DownloadObjectRequest{key: key}

    case Proto.DataService.Stub.download_object(channel, request, timeout: timeout) do
      {:ok, stream} ->
        collect_download_chunks(stream)

      {:error, reason} = error ->
        Logger.error("Error downloading object #{key}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Get object info without downloading the data.
  """
  @spec get_object_info(GRPC.Channel.t(), String.t(), keyword()) ::
          {:ok, Proto.GetObjectInfoResponse.t()} | {:error, term()}
  def get_object_info(channel, key, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout
    request = %Proto.GetObjectInfoRequest{key: key}

    case Proto.DataService.Stub.get_object_info(channel, request, timeout: timeout) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Error getting object info for #{key}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Delete an object from the sync service.
  """
  @spec delete_object(GRPC.Channel.t(), String.t(), keyword()) ::
          {:ok, Proto.DeleteObjectResponse.t()} | {:error, term()}
  def delete_object(channel, key, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout
    request = %Proto.DeleteObjectRequest{key: key}

    case Proto.DataService.Stub.delete_object(channel, request, timeout: timeout) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Error deleting object #{key}: #{inspect(reason)}")
        error
    end
  end

  # Helper: Collect download chunks into a single binary
  defp collect_download_chunks(stream) do
    collect_download_chunks(stream, nil, [])
  end

  defp collect_download_chunks(stream, info, acc) do
    case GRPC.Stub.recv(stream) do
      {:ok, chunk} ->
        new_info = chunk.info || info
        new_acc = [chunk.data | acc]

        if chunk.is_final do
          data = acc |> Enum.reverse() |> IO.iodata_to_binary()
          {:ok, {new_info, data}}
        else
          collect_download_chunks(stream, new_info, new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Helper: Split binary into chunks
  defp chunk_binary(data, chunk_size) when is_binary(data) do
    chunk_binary(data, chunk_size, [])
  end

  defp chunk_binary(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp chunk_binary(data, chunk_size, acc) when byte_size(data) <= chunk_size do
    Enum.reverse([data | acc])
  end

  defp chunk_binary(data, chunk_size, acc) do
    <<chunk::binary-size(chunk_size), rest::binary>> = data
    chunk_binary(rest, chunk_size, [chunk | acc])
  end

  # Helper: Get configuration value
  defp config(key, default) do
    Application.get_env(:serviceradar_core, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
