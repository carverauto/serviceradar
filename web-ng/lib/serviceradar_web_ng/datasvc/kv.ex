defmodule ServiceRadarWebNG.Datasvc.KV do
  @moduledoc """
  KV store operations via datasvc gRPC.

  Provides access to NATS JetStream KV store for operations like
  listing keys, getting values, and store metadata.

  ## Usage

      # List keys with a prefix
      {:ok, keys} = KV.list_keys("templates/checkers/mtls/")

      # Get a value
      {:ok, value, revision} = KV.get("templates/checkers/mtls/sysmon.json")

      # Get store info
      {:ok, info} = KV.info()

  """

  require Logger

  alias ServiceRadarWebNG.Datasvc
  alias ServiceRadarWebNG.Datasvc.KV.Proto

  @doc """
  Lists all keys matching the given prefix.

  Returns `{:ok, [keys]}` on success, `{:error, reason}` on failure.
  """
  @spec list_keys(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_keys(prefix, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Datasvc.default_timeout())

    Datasvc.with_channel(fn channel ->
      request = %Proto.ListKeysRequest{prefix: prefix}

      case Proto.Stub.list_keys(channel, request, timeout: timeout) do
        {:ok, %Proto.ListKeysResponse{keys: keys}} ->
          {:ok, keys}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.warning("KV list_keys failed: #{inspect(error)}")
          {:error, {:grpc_error, error.status, error.message}}

        {:error, reason} ->
          Logger.warning("KV list_keys failed: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  @doc """
  Gets a value by key.

  Returns `{:ok, value, revision}` if found, `{:ok, nil, 0}` if not found,
  or `{:error, reason}` on failure.
  """
  @spec get(String.t(), keyword()) :: {:ok, binary() | nil, non_neg_integer()} | {:error, term()}
  def get(key, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Datasvc.default_timeout())

    Datasvc.with_channel(fn channel ->
      request = %Proto.GetRequest{key: key}

      case Proto.Stub.get(channel, request, timeout: timeout) do
        {:ok, %Proto.GetResponse{found: true, value: value, revision: revision}} ->
          {:ok, value, revision}

        {:ok, %Proto.GetResponse{found: false}} ->
          {:ok, nil, 0}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.warning("KV get failed: #{inspect(error)}")
          {:error, {:grpc_error, error.status, error.message}}

        {:error, reason} ->
          Logger.warning("KV get failed: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  @doc """
  Gets info about the KV store.

  Returns `{:ok, %{domain: domain, bucket: bucket, object_bucket: object_bucket}}` on success.
  """
  @spec info(keyword()) :: {:ok, map()} | {:error, term()}
  def info(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Datasvc.default_timeout())

    Datasvc.with_channel(fn channel ->
      request = %Proto.InfoRequest{}

      case Proto.Stub.info(channel, request, timeout: timeout) do
        {:ok, %Proto.InfoResponse{} = response} ->
          {:ok,
           %{
             domain: response.domain,
             bucket: response.bucket,
             object_bucket: response.object_bucket
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.warning("KV info failed: #{inspect(error)}")
          {:error, {:grpc_error, error.status, error.message}}

        {:error, reason} ->
          Logger.warning("KV info failed: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  @doc """
  Checks if the KV store is available.
  """
  @spec available?() :: boolean()
  def available? do
    Datasvc.configured?()
  end
end
