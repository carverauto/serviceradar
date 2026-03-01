defmodule ServiceRadar.Plugins.Validations.AssignmentParams do
  @moduledoc """
  Validates plugin assignment params against the package config schema.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.{ConfigSchema, PluginInputs, PluginPackage, TargetBatchParams}

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    package_id =
      Ash.Changeset.get_attribute(changeset, :plugin_package_id) ||
        Map.get(changeset.data, :plugin_package_id)

    params =
      Ash.Changeset.get_attribute(changeset, :params) ||
        Map.get(changeset.data, :params) || %{}

    schema_from_context = Map.get(changeset.context, :config_schema)

    with {:ok, schema} <- resolve_schema(schema_from_context, package_id),
         :ok <- validate_batch_params(params),
         :ok <- validate_params(schema, params) do
      :ok
    else
      {:error, {:invalid_batch_params, errors}} ->
        {:error, field: :params, message: Enum.join(errors, "; ")}

      {:error, {:invalid_params, errors}} ->
        {:error, field: :params, message: Enum.join(errors, "; ")}

      {:error, :package_lookup} ->
        {:error, field: :plugin_package_id, message: "plugin package lookup failed"}
    end
  end

  defp load_schema(nil), do: {:ok, %{}}

  defp load_schema(package_id) do
    actor = SystemActor.system(:plugin_assignment_validation)

    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %PluginPackage{config_schema: schema}} -> {:ok, schema || %{}}
      {:ok, nil} -> {:ok, %{}}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_schema(schema_from_context, _package_id)
       when is_map(schema_from_context) and map_size(schema_from_context) > 0 do
    {:ok, schema_from_context}
  end

  defp resolve_schema(_schema_from_context, package_id) do
    case load_schema(package_id) do
      {:ok, schema} -> {:ok, schema || %{}}
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

  defp validate_batch_params(params) when is_map(params) do
    with :ok <- TargetBatchParams.validate(params),
         :ok <- PluginInputs.validate(params) do
      :ok
    else
      {:error, errors} -> {:error, {:invalid_batch_params, errors}}
    end
  end

  defp validate_batch_params(_params),
    do: {:error, {:invalid_batch_params, ["params must be an object"]}}
end
