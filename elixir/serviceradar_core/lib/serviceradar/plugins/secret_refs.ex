defmodule ServiceRadar.Plugins.SecretRefs do
  @moduledoc """
  Helpers for storing plugin secret-reference params without echoing raw secrets.
  """

  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Plugins.MapUtils

  @secret_prefix "secretref:"
  @secret_material_key "_secret_material"

  @spec prepare_params_for_storage(map(), map(), map()) :: map()
  def prepare_params_for_storage(schema, params, existing_params \\ %{})

  def prepare_params_for_storage(schema, params, existing_params)
      when is_map(schema) and is_map(params) and is_map(existing_params) do
    params = stringify_keys(params)
    existing_params = stringify_keys(existing_params)

    existing_material = secret_material(existing_params)

    {result, kept_material} =
      Enum.reduce(secret_ref_fields(schema), {public_params(params), %{}}, fn field, {acc, material} ->
        preserve_secret_field(acc, material, field, params, existing_params, existing_material)
      end)

    if map_size(kept_material) == 0 do
      Map.delete(result, @secret_material_key)
    else
      Map.put(result, @secret_material_key, kept_material)
    end
  end

  def prepare_params_for_storage(_schema, params, _existing_params) when is_map(params),
    do: public_params(params)

  def prepare_params_for_storage(_schema, _params, _existing_params), do: %{}

  @spec public_params(map()) :: map()
  def public_params(params) when is_map(params) do
    params
    |> stringify_keys()
    |> Map.delete(@secret_material_key)
  end

  def public_params(_params), do: %{}

  @spec resolve_runtime_params(map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def resolve_runtime_params(schema, params) when is_map(schema) and is_map(params) do
    params = stringify_keys(params)
    material = secret_material(params)

    Enum.reduce(secret_ref_fields(schema), {:ok, public_params(params)}, fn field, {:ok, acc} ->
      case secret_ref_value(acc, field) do
        nil ->
          {:ok, acc}

        ref ->
          case Map.get(material, ref) do
            nil ->
              {:error, ["#{field} is missing secret material"]}

            encrypted ->
              case Crypto.decrypt_safe(encrypted) do
                {:ok, secret} ->
                  {:ok, Map.put(acc, runtime_field_name(field), secret)}

                {:error, :decrypt_failed} ->
                  {:error, ["#{field} could not be decrypted"]}
              end
          end
      end
    end)
  end

  def resolve_runtime_params(_schema, params) when is_map(params), do: {:ok, public_params(params)}
  def resolve_runtime_params(_schema, _params), do: {:ok, %{}}

  @spec validate_secret_linkage(map(), map()) :: :ok | {:error, [String.t()]}
  def validate_secret_linkage(schema, params) when is_map(schema) and is_map(params) do
    params = stringify_keys(params)
    material = secret_material(params)

    errors =
      Enum.flat_map(secret_ref_fields(schema), fn field ->
        ref = secret_ref_value(params, field)

        cond do
          is_nil(ref) ->
            []

          not is_secret_ref(ref) ->
            ["#{field} must be a secret reference"]

          is_nil(Map.get(material, ref)) ->
            ["#{field} is missing linked secret material"]

          true ->
            []
        end
      end)

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

  @spec is_secret_ref(String.t()) :: boolean()
  def is_secret_ref(value) when is_binary(value), do: String.starts_with?(value, @secret_prefix)
  def is_secret_ref(_value), do: false

  defp preserve_secret_field(acc, material, field, params, existing_params, existing_material) do
    incoming = normalize_string(Map.get(params, field))
    existing_ref = secret_ref_value(existing_params, field)

    cond do
      incoming == nil and existing_ref != nil ->
        keep_existing_secret(acc, material, field, existing_ref, existing_material)

      incoming == nil ->
        {Map.delete(acc, field), material}

      is_secret_ref(incoming) && Map.has_key?(existing_material, incoming) ->
        {Map.put(acc, field, incoming), Map.put(material, incoming, Map.fetch!(existing_material, incoming))}

      is_secret_ref(incoming) ->
        {Map.put(acc, field, incoming), material}

      existing_ref != nil && incoming == existing_ref ->
        keep_existing_secret(acc, material, field, existing_ref, existing_material)

      true ->
        ref = generate_secret_ref(field)

        {
          Map.put(acc, field, ref),
          Map.put(material, ref, Crypto.encrypt(incoming))
        }
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

  defp stringify_keys(value), do: MapUtils.stringify_keys_or_empty(value)
end
