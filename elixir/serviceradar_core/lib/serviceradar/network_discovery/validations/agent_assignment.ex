defmodule ServiceRadar.NetworkDiscovery.Validations.AgentAssignment do
  @moduledoc """
  Ensures mapper jobs reference a known agent in the selected partition.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    agent_id =
      Ash.Changeset.get_attribute(changeset, :agent_id) ||
        Map.get(changeset.data, :agent_id)

    agent_id = normalize_agent_id(agent_id)

    if is_nil(agent_id) do
      :ok
    else
      partition =
        Ash.Changeset.get_attribute(changeset, :partition) ||
          Map.get(changeset.data, :partition) || "default"

      actor = SystemActor.system(:mapper_job_agent_validation)

      Agent
      |> Ash.Query.for_read(:by_uid, %{uid: agent_id})
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %Agent{} = agent} ->
          agent_partition = Map.get(agent.metadata || %{}, "partition_id") || "default"

          if agent_partition == partition do
            :ok
          else
            {:error,
             field: :agent_id,
             message:
               "agent '#{agent_id}' belongs to partition '#{agent_partition}', not '#{partition}'"}
          end

        {:ok, nil} ->
          {:error, field: :agent_id, message: "agent '#{agent_id}' not found"}

        {:error, _reason} ->
          {:error, field: :agent_id, message: "agent lookup failed"}
      end
    end
  end

  defp normalize_agent_id(nil), do: nil

  defp normalize_agent_id(agent_id) when is_binary(agent_id) do
    trimmed = String.trim(agent_id)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_agent_id(agent_id), do: to_string(agent_id)
end
