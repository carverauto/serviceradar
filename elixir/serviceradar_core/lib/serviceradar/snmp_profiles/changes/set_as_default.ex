defmodule ServiceRadar.SNMPProfiles.Changes.SetAsDefault do
  @moduledoc """
  Ensures only one default SNMP profile exists per tenant.

  Before setting a profile as default, this change finds and unsets
  any existing default profile for the tenant using the :unset_default action.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @impl true
  def change(changeset, _opts, _context) do
    tenant = changeset.tenant
    current_id = Ash.Changeset.get_data(changeset, :id)

    # Use SystemActor for the unset operation (never authorize?: false per CLAUDE.md)
    system_actor = SystemActor.for_tenant(extract_tenant_id(tenant), :snmp_profile_default)

    # Find and unset any existing default profile (excluding the current one)
    unset_other_defaults(tenant, current_id, system_actor)

    # Set the current profile as default
    Ash.Changeset.change_attribute(changeset, :is_default, true)
  end

  defp unset_other_defaults(tenant, current_id, actor) do
    # Query for existing default profiles, excluding the current one
    query =
      SNMPProfile
      |> Ash.Query.filter(is_default == true)
      |> Ash.Query.filter(id != ^current_id)
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)

    case Ash.read(query, actor: actor) do
      {:ok, profiles} ->
        # Unset each default profile using the dedicated action
        Enum.each(profiles, fn profile ->
          profile
          |> Ash.Changeset.for_update(:unset_default, %{}, actor: actor, tenant: tenant)
          |> Ash.update(actor: actor)
        end)

      {:error, error} ->
        # Log but don't fail - the system should continue and we'll have multiple defaults
        # which is still better than crashing
        require Logger
        Logger.warning("Failed to query existing default SNMP profiles: #{inspect(error)}")
        :ok
    end
  end

  defp extract_tenant_id(tenant) when is_binary(tenant) do
    # Tenant schema format is "tenant_<id>", extract the ID
    case String.split(tenant, "_", parts: 2) do
      ["tenant", id] -> id
      _ -> tenant
    end
  end

  defp extract_tenant_id(tenant), do: tenant
end
