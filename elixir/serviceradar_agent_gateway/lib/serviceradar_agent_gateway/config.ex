defmodule ServiceRadarAgentGateway.Config do
  @moduledoc """
  Gateway identity configuration using persistent_term.

  Stores the gateway's static identity (gateway_id, domain, capabilities) in
  persistent_term for fast access from gRPC handlers without GenServer overhead.

  ## Platform Infrastructure

  The agent gateway is platform infrastructure that serves all tenants and
  all partitions. This module stores only the gateway's own identity.
  Tenant and partition context flows through each gRPC request via mTLS.

  ## Usage

  Call `setup/1` once at application startup, then use reader functions:

      # At startup (in Application.start)
      Config.setup(gateway_id: "gw-1", domain: "prod")

      # In gRPC handlers
      Config.gateway_id()  # => "gw-1"
      Config.domain()      # => "prod"
  """

  @pt_key __MODULE__

  @doc """
  Initialize gateway config. Call once at application startup.
  """
  @spec setup(keyword()) :: :ok
  def setup(opts) do
    config = %{
      gateway_id: Keyword.fetch!(opts, :gateway_id),
      domain: Keyword.fetch!(opts, :domain),
      capabilities: Keyword.get(opts, :capabilities, [])
    }

    :persistent_term.put(@pt_key, config)
    :ok
  end

  @doc """
  Returns the full config map.
  """
  @spec get() :: map()
  def get do
    :persistent_term.get(@pt_key)
  end

  @doc """
  Returns the gateway's unique identifier.
  """
  @spec gateway_id() :: String.t()
  def gateway_id do
    get().gateway_id
  end

  @doc """
  Returns the domain this gateway serves.
  """
  @spec domain() :: String.t()
  def domain do
    get().domain
  end

  @doc """
  Returns the gateway's capabilities.
  """
  @spec capabilities() :: [atom()]
  def capabilities do
    get().capabilities
  end

  @doc """
  Get a specific config value by key.
  """
  @spec get(atom()) :: any()
  def get(key) when is_atom(key) do
    Map.get(get(), key)
  end
end
