defmodule ServiceRadar.Identity.ApiToken.Checks.CreatingOwnToken do
  @moduledoc """
  Custom policy check to verify a user is creating an API token for themselves.

  This check is needed because create actions cannot use expr() filters that
  reference the record's attributes - the record doesn't exist yet. Instead,
  we examine the changeset to verify the user_id being set matches the actor.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor is creating a token for themselves"
  end

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) when not is_nil(actor) do
    # Get the user_id being set in the changeset
    setting_user_id = Ash.Changeset.get_attribute(changeset, :user_id)

    # Check if it matches the actor's id
    actor_id = Map.get(actor, :id)

    actor_id && setting_user_id && to_string(actor_id) == to_string(setting_user_id)
  end

  def match?(_, _, _), do: false
end
