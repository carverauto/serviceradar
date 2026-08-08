defmodule ServiceRadar.Plugins.Changes.ApplyAddonUpdatePolicyDefaults do
  @moduledoc """
  Defaults verified first-party native add-on sources to managed updates while
  preserving explicit pins and conservative defaults for other provenance.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRolloutPolicy

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> apply_create_default()
    |> record_explicit_policy_choice()
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp apply_create_default(%{action_type: :create} = changeset) do
    case load_package(package_id(changeset)) do
      %AddonPackage{} = package ->
        apply_package_defaults(changeset, package)

      _package ->
        apply_manual_defaults(changeset)
    end
  end

  defp apply_create_default(changeset), do: changeset

  defp apply_package_defaults(changeset, package) do
    default_policy =
      if trusted_first_party?(package), do: :track_latest_approved, else: :manual_pin

    changeset
    |> change_default_attribute(:update_policy, default_policy)
    |> change_default_attribute(
      :capability_ceiling,
      package.approved_capabilities || []
    )
    |> change_default_attribute(:rollout_policy, AddonRolloutPolicy.defaults())
  end

  defp apply_manual_defaults(changeset) do
    changeset
    |> change_default_attribute(:update_policy, :manual_pin)
    |> change_default_attribute(:rollout_policy, AddonRolloutPolicy.defaults())
  end

  defp change_default_attribute(changeset, attribute, value) do
    if param_provided?(changeset, attribute) do
      changeset
    else
      Ash.Changeset.change_attribute(changeset, attribute, value)
    end
  end

  defp record_explicit_policy_choice(changeset) do
    if param_provided?(changeset, :update_policy) do
      explicit_pin? = Ash.Changeset.get_attribute(changeset, :update_policy) == :manual_pin
      Ash.Changeset.change_attribute(changeset, :explicit_version_pin, explicit_pin?)
    else
      changeset
    end
  end

  defp param_provided?(changeset, attribute) do
    params = changeset.params || %{}
    Map.has_key?(params, attribute) or Map.has_key?(params, Atom.to_string(attribute))
  end

  defp package_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :addon_package_id) ||
      Map.get(changeset.data, :addon_package_id)
  end

  defp load_package(nil), do: nil

  defp load_package(package_id) do
    actor = SystemActor.system(:addon_update_policy_defaults)

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %AddonPackage{} = package} -> package
      _ -> nil
    end
  end

  defp trusted_first_party?(%AddonPackage{} = package) do
    package.source_type == :first_party and package.status == :approved and
      package.verification_status == "verified" and is_nil(package.verification_error)
  end
end
