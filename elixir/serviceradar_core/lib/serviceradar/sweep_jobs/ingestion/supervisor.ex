defmodule ServiceRadar.SweepJobs.Ingestion.Supervisor do
  @moduledoc """
  Node-local supervisor for sweep result ingestion workers.

  Started on every core node that handles agent results. It owns the node's
  `:pg` scope and a fixed pool of `ServiceRadar.SweepJobs.Ingestion.Worker`
  processes, so the number of concurrent sweep ingestions on a node is bounded
  by `workers_per_node/0`. The coordinator's dispatcher discovers the workers
  of every node through the scope.

  `rest_for_one`: if the scope restarts, the workers restart after it and join
  the new scope.
  """

  use Supervisor

  alias ServiceRadar.SweepJobs.Ingestion.Worker

  @scope ServiceRadar.SweepJobs.Ingestion.Scope
  @group :sweep_ingestion_workers
  @default_workers_per_node 2

  @doc "The `:pg` scope sweep ingestion workers register in."
  @spec scope() :: atom()
  def scope, do: @scope

  @doc "The `:pg` group sweep ingestion workers join."
  @spec group() :: atom()
  def group, do: @group

  @doc """
  Number of workers this node runs. Configured with

      config :serviceradar_core, sweep_ingestion_workers_per_node: 2

  A value of 0 starts no workers.
  """
  @spec workers_per_node() :: non_neg_integer()
  def workers_per_node do
    case Application.get_env(:serviceradar_core, :sweep_ingestion_workers_per_node) do
      count when is_integer(count) and count >= 0 -> count
      _ -> @default_workers_per_node
    end
  end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    scope = Keyword.get(opts, :scope, @scope)
    group = Keyword.get(opts, :group, @group)
    count = Keyword.get(opts, :workers, workers_per_node())
    worker_opts = Keyword.take(opts, [:processor])

    scope_child = %{id: :pg_scope, start: {:pg, :start_link, [scope]}}

    workers =
      for index <- 1..count//1 do
        {Worker, Keyword.merge(worker_opts, scope: scope, group: group, index: index)}
      end

    Supervisor.init([scope_child | workers], strategy: :rest_for_one)
  end
end
