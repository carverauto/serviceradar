defmodule ServiceRadar.SNMPProfiles.Changes.SetAsDefault do
  @moduledoc """
  Ensures only one default SNMP profile exists.

  Before setting a profile as default, this change finds and unsets
  any existing default profile using the :unset_default action.

  In single-deployment architecture, the DB connection's
  search_path determines which schema is affected.
  """

  use Ash.Resource.Change

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @impl true
  def change(changeset, _opts, _context) do
    current_id = Ash.Changeset.get_data(changeset, :id)

    # Use SystemActor for the unset operation
    system_actor = SystemActor.system(:snmp_profile_default)

    # Find and unset any existing default profile (excluding the current one)
    unset_other_defaults(current_id, system_actor)

    # Set the current profile as default
    Ash.Changeset.change_attribute(changeset, :is_default, true)
  end

  defp unset_other_defaults(current_id, actor) do
    _ = actor
    now = DateTime.truncate(DateTime.utc_now(), :second)

    query =
      from(p in SNMPProfile,
        where: p.is_default == true and p.id != ^current_id
      )

    Repo.update_all(query, [set: [is_default: false, updated_at: now]], prefix: "platform")

    :ok
  end
end
