defmodule ServiceRadar.Plugins.Validations.AddonPackageApproved do
  @moduledoc """
  Ensures native add-on assignments only reference approved add-on packages.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    if changed_or_current(changeset, :enabled) == false do
      :ok
    else
      validate_package_approved(changeset)
    end
  end

  defp validate_package_approved(changeset) do
    package_id =
      Ash.Changeset.get_attribute(changeset, :addon_package_id) ||
        Map.get(changeset.data, :addon_package_id)

    if is_nil(package_id) do
      :ok
    else
      actor = SystemActor.system(:addon_assignment_validation)

      AddonPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^package_id)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %AddonPackage{status: :approved, verification_status: "blob_missing"}} ->
          {:error,
           field: :addon_package_id,
           message: "add-on package artifact is missing from object storage"}

        {:ok, %AddonPackage{status: :approved}} ->
          :ok

        {:ok, %AddonPackage{status: status}} ->
          {:error,
           field: :addon_package_id,
           message: "add-on package must be approved (status: #{status})"}

        {:ok, nil} ->
          {:error, field: :addon_package_id, message: "add-on package not found"}

        {:error, _error} ->
          {:error, field: :addon_package_id, message: "add-on package lookup failed"}
      end
    end
  end

  defp changed_or_current(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> Map.get(changeset.data, attribute)
      value -> value
    end
  end
end
