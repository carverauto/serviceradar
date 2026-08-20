defmodule ServiceRadar.Plugins.Validations.AssignmentParams do
  @moduledoc """
  Validates plugin assignment params against the package config schema.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.PluginInputs
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.TargetBatchParams

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
    policy_envelope? = policy_envelope?(changeset, params)

    with {:ok, schema} <- resolve_schema(schema_from_context, package_id),
         :ok <- validate_batch_params(params),
         :ok <- validate_params(schema, params, policy_envelope?),
         :ok <- validate_secret_linkage(schema, params),
         :ok <- validate_auth_linkage(params) do
      :ok
    else
      {:error, {:invalid_batch_params, errors}} ->
        {:error, field: :params, message: Enum.join(errors, "; ")}

      {:error, {:invalid_params, errors}} ->
        {:error, field: :params, message: Enum.join(errors, "; ")}

      {:error, {:invalid_secret_linkage, errors}} ->
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

  defp validate_params(schema, params, policy_envelope?)
       when is_map(schema) and map_size(schema) > 0 do
    case ConfigSchema.validate_params(schema, operator_params(params, policy_envelope?)) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_params, errors}}
    end
  end

  defp validate_params(_schema, _params, _policy_envelope?), do: :ok

  # A package `config_schema` is the operator-facing contract. A policy-owned
  # assignment carries no operator keys at the top level -- they live under
  # "template", inside the platform-owned `serviceradar.plugin_inputs.v1`
  # envelope. Those envelope keys were already validated by
  # `validate_batch_params/1` against `PluginInputs`' own closed schema earlier
  # in the same `with`; running them through `config_schema` as well makes every
  # package that sets `additionalProperties: false` reject its own materialized
  # assignment. That is how proxmox-inventory became unmaterializable
  # (go/cmd/wasm-plugins/proxmox/config.schema.json).
  #
  # This is a subset restriction, not a skip. `PluginInputs` closes its own
  # schema, so anything left after dropping the envelope keys is still handed to
  # `config_schema` and still validated strictly.
  defp operator_params(params, true) when is_map(params),
    do: Map.drop(params, PluginInputs.envelope_keys())

  defp operator_params(params, _policy_envelope?), do: params

  # Both halves are required.
  #
  # `source == :policy` because config_schema's `additionalProperties: false` is
  # today the only thing stopping a hand-written assignment from carrying a
  # forged `credential_broker`: ProxmoxHostAuthority accepts a grant from either
  # params["credential_broker"] or params["template"]["credential_broker"], and
  # `PluginInputs` types "template" as a free-form object, constraining nothing
  # inside it. An unconditional carve-out would widen that trust boundary for no
  # benefit -- no lib/ path ever gives a manual assignment envelope-shaped params.
  #
  # The schema id because it proves the strict envelope validation above actually
  # ran. This is deliberately narrower than `PluginInputs.plugin_inputs_payload?/1`,
  # which also matches a bare "inputs" key: a partial or forged envelope must not
  # buy an exemption.
  defp policy_envelope?(changeset, params) when is_map(params) do
    source =
      Ash.Changeset.get_attribute(changeset, :source) ||
        Map.get(changeset.data, :source) || :manual

    source == :policy and Map.get(params, "schema") == PluginInputs.schema_id()
  end

  defp policy_envelope?(_changeset, _params), do: false

  defp validate_secret_linkage(schema, params) when is_map(params) do
    case SecretRefs.validate_secret_linkage(schema, params) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_secret_linkage, errors}}
    end
  end

  defp validate_secret_linkage(_schema, _params), do: :ok

  defp validate_auth_linkage(params) when is_map(params) do
    auth_mode =
      params
      |> Map.get("stream_auth_mode")
      |> normalize_string()

    secret_ref =
      params
      |> Map.get("password_secret_ref")
      |> normalize_string()

    if auth_mode in ["basic", "digest"] and is_nil(secret_ref) do
      {:error,
       {:invalid_secret_linkage,
        ["password_secret_ref is required when stream_auth_mode requires authentication"]}}
    else
      :ok
    end
  end

  defp validate_auth_linkage(_params), do: :ok

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

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
