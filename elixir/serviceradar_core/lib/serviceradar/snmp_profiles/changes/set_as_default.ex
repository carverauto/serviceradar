defmodule ServiceRadar.SNMPProfiles.Changes.SetAsDefault do
  @moduledoc """
  Ensures only one default SNMP profile exists.

  Before setting a profile as default, this change finds and unsets
  any existing default profile using the :unset_default action.

  In single-tenant-per-deployment architecture, the DB connection's
  search_path determines which schema is affected.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
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
    # Query for existing default profiles, excluding the current one
    query =
      SNMPProfile
      |> Ash.Query.filter(is_default == true)
      |> Ash.Query.filter(id != ^current_id)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, profiles} ->
        # Unset all default profiles in a single bulk operation
        Ash.bulk_update(profiles, :unset_default, %{}, actor: actor)

      {:error, error} ->
        # Log but don't fail - the system should continue and we'll have multiple defaults
        # which is still better than crashing
        require Logger
        Logger.warning("Failed to query existing default SNMP profiles: #{inspect(error)}")
        :ok
    end
  end

end
