defmodule ServiceRadar.SNMPProfiles.Changes.CheckTargetLimit do
  @moduledoc """
  Refuses to save an enabled SNMP profile that selects more targets than one
  agent may be given. See `ServiceRadar.SNMPProfiles.TargetLimit`.

  A disabled profile is not judged, so a profile that grew past the limit can
  always be disabled.

  The count runs when the action is submitted, before its transaction opens.
  Counting reads the inventory with the profile's own target query, and a read
  that fails inside the action's transaction would roll the save back: a
  target query with a filter value that cannot be cast must stay saveable, as
  it matches nothing.
  """

  use Ash.Resource.Change

  alias ServiceRadar.SNMPProfiles.TargetLimit

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, &check/1)
  end

  defp check(changeset) do
    if Ash.Changeset.get_attribute(changeset, :enabled) do
      profile = %{
        id: changeset.data.id,
        name: Ash.Changeset.get_attribute(changeset, :name),
        target_query: Ash.Changeset.get_attribute(changeset, :target_query),
        is_default: Ash.Changeset.get_attribute(changeset, :is_default),
        agent_ids: Ash.Changeset.get_attribute(changeset, :agent_ids)
      }

      case TargetLimit.refusals(profile) do
        [] ->
          changeset

        [refusal | _] ->
          Ash.Changeset.add_error(changeset,
            field: :target_query,
            message: TargetLimit.message(refusal)
          )
      end
    else
      changeset
    end
  end
end
