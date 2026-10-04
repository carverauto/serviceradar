defmodule ServiceRadar.Plugins.Validations.NoDuplicateAddonProfileTarget do
  @moduledoc """
  Rejects a second enabled profile for the same add-on with the same target
  query.

  Profiles are priority-layered: several enabled profiles may target one
  add-on, and each agent gets the highest-precedence assignment. That layering
  only means something when the target queries differ. Two enabled profiles
  with an identical query select exactly the same agents, so the lower-priority
  one never delivers anything. It still reconciles its own assignment rows and
  starts its own rollouts for the same agents, which is how several profiles
  for one add-on ended up fighting over the fleet (GitHub #4453). The usual way
  in is creating a profile on a new version's page while the existing profile is
  pinned to an older version; the fix there is to edit that profile.

  Only transitions into the conflicting state are checked (create, enabling, or
  changing the add-on or query of an enabled profile), so duplicates that
  already exist keep working until an operator resolves them.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonProfile

  require Ash.Query

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "duplicate add-on profile target validation requires a row read"}

  @impl true
  def validate(changeset, _opts, _context) do
    addon_id = changed_or_current(changeset, :addon_id)
    target_query = changed_or_current(changeset, :target_query)

    if entering_enabled_target?(changeset) and is_binary(addon_id) and is_binary(target_query) do
      reject_duplicate(addon_id, normalize(target_query), Map.get(changeset.data, :id))
    else
      :ok
    end
  end

  defp entering_enabled_target?(changeset) do
    enabled? = changed_or_current(changeset, :enabled) != false

    case changeset.action_type do
      :create ->
        enabled?

      _ ->
        enabled? and
          Enum.any?(
            [:enabled, :addon_id, :target_query],
            &Ash.Changeset.changing_attribute?(changeset, &1)
          )
    end
  end

  defp reject_duplicate(addon_id, target_query, current_id) do
    case enabled_profiles(addon_id) do
      {:ok, profiles} ->
        profiles
        |> Enum.reject(&(current_id && &1.id == current_id))
        |> Enum.find(&(normalize(&1.target_query) == target_query))
        |> case do
          nil ->
            :ok

          %AddonProfile{} = existing ->
            {:error,
             field: :target_query,
             message:
               "enabled profile \"#{existing.name}\" (#{existing.id}) already targets " <>
                 "#{inspect(target_query)} for add-on \"#{addon_id}\"; edit that profile, " <>
                 "or disable it first"}
        end

      {:error, _reason} ->
        {:error, field: :target_query, message: "add-on profile lookup failed"}
    end
  end

  defp enabled_profiles(addon_id) do
    AddonProfile
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(addon_id == ^addon_id and enabled == true)
    |> Ash.read(actor: SystemActor.system(:addon_profile_validation))
  end

  # The stored query has already been through NormalizeAddonProfileTargetQuery;
  # whitespace is the only remaining difference between equivalent spellings
  # that this check can safely treat as equal.
  defp normalize(nil), do: nil
  defp normalize(query), do: query |> String.split() |> Enum.join(" ")

  defp changed_or_current(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> Map.get(changeset.data, attribute)
      value -> value
    end
  end
end
