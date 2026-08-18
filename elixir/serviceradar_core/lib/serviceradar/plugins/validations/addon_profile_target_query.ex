defmodule ServiceRadar.Plugins.Validations.AddonProfileTargetQuery do
  @moduledoc """
  Add-on profiles assign packages to enrolled agents, so the SRQL target must
  be the `agents` entity. Operators may add filters (`in:agents hostname:dusk*`)
  but may not retarget `devices` or any other inventory.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.SRQLAst

  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.action_type == :create or
         Ash.Changeset.changing_attribute?(changeset, :target_query) do
      validate_query(Ash.Changeset.get_attribute(changeset, :target_query))
    else
      :ok
    end
  end

  defp validate_query(query) when is_binary(query) do
    case SRQLAst.entity(String.trim(query), "agents") do
      "agents" ->
        :ok

      entity ->
        {:error,
         field: :target_query,
         message:
           "must target agents (in:agents), not #{entity}. Add filters after in:agents to narrow the set."}
    end
  end

  defp validate_query(_query) do
    {:error, field: :target_query, message: "must target agents (in:agents)"}
  end
end
