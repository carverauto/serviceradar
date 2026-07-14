defmodule ServiceRadar.Plugins.Validations.NoDuplicateEnabledAssignment do
  @moduledoc """
  Prevents an agent from receiving two enabled assignments for the same plugin.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    enabled = changed_or_current(changeset, :enabled)

    if enabled == false do
      :ok
    else
      reject_duplicate_enabled_assignment(changeset)
    end
  end

  defp reject_duplicate_enabled_assignment(changeset) do
    agent_uid = changed_or_current(changeset, :agent_uid)
    partition_id = changed_or_current(changeset, :partition_id)

    package_id = changed_or_current(changeset, :plugin_package_id)

    current_id = Map.get(changeset.data, :id)

    with false <- blank?(agent_uid),
         {:ok, plugin_id} <- load_plugin_id(package_id),
         false <- blank?(partition_id),
         {:ok, assignments} <- enabled_assignments(partition_id, agent_uid, plugin_id) do
      assignments
      |> Enum.reject(&(current_id && &1.id == current_id))
      |> case do
        [] ->
          :ok

        [%PluginAssignment{} | _] ->
          {:error, field: :plugin_package_id, message: "plugin is already enabled for this agent"}
      end
    else
      true ->
        :ok

      {:error, :package_not_found} ->
        :ok

      {:error, _reason} ->
        {:error, field: :plugin_package_id, message: "plugin assignment lookup failed"}
    end
  end

  defp load_plugin_id(nil), do: {:error, :missing_package}

  defp load_plugin_id(package_id) do
    actor = SystemActor.system(:plugin_assignment_validation)

    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %PluginPackage{plugin_id: plugin_id}} -> {:ok, plugin_id}
      {:ok, nil} -> {:error, :package_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp enabled_assignments(partition_id, agent_uid, plugin_id) do
    actor = SystemActor.system(:plugin_assignment_validation)

    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      partition_id == ^partition_id and agent_uid == ^agent_uid and plugin_id == ^plugin_id and
        enabled == true
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
