defmodule ServiceRadar.GatewayRegistry do
  @moduledoc """
  Registry for tracking available agent gateways across the ERTS cluster.

  This module provides gateway discovery for the local instance. Each deployment
  runs independently with its own infrastructure.

  ## Registration

      ServiceRadar.GatewayRegistry.register_gateway("gateway-001", %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      })

  ## Querying Gateways

      # Find all gateways
      ServiceRadar.GatewayRegistry.find_gateways()

      # Find available gateways for a partition
      ServiceRadar.GatewayRegistry.find_gateways_for_partition(partition_id)
  """

  alias ServiceRadar.ProcessRegistry

  require Logger

  @doc """
  Register a gateway in the registry.

  ## Parameters

    - `gateway_id` - Unique gateway identifier
    - `gateway_info` - Gateway metadata map

  ## Examples

      register_gateway("gateway-001", %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      })
  """
  @spec register_gateway(String.t(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()} | term()}
  def register_gateway(gateway_id, gateway_info) when is_binary(gateway_id) do
    metadata = %{
      gateway_id: gateway_id,
      partition_id: Map.get(gateway_info, :partition_id),
      domain: Map.get(gateway_info, :domain),
      node: Node.self(),
      status: Map.get(gateway_info, :status, :available),
      entity_type: :gateway,
      registered_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    case ProcessRegistry.register_gateway(gateway_id, metadata) do
      {:ok, _pid} = result ->
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "gateway:registrations",
          {:gateway_registered, metadata}
        )

        Logger.info("Gateway registered: #{gateway_id}")
        result

      error ->
        Logger.warning("Failed to register gateway #{gateway_id}: #{inspect(error)}")
        error
    end
  end

  @doc """
  Unregister a gateway from the registry.
  """
  @spec unregister_gateway(String.t(), node()) :: :ok
  def unregister_gateway(gateway_id, node \\ Node.self()) when is_binary(gateway_id) do
    ProcessRegistry.unregister_gateway(gateway_id, node)

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:registrations",
      {:gateway_disconnected, gateway_id}
    )

    :ok
  end

  @doc """
  Update gateway heartbeat timestamp.
  """
  @spec heartbeat(String.t()) :: :ok | :error
  def heartbeat(gateway_id) when is_binary(gateway_id) do
    ProcessRegistry.gateway_heartbeat(gateway_id)
  end

  @doc """
  Update a gateway's registry metadata using a callback.
  """
  @spec update_value(String.t(), (map() -> map()), node()) :: {map(), map()} | :error
  def update_value(gateway_id, callback, node \\ Node.self())
      when is_binary(gateway_id) and is_function(callback, 1) do
    ProcessRegistry.update_value({:gateway, gateway_id, node}, callback)
  end

  @doc """
  Look up a specific gateway in the registry.
  """
  @spec lookup(String.t()) :: [{pid(), map()}]
  def lookup(gateway_id) when is_binary(gateway_id) do
    ProcessRegistry.lookup_gateway(gateway_id)
  end

  @doc """
  Find all gateways.
  """
  @spec find_gateways() :: [map()]
  def find_gateways do
    ProcessRegistry.find_gateways()
  end

  @doc """
  Find all gateways for a specific partition.
  """
  @spec find_gateways_for_partition(String.t()) :: [map()]
  def find_gateways_for_partition(partition_id) do
    find_gateways()
    |> Enum.filter(&(&1[:partition_id] == partition_id))
  end

  @doc """
  Find all gateways for a specific domain.

  Domain represents a logical grouping of gateways, typically by site or location
  (e.g., "site-a", "datacenter-east").
  """
  @spec find_gateways_for_domain(String.t()) :: [map()]
  def find_gateways_for_domain(domain) do
    find_gateways()
    |> Enum.filter(&(&1[:domain] == domain))
  end

  @doc """
  Find an available gateway for a domain.

  Returns `{:ok, metadata}` if found, `{:error, :no_available_gateway}` otherwise.
  """
  @spec find_available_gateway_for_domain(String.t()) ::
          {:ok, map()} | {:error, :no_available_gateway}
  def find_available_gateway_for_domain(domain) do
    gateways = find_gateways_for_domain(domain)

    case Enum.find(gateways, &(&1[:status] == :available)) do
      nil -> {:error, :no_available_gateway}
      gateway -> {:ok, gateway}
    end
  end

  @doc """
  Find an available gateway for a partition.

  Returns `{:ok, metadata}` if found, `{:error, :no_available_gateway}` otherwise.
  """
  @spec find_available_gateway_for_partition(String.t()) ::
          {:ok, map()} | {:error, :no_available_gateway}
  def find_available_gateway_for_partition(partition_id) do
    gateways = find_gateways_for_partition(partition_id)

    case Enum.find(gateways, &(&1[:status] == :available)) do
      nil -> {:error, :no_available_gateway}
      gateway -> {:ok, gateway}
    end
  end

  @doc """
  Find all available gateways.
  """
  @spec find_available_gateways() :: [map()]
  def find_available_gateways do
    ProcessRegistry.find_available_gateways()
  end

  @doc """
  Get all registered gateways.
  """
  @spec all_gateways() :: [map()]
  def all_gateways do
    find_gateways()
  end

  @doc """
  Count of registered gateways.
  """
  @spec count() :: non_neg_integer()
  def count do
    ProcessRegistry.count_by_type(:gateway)
  end
end
