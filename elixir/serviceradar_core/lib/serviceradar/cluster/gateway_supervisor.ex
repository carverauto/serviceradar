defmodule ServiceRadar.GatewaySupervisor do
  @moduledoc """
  Distributed dynamic supervisor for gateway-related processes.

  Uses Horde.DynamicSupervisor to distribute processes across the cluster.
  Processes are automatically redistributed when nodes join or leave.

  ## Starting Processes

  Processes started under this supervisor are distributed across the cluster:

      ServiceRadar.GatewaySupervisor.start_child({MyWorker, arg})

  If the node hosting the process goes down, Horde will restart it on
  another available node.
  """

  use Horde.DynamicSupervisor

  def start_link(opts) do
    Horde.DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    [
      strategy: :one_for_one,
      members: :auto
    ]
    |> Keyword.merge(opts)
    |> Horde.DynamicSupervisor.init()
  end

  @doc """
  Start a child process under the distributed supervisor.
  """
  @spec start_child(Supervisor.child_spec() | {module(), term()}) ::
          DynamicSupervisor.on_start_child()
  def start_child(child_spec) do
    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Terminate a child process.
  """
  @spec terminate_child(pid()) :: :ok | {:error, :not_found}
  def terminate_child(pid) do
    Horde.DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Get all children across the cluster.
  """
  @spec which_children() :: [{:undefined, pid() | :restarting, :worker | :supervisor, [module()]}]
  def which_children do
    Horde.DynamicSupervisor.which_children(__MODULE__)
  end

  @doc """
  Count of children across the cluster.
  """
  @spec count_children() :: map()
  def count_children do
    Horde.DynamicSupervisor.count_children(__MODULE__)
  end
end
