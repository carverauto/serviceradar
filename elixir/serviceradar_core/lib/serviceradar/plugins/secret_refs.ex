defmodule ServiceRadar.Plugins.SecretRefs do
  @moduledoc """
  Helpers for storing plugin secret-reference params without echoing raw secrets.
  """

  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Plugins.MapUtils

  @secret_prefix "secretref:"
  @network_credential_prefix "credentialref:network-credential-secret:"
  @secret_material_key "_secret_material"

  @spec prepare_params_for_storage(map(), map(), map()) :: map()
  def prepare_params_for_storage(schema, params, existing_params \\ %{})

  def prepare_params_for_storage(schema, params, existing_params)
      when is_map(schema) and is_map(params) and is_map(existing_params) do
    params = stringify_keys(params)
    existing_params = stringify_keys(existing_params)

    params
    |> prepare_direct_params_for_storage(schema, existing_params)
    |> maybe_prepare_template_for_storage(schema, params, existing_params)
  end

  def prepare_params_for_storage(_schema, params, _existing_params) when is_map(params),
    do: public_params(params)

  def prepare_params_for_storage(_schema, _params, _existing_params), do: %{}

  defp prepare_direct_params_for_storage(params, schema, existing_params) do
    existing_material = secret_material(existing_params)

    {result, kept_material} =
      Enum.reduce(secret_ref_fields(schema), {public_params(params), %{}}, fn field,
                                                                              {acc, material} ->
        preserve_secret_field(acc, material, field, params, existing_params, existing_material)
      end)

    if map_size(kept_material) == 0 do
      Map.delete(result, @secret_material_key)
    else
      Map.put(result, @secret_material_key, kept_material)
    end
  end

  @spec public_params(map()) :: map()
  def public_params(params) when is_map(params) do
    params
    |> stringify_keys()
    |> remove_secret_material()
  end

  def public_params(_params), do: %{}

  @spec resolve_runtime_params(map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def resolve_runtime_params(schema, params) when is_map(schema) and is_map(params) do
    params = stringify_keys(params)

    with {:ok, resolved} <- resolve_direct_runtime_params(schema, params) do
      maybe_resolve_template_runtime(schema, resolved, params)
    end
  end

  def resolve_runtime_params(_schema, params) when is_map(params),
    do: {:ok, public_params(params)}

  def resolve_runtime_params(_schema, _params), do: {:ok, %{}}

  @spec validate_secret_linkage(map(), map()) :: :ok | {:error, [String.t()]}
  def validate_secret_linkage(schema, params) when is_map(schema) and is_map(params) do
    params = stringify_keys(params)

    errors =
      direct_secret_linkage_errors(schema, params) ++
        template_secret_linkage_errors(schema, params)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  def validate_secret_linkage(_schema, _params), do: :ok

  @spec secret_ref_fields(map()) :: [String.t()]
  def secret_ref_fields(schema) when is_map(schema) do
    schema
    |> stringify_keys()
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {name, property} ->
      if secret_ref_property?(property), do: [name], else: []
    end)
  end

  def secret_ref_fields(_schema), do: []

  @spec secret_ref_property?(map()) :: boolean()
  def secret_ref_property?(property) when is_map(property) do
    property
    |> stringify_keys()
    |> Map.get("secretRef") == true
  end

  def secret_ref_property?(_property), do: false

  @spec runtime_field_name(String.t()) :: String.t()
  def runtime_field_name(field) when is_binary(field) do
    String.replace_suffix(field, "_secret_ref", "")
  end

  @spec secret_ref?(String.t()) :: boolean()
  def secret_ref?(value) when is_binary(value) do
    String.starts_with?(value, @secret_prefix) or network_credential_ref?(value)
  end

  def secret_ref?(_value), do: false

  @spec network_credential_ref(String.t()) :: String.t()
  def network_credential_ref(secret_id) when is_binary(secret_id) do
    @network_credential_prefix <> secret_id
  end

  @spec network_credential_ref_id(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def network_credential_ref_id(ref) when is_binary(ref) do
    if network_credential_ref?(ref) do
      secret_id = String.replace_prefix(ref, @network_credential_prefix, "")

      if secret_id == "" do
        {:error, "has an empty network credential reference"}
      else
        {:ok, secret_id}
      end
    else
      {:error, "is not a network credential reference"}
    end
  end

  defp preserve_secret_field(acc, material, field, params, existing_params, existing_material) do
    incoming = normalize_string(Map.get(params, field))
    existing_ref = secret_ref_value(existing_params, field)

    case classify_secret_update(incoming, existing_ref, existing_material) do
      :keep_existing ->
        keep_existing_secret(acc, material, field, existing_ref, existing_material)

      :delete ->
        {Map.delete(acc, field), material}

      :existing_material_ref ->
        {Map.put(acc, field, incoming),
         Map.put(material, incoming, Map.fetch!(existing_material, incoming))}

      :passthrough_ref ->
        {Map.put(acc, field, incoming), material}

      :new_secret ->
        ref = generate_secret_ref(field)

        {
          Map.put(acc, field, ref),
          Map.put(material, ref, Crypto.encrypt(incoming))
        }
    end
  end

  defp resolve_secret_field(acc, field, material) do
    with ref when not is_nil(ref) <- secret_ref_value(acc, field),
         {:ok, secret} <- resolve_secret_ref(material, ref, field) do
      {:ok, Map.put(acc, runtime_field_name(field), secret)}
    else
      nil -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_secret_ref(material, ref, field) do
    if network_credential_ref?(ref) do
      resolve_network_credential_ref(ref, field)
    else
      with {:ok, encrypted} <- fetch_secret_material(material, ref, field) do
        decrypt_secret_material(encrypted, field)
      end
    end
  end

  defp fetch_secret_material(material, ref, field) do
    case Map.get(material, ref) do
      nil -> {:error, "#{field} is missing secret material"}
      encrypted -> {:ok, encrypted}
    end
  end

  defp decrypt_secret_material(encrypted, field) do
    case Crypto.decrypt_safe(encrypted) do
      {:ok, secret} -> {:ok, secret}
      {:error, :decrypt_failed} -> {:error, "#{field} could not be decrypted"}
    end
  end

  defp resolve_network_credential_ref(ref, field) do
    with {:ok, secret_id} <- network_credential_ref_id(ref),
         {:ok, secret} <- load_network_credential_secret(secret_id),
         {:ok, payload} <- decrypt_network_credential_secret(secret),
         true <- payload != "" do
      {:ok, payload}
    else
      {:error, reason} -> {:error, "#{field} #{reason}"}
      _ -> {:error, "#{field} referenced network credential has no secret payload"}
    end
  end

  defp decrypt_network_credential_secret(secret) do
    case Map.get(secret, :secret_payload) do
      payload when is_binary(payload) and payload != "" ->
        {:ok, payload}

      _ ->
        {:error, "referenced network credential has no secret payload"}
    end
  end

  defp load_network_credential_secret(secret_id) do
    actor = ServiceRadar.Actors.SystemActor.system(:plugin_secret_ref_resolution)

    ServiceRadar.Credentials.NetworkCredentialSecret.get_secret_by_id(secret_id, actor: actor)
  end

  defp classify_secret_update(nil, existing_ref, _existing_material)
       when not is_nil(existing_ref), do: :keep_existing

  defp classify_secret_update(nil, _existing_ref, _existing_material), do: :delete

  defp classify_secret_update(incoming, existing_ref, _existing_material)
       when not is_nil(existing_ref) and incoming == existing_ref, do: :keep_existing

  defp classify_secret_update(incoming, _existing_ref, existing_material) do
    cond do
      secret_ref?(incoming) and Map.has_key?(existing_material, incoming) ->
        :existing_material_ref

      secret_ref?(incoming) ->
        :passthrough_ref

      true ->
        :new_secret
    end
  end

  defp keep_existing_secret(acc, material, field, existing_ref, existing_material) do
    if encrypted = Map.get(existing_material, existing_ref) do
      {
        Map.put(acc, field, existing_ref),
        Map.put(material, existing_ref, encrypted)
      }
    else
      {Map.put(acc, field, existing_ref), material}
    end
  end

  defp secret_ref_value(params, field) do
    case normalize_string(Map.get(params, field)) do
      nil -> nil
      value -> value
    end
  end

  defp generate_secret_ref(field) do
    suffix =
      field
      |> runtime_field_name()
      |> String.replace(~r/[^a-zA-Z0-9_:-]/, "-")

    @secret_prefix <> suffix <> ":" <> Crypto.generate_token()
  end

  defp secret_material(params) do
    params
    |> Map.get(@secret_material_key, %{})
    |> stringify_keys()
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp maybe_prepare_template_for_storage(result, schema, params, existing_params) do
    template = Map.get(params, "template")

    if plugin_inputs_payload?(params) and is_map(template) do
      existing_template =
        existing_params
        |> Map.get("template", %{})
        |> stringify_keys()

      prepared_template =
        template
        |> stringify_keys()
        |> prepare_direct_params_for_storage(schema, existing_template)

      Map.put(result, "template", prepared_template)
    else
      result
    end
  end

  defp resolve_direct_runtime_params(schema, params) do
    material = secret_material(params)

    Enum.reduce_while(secret_ref_fields(schema), {:ok, public_params(params)}, fn field,
                                                                                  {:ok, acc} ->
      case resolve_secret_field(acc, field, material) do
        {:ok, resolved} ->
          {:cont, {:ok, resolved}}

        {:error, reason} ->
          {:halt, {:error, [reason]}}
      end
    end)
  end

  defp maybe_resolve_template_runtime(schema, resolved, params) do
    template = Map.get(params, "template")

    if plugin_inputs_payload?(params) and is_map(template) do
      case resolve_direct_runtime_params(schema, stringify_keys(template)) do
        {:ok, runtime_template} -> {:ok, Map.put(resolved, "template", runtime_template)}
        {:error, _} = error -> error
      end
    else
      {:ok, resolved}
    end
  end

  defp direct_secret_linkage_errors(schema, params) do
    material = secret_material(params)

    Enum.flat_map(secret_ref_fields(schema), fn field ->
      ref = secret_ref_value(params, field)

      cond do
        is_nil(ref) ->
          []

        not secret_ref?(ref) ->
          ["#{field} must be a secret reference"]

        network_credential_ref?(ref) ->
          []

        is_nil(Map.get(material, ref)) ->
          ["#{field} is missing linked secret material"]

        true ->
          []
      end
    end)
  end

  defp template_secret_linkage_errors(schema, params) do
    template = Map.get(params, "template")

    if plugin_inputs_payload?(params) and is_map(template) do
      schema
      |> direct_secret_linkage_errors(stringify_keys(template))
      |> Enum.map(&("template." <> &1))
    else
      []
    end
  end

  defp plugin_inputs_payload?(params) when is_map(params) do
    Map.get(params, "schema") == "serviceradar.plugin_inputs.v1" or Map.has_key?(params, "inputs")
  end

  defp plugin_inputs_payload?(_params), do: false

  defp network_credential_ref?(value) when is_binary(value) do
    String.starts_with?(value, @network_credential_prefix)
  end

  defp network_credential_ref?(_value), do: false

  defp remove_secret_material(%{} = map) do
    map
    |> Map.delete(@secret_material_key)
    |> Map.new(fn {key, value} -> {key, remove_secret_material(value)} end)
  end

  defp remove_secret_material(list) when is_list(list),
    do: Enum.map(list, &remove_secret_material/1)

  defp remove_secret_material(value), do: value

  defp stringify_keys(value), do: MapUtils.stringify_keys_or_empty(value)
end
