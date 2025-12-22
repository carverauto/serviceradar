defmodule Datasvc do
  @moduledoc """
  Elixir client for the ServiceRadar datasvc gRPC service.

  Datasvc provides access to NATS JetStream for:
  - KV store operations (`Datasvc.KV`)
  - Object store operations (future)
  - Event streaming (future)

  ## Configuration

  Configure the datasvc address in your application config:

      config :datasvc,
        address: "localhost:50053",
        timeout: 5000

  ## Usage

      # Check if datasvc is configured
      Datasvc.configured?()

      # Use KV operations
      {:ok, keys} = Datasvc.KV.list_keys("templates/checkers/mtls/")
      {:ok, value, revision} = Datasvc.KV.get("some/key")

  """

  require Logger

  @default_timeout 5_000

  @doc """
  Gets the configured datasvc address.

  Returns `nil` if not configured.
  """
  @spec address() :: String.t() | nil
  def address do
    config() |> Keyword.get(:address)
  end

  @doc """
  Gets the configured default timeout in milliseconds.
  """
  @spec default_timeout() :: pos_integer()
  def default_timeout do
    config() |> Keyword.get(:timeout, @default_timeout)
  end

  @doc """
  Returns true if datasvc is configured.
  """
  @spec configured?() :: boolean()
  def configured? do
    address() != nil
  end

  @doc """
  Creates a gRPC channel to datasvc.

  Returns `{:ok, channel}` on success, `{:error, reason}` on failure.
  """
  @spec connect(keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def connect(opts \\ []) do
    case address() do
      nil ->
        {:error, :not_configured}

      addr ->
        interceptors = Keyword.get(opts, :interceptors, [])

        case GRPC.Stub.connect(addr, interceptors: interceptors) do
          {:ok, channel} -> {:ok, channel}
          {:error, reason} -> {:error, {:connection_failed, reason}}
        end
    end
  end

  @doc """
  Executes a gRPC call with a temporary channel.

  Connects, executes the function, and returns the result.
  Handles connection errors gracefully.

  ## Example

      Datasvc.with_channel(fn channel ->
        Stub.some_rpc(channel, request, timeout: 5000)
      end)

  """
  @spec with_channel((GRPC.Channel.t() -> result)) :: result | {:error, term()}
        when result: term()
  def with_channel(fun) when is_function(fun, 1) do
    case connect() do
      {:ok, channel} ->
        try do
          fun.(channel)
        after
          # Note: GRPC connections in Elixir are lightweight
          # Could add connection pooling here in the future
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def config do
    Application.get_env(:datasvc, :datasvc, [])
  end
end
