defmodule ServiceRadar.Infrastructure.Changes.RevokeEdgeOutputGrants do
  @moduledoc """
  Revokes the agent's standing edge output grants in the same transaction as the update
  (`ServiceRadar.Edge.OutputGrants.revoke_agent/1`), so a superseded identity's records are
  fenced at the gateway's next trust refresh instead of staying admissible until the grant
  expires. `Infrastructure.Agent` `:supersede` is the only way into `:superseded`, so this
  change on that action covers every writer.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.OutputGrants

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, agent ->
      case OutputGrants.revoke_agent(agent.uid) do
        {:ok, _count} -> {:ok, agent}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
