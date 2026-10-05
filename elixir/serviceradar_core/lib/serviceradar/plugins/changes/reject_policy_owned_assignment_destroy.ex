defmodule ServiceRadar.Plugins.Changes.RejectPolicyOwnedAssignmentDestroy do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor

  @impl true
  def change(changeset, _opts, context) do
    if policy_owned?(changeset.data) and not SystemActor.system_actor?(Map.get(context, :actor)) do
      Ash.Changeset.add_error(changeset,
        field: :source,
        message: "policy-owned assignments may only be changed by a trusted system process"
      )
    else
      changeset
    end
  end

  defp policy_owned?(%{source: source}), do: source in [:policy, "policy"]
  defp policy_owned?(_assignment), do: false
end
