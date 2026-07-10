defmodule ServiceRadar.Plugins.ConfigSchema do
  @moduledoc """
  Helpers for validating and normalizing plugin configuration schemas.
  """

  alias ServiceRadar.Plugins.MapUtils

  @allowed_formats ~w(uri email password)
  @allowed_root_keys ~w($schema type title description properties required additionalProperties)
  @allowed_property_keys ~w(
    type title description default enum minimum maximum minLength maxLength pattern format items
    minItems maxItems uniqueItems properties required additionalProperties secretRef
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
    schema = schema |> stringify_keys() |> assignment_schema()
    params = stringify_keys(params || %{})
    {normalized, _} = normalize_for_schema(schema, params)
    normalized
  end

  def normalize_params(_schema, params) when is_map(params), do: stringify_keys(params)
  def normalize_params(_schema, _params), do: %{}

  @doc """
  Schema-driven type coercion for the config delivery path (fj#4381).

  Coerces param values that are present in `params` to the types their package
  `config_schema` declares — notably scalar string → string list for
  `"type": "array"` properties, the shape that wedged netprobe config apply —
  while leaving everything else untouched: no schema defaults are injected for
  absent top-level keys, no top-level keys are added or removed, and `nil`
  values pass through unchanged (JSON `null` means "unset" to the agent-side
  decoders; coercing it to `[]` would turn "inherit" into "explicit clear").
  Values of declared `object` properties are normalized recursively with the
  same rules as author-time normalization.

  Unlike `normalize_params/2` (author-time form normalization, which injects
  defaults and drops blank values), this is safe to run on every delivery
  cycle: params that already match the schema come back equal, so the encoded
  `config_json` is byte-identical.

  Params are expected to carry string keys (they come from JSONB storage);
  atom-keyed entries are left untouched. A `nil`, empty, or property-less
  schema passes params through unchanged — there is nothing to coerce against.
  """
  @spec coerce_params(map() | nil, map()) :: map()
  def coerce_params(schema, params) when is_map(schema) and is_map(params) do
    properties =
      schema
      |> stringify_keys()
      |> Map.get("properties")

    if is_map(properties) do
      Enum.reduce(properties, params, fn {key, prop_schema}, acc ->
        coerce_param(acc, key, prop_schema)
      end)
    else
      params
    end
  end

  def coerce_params(_schema, params) when is_map(params), do: params
  def coerce_params(_schema, _params), do: %{}

  defp coerce_param(params, key, prop_schema) when is_map(prop_schema) do
    case Map.fetch(params, key) do
      {:ok, nil} -> params
      {:ok, value} -> Map.put(params, key, normalize_value(prop_schema, value))
      :error -> params
    end
  end

  defp coerce_param(params, _key, _prop_schema), do: params

  @spec validate_params(map(), map()) :: :ok | {:error, [String.t()]}
  def validate_params(schema, params) when is_map(schema) and is_map(params) do
    schema = schema |> stringify_keys() |> assignment_schema()

    if map_size(schema) == 0 do
      :ok
    else
      resolved = schema |> validation_schema() |> ExJsonSchema.Schema.resolve()

      case ExJsonSchema.Validator.validate(resolved, params) do
        :ok -> :ok
        {:error, errors} -> {:error, Enum.map(errors, &format_error/1)}
      end
    end
  end

  def validate_params(_schema, _params), do: :ok

  defp assignment_schema(%{} = schema) do
    required = Map.get(schema, "required")
    properties = Map.get(schema, "properties")

    cond do
      not is_list(required) ->
        schema

      not is_map(properties) ->
        schema

      true ->
        required =
          Enum.reject(required, fn field ->
            field
            |> then(&Map.get(properties, &1, %{}))
            |> runtime_injected_property?()
          end)

        if required == [] do
          Map.delete(schema, "required")
        else
          Map.put(schema, "required", required)
        end
    end
  end

  defp validation_schema(%{} = schema), do: Map.delete(schema, "$schema")

  defp runtime_injected_property?(%{} = property) do
    Map.get(property, "x-serviceradar-credential-materialized") == true or
      (Map.get(property, "x-serviceradar-ui-hidden") == true and
         Map.get(property, "default") in [nil, ""])
  end

  defp runtime_injected_property?(_property), do: false

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
      |> Enum.reject(&allowed_key?(&1, allowed))

    case unknown do
      [] -> errors
      _ -> ["#{path} contains unsupported keys: #{Enum.join(unknown, ", ")}" | errors]
    end
  end

  defp allowed_key?(key, allowed), do: key in allowed or String.starts_with?(key, "x-")

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
    |> validate_array_constraints(schema, path)
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

  defp validate_array_constraints(errors, schema, path) do
    if Map.get(schema, "type") == "array" do
      errors
      |> validate_integer(schema, "minItems", path)
      |> validate_integer(schema, "maxItems", path)
      |> validate_unique_items(schema, path)
      |> validate_array_bounds(schema, path)
    else
      errors
    end
  end

  defp validate_unique_items(errors, schema, path) do
    case Map.get(schema, "uniqueItems") do
      nil -> errors
      value when is_boolean(value) -> errors
      _ -> ["#{path}.uniqueItems must be a boolean" | errors]
    end
  end

  defp validate_array_bounds(errors, schema, path) do
    case {Map.get(schema, "minItems"), Map.get(schema, "maxItems")} do
      {minimum, maximum}
      when is_integer(minimum) and minimum >= 0 and is_integer(maximum) and maximum >= 0 and
             minimum > maximum ->
        ["#{path}.minItems must be less than or equal to maxItems" | errors]

      _ ->
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

  defp normalize_object_params(properties, params) do
    Enum.reduce(properties, params, fn {key, prop_schema}, acc ->
      normalize_object_param(acc, key, prop_schema)
    end)
  end

  defp normalize_object_param(acc, key, prop_schema) do
    if Map.has_key?(acc, key) do
      normalize_present_object_param(acc, key, prop_schema)
    else
      maybe_put_default(acc, key, prop_schema)
    end
  end

  defp normalize_present_object_param(acc, key, prop_schema) do
    case Map.get(acc, key) do
      value when value in [nil, ""] ->
        # A blank form value means "not provided". Numeric blanks stay omitted so
        # add-ons can distinguish an explicit knob from runtime defaults.
        acc |> Map.delete(key) |> maybe_put_default_for_blank(key, prop_schema)

      value ->
        Map.put(acc, key, normalize_value(prop_schema, value))
    end
  end

  defp maybe_put_default(acc, key, prop_schema) do
    case Map.get(prop_schema, "default") do
      nil -> acc
      default -> Map.put(acc, key, default)
    end
  end

  defp maybe_put_default_for_blank(acc, _key, %{"type" => type})
       when type in ["integer", "number"], do: acc

  defp maybe_put_default_for_blank(acc, key, prop_schema),
    do: maybe_put_default(acc, key, prop_schema)

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
