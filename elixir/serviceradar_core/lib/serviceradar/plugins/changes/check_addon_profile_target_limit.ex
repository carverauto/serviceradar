defmodule ServiceRadar.Plugins.Changes.CheckAddonProfileTargetLimit do
  @moduledoc """
  Refuses to save an enabled add-on profile whose target query selects more
  agents than its `max_targets`, with the count reconciliation uses
  (`ServiceRadar.Plugins.AddonProfileReconciler.check_target_limit/2`).

  The profile is judged when it is created, and when an update changes its
  target query, its `max_targets` or whether it is enabled. A disabled profile
  is not judged, so a profile that grew past its limit can always be disabled;
  one that grows past it after it was saved is refused by reconciliation.

  The count runs before the action's transaction opens. A read that fails
  refuses nothing: reconciliation reads the query again and reports the
  failure on the profile.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Plugins.AddonProfileReconciler

  @judged_attributes [:target_query, :max_targets, :enabled]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, &check/1)
  end

  defp check(changeset) do
    if changeset.valid? and judged?(changeset) do
      profile = %{
        id: Ash.Changeset.get_attribute(changeset, :id),
        name: Ash.Changeset.get_attribute(changeset, :name),
        target_query: Ash.Changeset.get_attribute(changeset, :target_query),
        max_targets: Ash.Changeset.get_attribute(changeset, :max_targets)
      }

      case AddonProfileReconciler.check_target_limit(profile) do
        {:refused, refusal} ->
          Ash.Changeset.add_error(changeset, field: :target_query, message: refusal.message)

        _within_limit_or_unreadable ->
          changeset
      end
    else
      changeset
    end
  end

  defp judged?(changeset) do
    Ash.Changeset.get_attribute(changeset, :enabled) == true and
      (changeset.action_type == :create or
         Enum.any?(@judged_attributes, &Ash.Changeset.changing_attribute?(changeset, &1)))
  end
end
