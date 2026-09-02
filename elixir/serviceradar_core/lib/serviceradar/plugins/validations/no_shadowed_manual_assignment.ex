defmodule ServiceRadar.Plugins.Validations.NoShadowedManualAssignment do
  @moduledoc """
  Prevents manual plugin assignments from duplicating policy-owned assignments.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment

  require Ash.Query
  require Logger

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    source = Ash.Changeset.get_attribute(changeset, :source) || :manual

    if source == :manual do
      reject_shadowed_manual_assignment(changeset)
    else
      :ok
    end
  end

  defp reject_shadowed_manual_assignment(changeset) do
    agent_uid = Ash.Changeset.get_attribute(changeset, :agent_uid)
    partition_id = Ash.Changeset.get_attribute(changeset, :partition_id)
    plugin_package_id = Ash.Changeset.get_attribute(changeset, :plugin_package_id)

    if blank?(agent_uid) or blank?(partition_id) or is_nil(plugin_package_id) do
      :ok
    else
      actor = SystemActor.system(:plugin_assignment_validation)

      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        partition_id == ^partition_id and agent_uid == ^agent_uid and
          plugin_package_id == ^plugin_package_id and source == :policy and enabled == true
      )
      |> Ash.Query.limit(1)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %PluginAssignment{}} ->
          {:error,
           field: :plugin_package_id,
           message: "plugin is already assigned to this agent by policy"}

        {:ok, nil} ->
          :ok

        {:error, %NotFound{}} ->
          :ok

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          if Enum.any?(errors, &match?(%NotFound{}, &1)) do
            :ok
          else
            log_lookup_failure(errors)
            {:error, field: :plugin_package_id, message: "plugin assignment lookup failed"}
          end

        {:error, reason} ->
          log_lookup_failure(reason)
          {:error, field: :plugin_package_id, message: "plugin assignment lookup failed"}
      end
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp log_lookup_failure(%struct{}),
    do:
      Logger.warning("NoShadowedManualAssignment: plugin assignment lookup failed",
        error: inspect(struct)
      )

  defp log_lookup_failure(reason) do
    Logger.warning("NoShadowedManualAssignment: plugin assignment lookup failed",
      error: inspect(reason)
    )
  end
end
