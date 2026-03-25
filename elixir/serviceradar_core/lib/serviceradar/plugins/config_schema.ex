defmodule ServiceRadar.Plugins.ConfigSchema do
  @moduledoc """
  Helpers for validating and normalizing plugin configuration schemas.
  """

  alias ServiceRadar.Plugins.MapUtils

  @allowed_formats ~w(uri email)
  @allowed_root_keys ~w(type title description properties required additionalProperties)
  @allowed_property_keys ~w(
    type title description default enum minimum maximum minLength maxLength pattern format items
    properties required additionalProperties secretRef
  )
  @allowed_types ~w(string integer number boolean array object)

  @spec validate_schema(map()) :: :ok | {:error, [String.t()]}
  def validate_schema(%{} = schema) do
    schema = stringify_keys(schema)

    if map_size(schema) == 0 do
      :ok
    else
      errors = []

      errors = ensure_root_object(schema, errors)
      errors = validate_keys(schema, @allowed_root_keys, "schema", errors)
      errors = validate_required(schema, errors)
      errors = validate_additional_properties(schema, errors)
      errors = validate_properties(Map.get(schema, "properties"), "properties", errors)

      case errors do
        [] -> :ok
        _ -> {:error, Enum.reverse(errors)}
      end
    end
  end

  def validate_schema(_), do: {:error, ["config schema must be a JSON object"]}

  @spec normalize_params(map(), map()) :: map()
  def normalize_params(schema, params) when is_map(schema) do
    schema = stringify_keys(schema)
    params = stringify_keys(params || %{})
    {normalized, _} = normalize_for_schema(schema, params)
    normalized
  end

  def normalize_params(_schema, params) when is_map(params), do: stringify_keys(params)
  def normalize_params(_schema, _params), do: %{}

  @spec validate_params(map(), map()) :: :ok | {:error, [String.t()]}
  def validate_params(schema, params) when is_map(schema) and is_map(params) do
    schema = stringify_keys(schema)

    if map_size(schema) == 0 do
      :ok
    else
      resolved = ExJsonSchema.Schema.resolve(schema)

      case ExJsonSchema.Validator.validate(resolved, params) do
        :ok -> :ok
        {:error, errors} -> {:error, Enum.map(errors, &format_error/1)}
      end
    end
  end

  def validate_params(_schema, _params), do: :ok

  defp ensure_root_object(schema, errors) do
    case Map.get(schema, "type") do
      "object" -> errors
      nil -> ["schema.type must be \"object\"" | errors]
      other -> ["schema.type must be \"object\" (got #{inspect(other)})" | errors]
    end
  end

  defp validate_keys(schema, allowed, path, errors) do
    unknown =
      schema
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] -> errors
      _ -> ["#{path} contains unsupported keys: #{Enum.join(unknown, ", ")}" | errors]
    end
  end

  defp validate_required(schema, errors) do
    required = Map.get(schema, "required")

    cond do
      is_nil(required) ->
        errors

      is_list(required) and Enum.all?(required, &is_binary/1) ->
        errors

      true ->
        ["schema.required must be a list of strings" | errors]
    end
  end

  defp validate_additional_properties(schema, errors) do
    case Map.get(schema, "additionalProperties") do
      nil -> errors
      value when is_boolean(value) -> errors
      _ -> ["schema.additionalProperties must be a boolean" | errors]
    end
  end

  defp validate_properties(nil, _path, errors), do: errors

  defp validate_properties(%{} = properties, path, errors) do
    Enum.reduce(properties, errors, fn {key, prop_schema}, acc ->
      prop_path = "#{path}.#{key}"

      if is_map(prop_schema) do
        acc
        |> then(&validate_keys(prop_schema, @allowed_property_keys, prop_path, &1))
        |> validate_property_type(prop_schema, prop_path)
        |> validate_property_constraints(prop_schema, prop_path)
        |> validate_nested_properties(prop_schema, prop_path)
      else
        ["#{prop_path} must be an object" | acc]
      end
    end)
  end

  defp validate_properties(_, path, errors) do
    ["#{path} must be an object" | errors]
  end

  defp validate_property_type(errors, schema, path) do
    case Map.get(schema, "type") do
      nil ->
        ["#{path}.type is required" | errors]

      type when type in @allowed_types ->
        errors

      type ->
        ["#{path}.type must be one of: #{Enum.join(@allowed_types, ", ")} (got #{type})" | errors]
    end
  end

  defp validate_property_constraints(errors, schema, path) do
    errors
    |> validate_enum(schema, path)
    |> validate_string_constraints(schema, path)
    |> validate_number_constraints(schema, path)
    |> validate_format(schema, path)
    |> validate_items(schema, path)
    |> validate_secret_ref(schema, path)
  end

  defp validate_enum(errors, schema, path) do
    case Map.get(schema, "enum") do
      nil -> errors
      value when is_list(value) and value != [] -> errors
      _ -> ["#{path}.enum must be a non-empty list" | errors]
    end
  end

  defp validate_string_constraints(errors, schema, path) do
    if Map.get(schema, "type") == "string" do
      errors
      |> validate_integer(schema, "minLength", path)
      |> validate_integer(schema, "maxLength", path)
    else
      errors
    end
  end

  defp validate_number_constraints(errors, schema, path) do
    if Map.get(schema, "type") in ["integer", "number"] do
      errors
      |> validate_number(schema, "minimum", path)
      |> validate_number(schema, "maximum", path)
    else
      errors
    end
  end

  defp validate_format(errors, schema, path) do
    case Map.get(schema, "format") do
      nil ->
        errors

      format when format in @allowed_formats ->
        errors

      format ->
        [
          "#{path}.format must be one of: #{Enum.join(@allowed_formats, ", ")} (got #{format})"
          | errors
        ]
    end
  end

  defp validate_items(errors, schema, path) do
    if Map.get(schema, "type") == "array" do
      case Map.get(schema, "items") do
        nil -> ["#{path}.items is required for array types" | errors]
        value when is_map(value) -> validate_property_type(errors, value, "#{path}.items")
        _ -> ["#{path}.items must be an object" | errors]
      end
    else
      errors
    end
  end

  defp validate_secret_ref(errors, schema, path) do
    case Map.get(schema, "secretRef") do
      nil ->
        errors

      value when is_boolean(value) ->
        errors

      _ ->
        ["#{path}.secretRef must be a boolean" | errors]
    end
  end

  defp validate_nested_properties(errors, schema, path) do
    case Map.get(schema, "type") do
      "object" ->
        errors
        |> then(&validate_required(schema, &1))
        |> then(&validate_additional_properties(schema, &1))
        |> then(&validate_properties(Map.get(schema, "properties"), "#{path}.properties", &1))

      _ ->
        errors
    end
  end

  defp validate_integer(errors, schema, key, path) do
    case Map.get(schema, key) do
      nil -> errors
      value when is_integer(value) and value >= 0 -> errors
      _ -> ["#{path}.#{key} must be a non-negative integer" | errors]
    end
  end

  defp validate_number(errors, schema, key, path) do
    case Map.get(schema, key) do
      nil -> errors
      value when is_integer(value) or is_float(value) -> errors
      _ -> ["#{path}.#{key} must be a number" | errors]
    end
  end

  defp stringify_keys(value), do: MapUtils.stringify_keys_or_empty(value)

  defp normalize_for_schema(%{"type" => "object"} = schema, params) when is_map(params) do
    properties = Map.get(schema, "properties", %{})
    {normalize_object_params(properties, params), schema}
  end

  defp normalize_for_schema(_schema, params) when is_map(params), do: {params, nil}
  defp normalize_for_schema(_schema, _params), do: {%{}, nil}

  defp normalize_object_params(properties, params) do
    Enum.reduce(properties, params, fn {key, prop_schema}, acc ->
      normalize_object_param(acc, key, prop_schema)
    end)
  end

  defp normalize_object_param(acc, key, prop_schema) do
    if Map.has_key?(acc, key) do
      Map.put(acc, key, normalize_value(prop_schema, Map.get(acc, key)))
    else
      maybe_put_default(acc, key, prop_schema)
    end
  end

  defp maybe_put_default(acc, key, prop_schema) do
    case Map.get(prop_schema, "default") do
      nil -> acc
      default -> Map.put(acc, key, default)
    end
  end

  defp normalize_value(%{"type" => "string"}, value) when is_binary(value), do: value
  defp normalize_value(%{"type" => "string"}, value), do: to_string(value)

  defp normalize_value(%{"type" => "integer"}, value) do
    cast_int(value)
  end

  defp normalize_value(%{"type" => "number"}, value) do
    cast_number(value)
  end

  defp normalize_value(%{"type" => "boolean"}, value) do
    cast_bool(value)
  end

  defp normalize_value(%{"type" => "array", "items" => item_schema}, value) do
    list =
      cond do
        is_list(value) -> value
        is_binary(value) -> split_list(value)
        true -> []
      end

    Enum.map(list, &normalize_value(item_schema, &1))
  end

  defp normalize_value(%{"type" => "object"} = schema, value) when is_map(value) do
    {normalized, _} = normalize_for_schema(schema, stringify_keys(value))
    normalized
  end

  defp normalize_value(_schema, value), do: value

  defp cast_int(nil), do: nil
  defp cast_int(value) when is_integer(value), do: value

  defp cast_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp cast_int(value), do: value

  defp cast_number(nil), do: nil
  defp cast_number(value) when is_integer(value) or is_float(value), do: value

  defp cast_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {num, ""} -> num
      _ -> value
    end
  end

  defp cast_number(value), do: value

  defp cast_bool(nil), do: nil
  defp cast_bool(value) when is_boolean(value), do: value

  defp cast_bool(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> value
    end
  end

  defp cast_bool(value), do: value

  defp split_list(value) do
    value
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_error(%{error: error, path: path}) when is_list(path) do
    "#{Enum.join(path, ".")}: #{error}"
  end

  defp format_error(error), do: inspect(error)
end
