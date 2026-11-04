defmodule ServiceRadar.Infrastructure.Calculations.EdgePipelineConditions do
  @moduledoc """
  An agent's edge pipeline conditions (`ServiceRadar.Edge.PipelineReadiness.conditions/2`):
  each reason that keeps it off the durable edge-record pipeline, empty for a ready agent.
  The installation state is read once per batch of agents.
  """

  use Ash.Resource.Calculation

  alias ServiceRadar.Edge.PipelineReadiness

  @impl true
  def load(_query, _opts, _context), do: [:device]

  @impl true
  def calculate(agents, _opts, _context) do
    with {:ok, facts} <- PipelineReadiness.facts() do
      {:ok, Enum.map(agents, &PipelineReadiness.conditions(&1, facts))}
    end
  end
end
