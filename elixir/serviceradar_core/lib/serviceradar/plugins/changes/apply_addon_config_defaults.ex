defmodule ServiceRadar.Plugins.Changes.ApplyAddonConfigDefaults do
  @moduledoc """
  Applies add-on config schema defaults and type normalization to add-on
  assignment params before validation and persistence.

  Native add-on assignment params arrive from the LiveView form with every value
  as a string — arrays as comma/newline text, booleans as "true"/"false", numbers
  as text. Unlike the Wasm-plugin path (where the web context sets
  `:config_schema` in the changeset context and `ApplyConfigDefaults` reads it),
  the add-on context module does not, so this change self-loads the package's
  config schema from `addon_package_id` and normalizes before the
  `AddonAssignmentParams` validation runs. Mirrors
  `ServiceRadar.Plugins.Changes.ApplyConfigDefaults`, but does not depend on the
  caller populating the changeset context — so it also covers policy-driven and
  seeder assignment paths.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.ConfigSchema

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    case resolve_schema(changeset) do
      %{} = schema when map_size(schema) > 0 ->
        params =
          Ash.Changeset.get_attribute(changeset, :params) ||
            Map.get(changeset.data, :params) || %{}

        params = inherit_active_netprobe_profile_default(changeset, params)
        normalized = ConfigSchema.normalize_params(schema, params)
        Ash.Changeset.change_attribute(changeset, :params, normalized)

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  # Prefer a schema the caller already resolved into context; otherwise load it.
  defp resolve_schema(changeset) do
    case Map.get(changeset.context, :config_schema) do
      %{} = schema when map_size(schema) > 0 -> schema
      _ -> load_schema(package_id(changeset))
    end
  end

  defp package_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :addon_package_id) ||
      Map.get(changeset.data, :addon_package_id)
  end

  defp load_schema(nil), do: %{}

  defp load_schema(package_id) do
    actor = SystemActor.system(:addon_assignment_config_defaults)

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %AddonPackage{config_schema: schema}} -> schema || %{}
      _ -> %{}
    end
  end

  # Netprobe profile creation is the operator's host-visibility opt-in. An active profile
  # with no explicit runtime switch must not normalize to the schema's disabled default;
  # explicit false remains available for install-but-idle workflows.
  defp inherit_active_netprobe_profile_default(changeset, params) when is_map(params) do
    addon_id = changeset_attribute(changeset, :addon_id)
    enabled = changeset_attribute(changeset, :enabled)

    profile? = changeset.resource == ServiceRadar.Plugins.AddonProfile
    enabled_present? = Map.has_key?(params, "enabled") or Map.has_key?(params, :enabled)

    if profile? and addon_id == "netprobe" and enabled != false and not enabled_present? do
      Map.put(params, "enabled", true)
    else
      params
    end
  end

  defp inherit_active_netprobe_profile_default(_changeset, params), do: params

  defp changeset_attribute(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> Map.get(changeset.data, attribute)
      value -> value
    end
  end
end
