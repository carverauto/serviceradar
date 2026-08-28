defmodule ServiceRadar.Plugins.Validations.NoDuplicateEnabledAssignment do
  @moduledoc """
  Prevents an agent from receiving two enabled assignments for the same plugin.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query
  require Logger

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

      {:error, reason} ->
        log_lookup_failure(reason)
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
      {:ok, %PluginPackage{plugin_id: plugin_id}} ->
        {:ok, plugin_id}

      {:ok, nil} ->
        {:error, :package_not_found}

      {:error, error} ->
        if not_found_error?(error), do: {:error, :package_not_found}, else: {:error, error}
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
    |> case do
      {:ok, assignments} -> {:ok, assignments}
      {:error, error} -> if not_found_error?(error), do: {:ok, []}, else: {:error, error}
    end
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &not_found_error?/1)
  end

  defp not_found_error?(_error), do: false

  defp log_lookup_failure(%struct{}),
    do:
      Logger.warning("NoDuplicateEnabledAssignment: plugin assignment lookup failed",
        error: inspect(struct)
      )

  defp log_lookup_failure(reason) do
    Logger.warning("NoDuplicateEnabledAssignment: plugin assignment lookup failed",
      error: inspect(reason)
    )
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
