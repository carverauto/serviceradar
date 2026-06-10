defmodule ServiceRadar.Plugins.Validations.NoDuplicateEnabledAddonAssignment do
  @moduledoc """
  Prevents an agent from receiving two enabled assignments for the same add-on.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    source = changed_or_current(changeset, :source) || :manual

    if changed_or_current(changeset, :enabled) == false or source != :manual do
      :ok
    else
      reject_duplicate_enabled_assignment(changeset)
    end
  end

  defp reject_duplicate_enabled_assignment(changeset) do
    agent_uid = changed_or_current(changeset, :agent_uid)
    package_id = changed_or_current(changeset, :addon_package_id)
    current_id = Map.get(changeset.data, :id)

    with false <- blank?(agent_uid),
         {:ok, addon_id} <- load_addon_id(package_id),
         {:ok, assignments} <- enabled_assignments(agent_uid, addon_id) do
      assignments
      |> Enum.reject(&(current_id && &1.id == current_id))
      |> case do
        [] ->
          :ok

        [%AddonAssignment{} | _] ->
          {:error, field: :addon_package_id, message: "add-on is already enabled for this agent"}
      end
    else
      true ->
        :ok

      {:error, :package_not_found} ->
        :ok

      {:error, _reason} ->
        {:error, field: :addon_package_id, message: "add-on assignment lookup failed"}
    end
  end

  defp load_addon_id(nil), do: {:error, :missing_package}

  defp load_addon_id(package_id) do
    actor = SystemActor.system(:addon_assignment_validation)

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %AddonPackage{addon_id: addon_id}} -> {:ok, addon_id}
      {:ok, nil} -> {:error, :package_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp enabled_assignments(agent_uid, addon_id) do
    actor = SystemActor.system(:addon_assignment_validation)

    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and addon_id == ^addon_id and enabled == true and source == :manual
    )
    |> Ash.read(actor: actor)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp changed_or_current(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> Map.get(changeset.data, attribute)
      value -> value
    end
  end
end
