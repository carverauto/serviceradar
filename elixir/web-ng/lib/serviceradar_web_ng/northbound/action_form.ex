defmodule ServiceRadarWebNG.Northbound.ActionForm do
  @moduledoc """
  Helpers for rendering and parsing provider-neutral northbound action forms.
  """

  alias Ash.Error.Forbidden

  def default_params(action) do
    input =
      action
      |> schema_properties()
      |> Enum.reduce(%{}, fn {name, schema}, acc ->
        case schema_default(schema) do
          nil -> acc
          value -> Map.put(acc, name, stringify_form_value(value))
        end
      end)

    %{"action_id" => action.id, "input" => input}
  end

  def ensure_params(params, nil), do: params

  def ensure_params(params, action) do
    params
    |> Map.put("action_id", action.id)
    |> Map.update("input", default_params(action)["input"], &normalize_input_params/1)
  end

  def parse_input(action, params) do
    input = params |> Map.get("input", %{}) |> normalize_input_params()
    properties = schema_properties(action)
    required = schema_required(action)

    with :ok <- validate_required(required, input) do
      cast_input(properties, input)
    end
  end

  def schema_properties(%{input_schema: schema}), do: schema_properties(schema)

  def schema_properties(schema) when is_map(schema) do
    schema
    |> schema_value("properties")
    |> case do
      %{} = properties ->
        properties
        |> Enum.map(fn {name, schema} -> {to_string(name), normalize_schema(schema)} end)
        |> Enum.sort_by(fn {name, schema} ->
          {schema_order(schema), String.downcase(humanize(name))}
        end)

      _ ->
        []
    end
  end

  def schema_properties(_action_or_schema), do: []

  def schema_required(%{input_schema: schema}) when is_map(schema) do
    schema
    |> schema_value("required")
    |> case do
      values when is_list(values) -> MapSet.new(Enum.map(values, &to_string/1))
      _ -> MapSet.new()
    end
  end

  def schema_required(_action), do: MapSet.new()

  def schema_enum(schema) do
    schema
    |> schema_value("enum")
    |> case do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      _ -> []
    end
  end

  def schema_title(name, schema) do
    case schema_value(schema, "title") do
      value when is_binary(value) and value != "" -> value
      _ -> humanize(name)
    end
  end

  def schema_description(schema) do
    case schema_value(schema, "description") do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def schema_type(schema) do
    case schema_value(schema, "type") do
      value when is_binary(value) -> value
      values when is_list(values) -> values |> Enum.find(&(&1 != "null")) |> to_string()
      _ -> "string"
    end
  end

  def form_value(form, name) do
    input =
      case form[:input].value do
        %{} = value -> value
        _ -> %{}
      end

    Map.get(input, name)
  end

  def json_textarea_value(nil, "array"), do: "[]"
  def json_textarea_value(nil, _type), do: "{}"
  def json_textarea_value(value, _type) when is_binary(value), do: value
  def json_textarea_value(value, _type) when is_map(value) or is_list(value), do: Jason.encode!(value)
  def json_textarea_value(value, _type), do: to_string(value)

  def html_input_type("integer"), do: "number"
  def html_input_type("number"), do: "number"
  def html_input_type(_type), do: "text"

  def safety_badge_variant("destructive"), do: "error"
  def safety_badge_variant("read_only"), do: "info"
  def safety_badge_variant(_classification), do: "primary"

  def present_text?(value) when is_binary(value), do: String.trim(value) != ""
  def present_text?(_value), do: false

  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def short_id(_id), do: "created"

  def humanize(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def format_launch_error(reason, target_label \\ "target")

  def format_launch_error({:missing_required_input, field}, _target_label) do
    "#{humanize(field)} is required."
  end

  def format_launch_error({:invalid_integer, field}, _target_label) do
    "#{humanize(field)} must be a whole number."
  end

  def format_launch_error({:invalid_number, field}, _target_label) do
    "#{humanize(field)} must be a number."
  end

  def format_launch_error({reason, field}, _target_label) when reason in [:invalid_json, :invalid_json_type] do
    "#{humanize(field)} must be valid JSON."
  end

  def format_launch_error(:action_not_found, _target_label), do: "Select a launchable action."
  def format_launch_error(:targets_required, target_label), do: "Select at least one #{target_label}."

  def format_launch_error(:descriptor_not_found, _target_label), do: "The selected action no longer exists."
  def format_launch_error(:descriptor_disabled, _target_label), do: "The selected action is disabled."

  def format_launch_error({:provider_not_active, _status}, _target_label) do
    "The selected action integration is not active."
  end

  def format_launch_error(%Forbidden{}, _target_label), do: "You are not authorized to launch actions."
  def format_launch_error(_reason, _target_label), do: "Failed to create action invocation."

  defp validate_required(required, input) do
    missing =
      Enum.find(required, fn key ->
        key
        |> then(&Map.get(input, &1))
        |> blank_form_value?()
      end)

    if missing do
      {:error, {:missing_required_input, missing}}
    else
      :ok
    end
  end

  defp cast_input(properties, input) do
    Enum.reduce_while(properties, {:ok, %{}}, fn {name, schema}, {:ok, acc} ->
      raw = Map.get(input, name)

      case cast_value(raw, schema) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, reason} -> {:halt, {:error, {reason, name}}}
      end
    end)
  end

  defp cast_value(raw, schema) do
    type = schema_type(schema)

    cond do
      blank_form_value?(raw) ->
        {:ok, nil}

      type == "boolean" ->
        {:ok, raw in [true, "true", "on", "1", 1]}

      type == "integer" ->
        raw |> to_string() |> Integer.parse() |> parse_numeric_value(:invalid_integer)

      type == "number" ->
        raw |> to_string() |> Float.parse() |> parse_numeric_value(:invalid_number)

      type in ["object", "array"] ->
        cast_json_form_value(raw, type)

      true ->
        {:ok, to_string(raw)}
    end
  end

  defp parse_numeric_value({value, ""}, _error), do: {:ok, value}
  defp parse_numeric_value({_value, _rest}, error), do: {:error, error}
  defp parse_numeric_value(:error, error), do: {:error, error}

  defp cast_json_form_value(value, _type) when is_map(value) or is_list(value), do: {:ok, value}

  defp cast_json_form_value(value, type) do
    case Jason.decode(to_string(value)) do
      {:ok, decoded} when type == "object" and is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} when type == "array" and is_list(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_json_type}
      {:error, _error} -> {:error, :invalid_json}
    end
  end

  defp normalize_schema(%{} = schema), do: schema
  defp normalize_schema(_schema), do: %{}

  defp schema_value(schema, "properties") when is_map(schema),
    do: Map.get(schema, "properties") || Map.get(schema, :properties)

  defp schema_value(schema, "required") when is_map(schema), do: Map.get(schema, "required") || Map.get(schema, :required)

  defp schema_value(schema, "default") when is_map(schema), do: Map.get(schema, "default") || Map.get(schema, :default)
  defp schema_value(schema, "type") when is_map(schema), do: Map.get(schema, "type") || Map.get(schema, :type)

  defp schema_value(schema, "x-order") when is_map(schema), do: Map.get(schema, "x-order") || Map.get(schema, :"x-order")

  defp schema_value(schema, "order") when is_map(schema), do: Map.get(schema, "order") || Map.get(schema, :order)
  defp schema_value(schema, "enum") when is_map(schema), do: Map.get(schema, "enum") || Map.get(schema, :enum)
  defp schema_value(schema, "title") when is_map(schema), do: Map.get(schema, "title") || Map.get(schema, :title)

  defp schema_value(schema, "description") when is_map(schema),
    do: Map.get(schema, "description") || Map.get(schema, :description)

  defp schema_value(_schema, _key), do: nil

  defp schema_default(schema), do: schema_value(schema, "default")

  defp schema_order(schema) do
    case schema_value(schema, "x-order") || schema_value(schema, "order") do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> elem_or_default(0)
      _ -> 0
    end
  end

  defp elem_or_default({value, _rest}, _default), do: value
  defp elem_or_default(:error, default), do: default

  defp normalize_input_params(%{} = params), do: params
  defp normalize_input_params(_params), do: %{}

  defp blank_form_value?(nil), do: true
  defp blank_form_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_form_value?(_value), do: false

  defp stringify_form_value(value) when is_binary(value), do: value
  defp stringify_form_value(value) when is_boolean(value), do: to_string(value)
  defp stringify_form_value(value) when is_number(value), do: to_string(value)

  defp stringify_form_value(value) when is_map(value) or is_list(value) do
    Jason.encode!(value)
  end

  defp stringify_form_value(value), do: to_string(value)
end
