defmodule ServiceRadar.Inventory.Validations.AgentManaged do
  @moduledoc """
  Prevents agent-backed devices from being marked unmanaged.
  """

  use Ash.Resource.Validation

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    case {agent_id(changeset), Ash.Changeset.get_attribute(changeset, :is_managed)} do
      {agent_id, false} when is_binary(agent_id) and agent_id != "" ->
        {:error, field: :is_managed, message: "Agent devices must remain managed"}

      _ ->
        :ok
    end
  end

  defp agent_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :agent_id) || changeset.data.agent_id
  end
end
