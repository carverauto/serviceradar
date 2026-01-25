defmodule ServiceRadar.Plugins.Validations.AssignmentParams do
  @moduledoc """
  Validates plugin assignment params against the package config schema.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.{ConfigSchema, PluginPackage}

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

    cond do
      is_map(schema_from_context) and map_size(schema_from_context) > 0 ->
        case ConfigSchema.validate_params(schema_from_context, params) do
          :ok -> :ok
          {:error, errors} -> {:error, field: :params, message: Enum.join(errors, "; ")}
        end

      true ->
        case load_schema(package_id) do
          {:ok, %{} = schema} when map_size(schema) > 0 ->
            case ConfigSchema.validate_params(schema, params) do
              :ok -> :ok
              {:error, errors} -> {:error, field: :params, message: Enum.join(errors, "; ")}
            end

          {:ok, _} ->
            :ok

          {:error, _} ->
            {:error, field: :plugin_package_id, message: "plugin package lookup failed"}
        end
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
end
