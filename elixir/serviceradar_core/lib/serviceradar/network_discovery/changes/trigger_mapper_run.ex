defmodule ServiceRadar.NetworkDiscovery.Changes.TriggerMapperRun do
  @moduledoc """
  Dispatches an on-demand mapper run over the agent command bus.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.after_action(fn changeset, record ->
      actor = get_actor(changeset)

      case AgentCommandBus.run_mapper_job(record, actor: actor) do
        {:ok, _command_id} -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp get_actor(%Ash.Changeset{context: %{private: %{actor: actor}}}), do: actor
  defp get_actor(%Ash.Changeset{context: %{actor: actor}}), do: actor
  defp get_actor(_), do: nil
end
