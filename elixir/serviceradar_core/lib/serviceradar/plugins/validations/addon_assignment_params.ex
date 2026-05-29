defmodule ServiceRadar.Plugins.Validations.AddonAssignmentParams do
  @moduledoc """
  Validates add-on assignment params against the add-on package's config schema
  before persistence, so invalid params are rejected at the control plane instead
  of surfacing later as a runtime `Configure` rejection on the agent.

  This mirrors the core of `ServiceRadar.Plugins.Validations.AssignmentParams`
  (schema lookup + `ConfigSchema.validate_params/2`) without the plugin-specific
  batch/secret/auth-linkage checks, which do not apply to native add-ons.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.ConfigSchema

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    package_id =
      Ash.Changeset.get_attribute(changeset, :addon_package_id) ||
        Map.get(changeset.data, :addon_package_id)

    params =
      Ash.Changeset.get_attribute(changeset, :params) ||
        Map.get(changeset.data, :params) || %{}

    with {:ok, schema} <- load_schema(package_id),
         :ok <- validate_params(schema, params) do
      :ok
    else
      {:error, {:invalid_params, errors}} ->
        {:error, field: :params, message: Enum.join(errors, "; ")}

      {:error, :package_lookup} ->
        {:error, field: :addon_package_id, message: "add-on package lookup failed"}
    end
  end

  defp load_schema(nil), do: {:ok, %{}}

  defp load_schema(package_id) do
    actor = SystemActor.system(:addon_assignment_validation)

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %AddonPackage{config_schema: schema}} -> {:ok, schema || %{}}
      {:ok, nil} -> {:ok, %{}}
      {:error, _} -> {:error, :package_lookup}
    end
  end

  defp validate_params(schema, params) when is_map(schema) and map_size(schema) > 0 do
    case ConfigSchema.validate_params(schema, params) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_params, errors}}
    end
  end

  defp validate_params(_schema, _params), do: :ok
end
