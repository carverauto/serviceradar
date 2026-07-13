defmodule ServiceRadar.Plugins.Validations.SingleEnabledAddonProfile do
  @moduledoc """
  Rejects enabling a second add-on profile for exclusive add-ons.

  The anomaly add-on treats its enabled profile as the deployment-wide config
  carrier: `AnomalyAddonConfigProjector` and `EdgeBaselineProducer` write
  operator settings and seasonal baselines into every enabled anomaly profile,
  while each agent receives exactly one effective assignment per add-on. Two
  enabled anomaly profiles with different params therefore make the delivered
  edge config ambiguous. Other add-ons keep priority-layered multi-profile
  targeting, so the rule is scoped to the exclusive add-on list.

  This validation is the friendly-error first line; the invariant itself is
  enforced under concurrency by the partial unique index
  `addon_profiles_single_enabled_anomaly_index` (migration 20260713010000).
  Keep `@exclusive_addon_ids` in sync with that index's predicate.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonProfile

  require Ash.Query

  @exclusive_addon_ids ["anomaly"]

  # Returning `:ok` here would tell Ash the validation PASSES atomically,
  # letting atomic/bulk updates enable a duplicate profile unchecked. The check
  # needs a cross-row read, so force the fallback to the non-atomic path where
  # `validate/3` runs (`:update` on AddonProfile sets `require_atomic? false`).
  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "single enabled anomaly profile validation requires a row read"}

  @impl true
  def validate(changeset, _opts, _context) do
    if enabling?(changeset) do
      reject_duplicate_enabled_profile(changeset)
    else
      :ok
    end
  end

  # Only transitions into the enabled state (or moving an enabled profile onto
  # another add-on) are enforced, so unrelated updates to profiles that already
  # coexist in legacy data keep working until an operator resolves the overlap.
  defp enabling?(changeset) do
    enabled? = changed_or_current(changeset, :enabled) == true

    case changeset.action_type do
      :create ->
        enabled?

      _ ->
        enabled? and
          (Ash.Changeset.changing_attribute?(changeset, :enabled) or
             Ash.Changeset.changing_attribute?(changeset, :addon_id))
    end
  end

  defp reject_duplicate_enabled_profile(changeset) do
    addon_id = changed_or_current(changeset, :addon_id)
    current_id = Map.get(changeset.data, :id)

    if is_binary(addon_id) and addon_id in @exclusive_addon_ids do
      case other_enabled_profiles(addon_id, current_id) do
        {:ok, []} ->
          :ok

        {:ok, [%AddonProfile{} = existing | _]} ->
          {:error,
           field: :enabled,
           message:
             "only one enabled add-on profile is allowed for add-on \"#{addon_id}\"; " <>
               "disable profile \"#{existing.name}\" (#{existing.id}) first"}

        {:error, _reason} ->
          {:error, field: :enabled, message: "add-on profile lookup failed"}
      end
    else
      :ok
    end
  end

  defp other_enabled_profiles(addon_id, current_id) do
    actor = SystemActor.system(:addon_profile_validation)

    AddonProfile
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(addon_id == ^addon_id and enabled == true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, profiles} -> {:ok, Enum.reject(profiles, &(current_id && &1.id == current_id))}
      {:error, error} -> {:error, error}
    end
  end

  defp changed_or_current(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> Map.get(changeset.data, attribute)
      value -> value
    end
  end
end
