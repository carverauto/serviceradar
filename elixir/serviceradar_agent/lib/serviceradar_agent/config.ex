defmodule ServiceRadarAgent.Config do
  @moduledoc """
  Configuration store for the agent.

  Stores runtime configuration that can be queried by other agent components.
  """

  use GenServer

  @type config :: %{
          partition_id: String.t(),
          agent_id: String.t(),
          poller_id: String.t() | nil,
          capabilities: [atom()]
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: config()
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @spec partition_id() :: String.t()
  def partition_id do
    GenServer.call(__MODULE__, :partition_id)
  end

  @spec agent_id() :: String.t()
  def agent_id do
    GenServer.call(__MODULE__, :agent_id)
  end

  @spec poller_id() :: String.t() | nil
  def poller_id do
    GenServer.call(__MODULE__, :poller_id)
  end

  @spec capabilities() :: [atom()]
  def capabilities do
    GenServer.call(__MODULE__, :capabilities)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    config = %{
      partition_id: Keyword.fetch!(opts, :partition_id),
      agent_id: Keyword.fetch!(opts, :agent_id),
      poller_id: Keyword.get(opts, :poller_id),
      capabilities: Keyword.get(opts, :capabilities, [])
    }

    {:ok, config}
  end

  @impl true
  def handle_call(:get, _from, config) do
    {:reply, config, config}
  end

  def handle_call(:partition_id, _from, config) do
    {:reply, config.partition_id, config}
  end

  def handle_call(:agent_id, _from, config) do
    {:reply, config.agent_id, config}
  end

  def handle_call(:poller_id, _from, config) do
    {:reply, config.poller_id, config}
  end

  def handle_call(:capabilities, _from, config) do
    {:reply, config.capabilities, config}
  end
end
