defmodule ServiceRadar.Plugins.Changes.ApplyPluginUpdatePolicy do
  @moduledoc """
  Records the update policy of a Wasm plugin assignment owner (a manual
  `PluginAssignment` or a `PluginTargetPolicy`); see
  `ServiceRadar.Plugins.PluginUpdatePolicy`.

  * Creating an owner without an explicit `update_policy` takes the provenance
    default of its package.
  * Supplying `update_policy` is an operator choice: `update_policy_source`
    becomes `:operator`.
  * Moving an owner to a different package without supplying `update_policy`
    is choosing a concrete version: the owner becomes `:pinned`, chosen by the
    operator.

  Policy-materialized assignment rows (`source: :policy`) are written by
  reconcilers on their owner's behalf, so a package change there records
  nothing.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginUpdatePolicy

  require Ash.Query

  @impl true
  def change(%{action_type: :create} = changeset, _opts, _context) do
    cond do
      param_provided?(changeset, :update_policy) ->
        Ash.Changeset.change_attribute(changeset, :update_policy_source, :operator)

      owner?(changeset) ->
        Ash.Changeset.change_attribute(
          changeset,
          :update_policy,
          changeset |> package_id() |> load_package() |> PluginUpdatePolicy.default_for()
        )

      true ->
        changeset
    end
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attributes(changeset, update_changes(changeset))
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case update_changes(changeset) do
      changes when map_size(changes) == 0 -> :ok
      changes -> {:atomic, changes}
    end
  end

  defp update_changes(changeset) do
    cond do
      param_provided?(changeset, :update_policy) ->
        %{update_policy_source: :operator}

      owner?(changeset) and package_changed?(changeset) ->
        %{update_policy: :pinned, update_policy_source: :operator}

      true ->
        %{}
    end
  end

  # PluginAssignment actions are never atomic, so the cast source is available.
  defp owner?(%{resource: PluginAssignment} = changeset) do
    Ash.Changeset.get_attribute(changeset, :source) != :policy
  end

  defp owner?(_changeset), do: true

  # Compared against the loaded row so that re-submitting the current package
  # (a form that always posts it) is not mistaken for a version choice.
  defp package_changed?(changeset) do
    with true <- param_provided?(changeset, :plugin_package_id),
         {:ok, proposed} <- cast_uuid(param(changeset, :plugin_package_id)) do
      cast_uuid(Map.get(changeset.data, :plugin_package_id)) != {:ok, proposed}
    else
      _ -> false
    end
  end

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp package_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :plugin_package_id) ||
      Map.get(changeset.data, :plugin_package_id)
  end

  defp load_package(nil), do: nil

  defp load_package(package_id) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: SystemActor.system(:plugin_update_policy))
    |> case do
      {:ok, %PluginPackage{} = package} -> package
      _ -> nil
    end
  end

  defp param_provided?(changeset, attribute) do
    params = changeset.params || %{}
    Map.has_key?(params, attribute) or Map.has_key?(params, Atom.to_string(attribute))
  end

  defp param(changeset, attribute) do
    params = changeset.params || %{}
    Map.get(params, attribute, Map.get(params, Atom.to_string(attribute)))
  end
end
