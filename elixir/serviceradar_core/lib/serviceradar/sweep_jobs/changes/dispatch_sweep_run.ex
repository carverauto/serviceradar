defmodule ServiceRadar.SweepJobs.Changes.DispatchSweepRun do
  @moduledoc """
  Dispatches an on-demand sweep run over the agent command bus.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      case AgentCommandBus.run_sweep_group(record) do
        {:ok, _command_id} -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
