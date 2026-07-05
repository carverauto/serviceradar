defmodule ServiceRadar.Plugins.Validations.AddonAssignmentParams do
  @moduledoc """
  Validates add-on assignment params against the add-on package's config schema
  before persistence, so invalid params are rejected at the control plane instead
  of surfacing later as a runtime `Configure` rejection on the agent.

  This mirrors the core of `ServiceRadar.Plugins.Validations.AssignmentParams`
  (schema lookup + `ConfigSchema.validate_params/2`) without the plugin-specific
  batch/secret/auth-linkage checks, which do not apply to native add-ons.

  ## Empty-schema policy (fj#4383)

  When a package declares NO `config_schema` (absent or empty map), there is
  nothing to validate types against, so validation intentionally passes.
  Blocking would break sample/dev add-ons that legitimately ship without a
  schema. To keep that hole visible instead of silent, a warning is logged
  ONCE per package (per node) the first time non-empty params are persisted
  against a schemaless package. Rows persisted before this guard existed are
  covered by the `mix serviceradar.validate_addon_params` backfill task, and
  the delivery path independently validates coerced params against the schema
  before emitting `config_json` (refusing delivery when they cannot conform).
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.ConfigSchema

  require Logger

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
         :ok <- validate_params(schema, params, package_id) do
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

  defp validate_params(schema, params, _package_id)
       when is_map(schema) and map_size(schema) > 0 do
    case ConfigSchema.validate_params(schema, params) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_params, errors}}
    end
  end

  # Empty-schema policy: pass, but warn once per package when the write carries
  # non-empty params that nothing can type-check (see moduledoc).
  defp validate_params(_schema, params, package_id) do
    warn_unvalidatable_params_once(package_id, params)
    :ok
  end

  defp warn_unvalidatable_params_once(package_id, params)
       when is_map(params) and map_size(params) > 0 and not is_nil(package_id) do
    key = {__MODULE__, :empty_schema_warned, package_id}

    if !:persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "Add-on package #{package_id} declares no config_schema; assignment params " <>
          "cannot be type-checked and will be delivered as-is (keys: " <>
          "#{params |> Map.keys() |> Enum.map_join(",", &to_string/1)}). " <>
          "Declare a config_schema on the package to enforce typed contracts. " <>
          "This warning is emitted once per package."
      )
    end

    :ok
  end

  defp warn_unvalidatable_params_once(_package_id, _params), do: :ok
end
