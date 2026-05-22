defmodule ServiceRadar.Dashboards.Checks.CreatingOwnDashboardPreference do
  @moduledoc """
  Verifies a user is creating a dashboard preference for themselves.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is creating their own dashboard preference"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) when not is_nil(actor) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    actor_id = Map.get(actor, :id)

    actor_id && user_id && to_string(actor_id) == to_string(user_id)
  end

  def match?(_actor, _context, _opts), do: false
end
