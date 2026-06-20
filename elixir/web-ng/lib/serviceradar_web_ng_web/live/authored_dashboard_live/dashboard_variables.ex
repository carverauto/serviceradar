defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables do
  @moduledoc false

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries

  def list(%{variables: variables}) when is_map(variables) do
    variables
    |> Enum.map(fn {name, config} -> variable(name, config) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  def list(%{variables: variables}) when is_list(variables) do
    variables
    |> Enum.map(fn
      %{"name" => name} = config -> variable(name, config)
      %{name: name} = config -> variable(name, config)
      name when is_binary(name) -> variable(name, %{})
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def list(_dashboard), do: []

  def values(variables, current_values) when is_list(variables) do
    current_values = current_values || %{}

    Map.new(variables, fn variable ->
      requested = Map.get(current_values, variable.name)

      value =
        normalize_value(requested, variable) || normalize_value(variable.default, variable) ||
          List.first(variable.options) || ""

      {variable.name, to_string(value)}
    end)
  end

  def values(dashboard, current_values) do
    dashboard
    |> list()
    |> values(current_values)
  end

  def substitute(query, values) when is_binary(query) and is_map(values) do
    substitute(query, values, [])
  end

  def substitute(query, _values), do: query

  def substitute(query, values, variables) when is_binary(query) and is_map(values) do
    variable_map =
      variables
      |> List.wrap()
      |> Map.new(fn variable -> {variable.name, variable} end)

    query
    |> String.graphemes()
    |> substitute_tokens(values, variable_map, nil, [])
    |> IO.iodata_to_binary()
  end

  def substitute(query, _values, _variables), do: query

  defp substitute_tokens([], _values, _variable_map, _quote, acc), do: Enum.reverse(acc)

  defp substitute_tokens(["\\" = slash, next | rest], values, variable_map, quote, acc) when not is_nil(quote) do
    substitute_tokens(rest, values, variable_map, quote, [next, slash | acc])
  end

  defp substitute_tokens([quote | rest], values, variable_map, quote, acc) when quote in ["\"", "'", "`"] do
    substitute_tokens(rest, values, variable_map, nil, [quote | acc])
  end

  defp substitute_tokens([quote | rest], values, variable_map, nil, acc) when quote in ["\"", "'", "`"] do
    substitute_tokens(rest, values, variable_map, quote, [quote | acc])
  end

  defp substitute_tokens(["$", "{" | rest], values, variable_map, quote, acc) do
    case take_variable_name(rest, []) do
      {:ok, name, remaining} ->
        replacement =
          if is_nil(quote) do
            replacement_value(name, values, variable_map)
          else
            escaped_string_content(Map.get(values, name, ""), quote)
          end

        substitute_tokens(remaining, values, variable_map, quote, [replacement | acc])

      :error ->
        substitute_tokens(rest, values, variable_map, quote, ["{", "$" | acc])
    end
  end

  defp substitute_tokens([char | rest], values, variable_map, quote, acc) do
    substitute_tokens(rest, values, variable_map, quote, [char | acc])
  end

  defp take_variable_name(["}" | rest], chars) do
    name = chars |> Enum.reverse() |> IO.iodata_to_binary()

    if Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_-]*$/, name) do
      {:ok, name, rest}
    else
      :error
    end
  end

  defp take_variable_name([char | rest], chars) when char != "}" do
    take_variable_name(rest, [char | chars])
  end

  defp take_variable_name([], _chars), do: :error

  defp variable(name, config) when is_binary(name) do
    normalized = normalize_name(name)

    if normalized == "" do
      nil
    else
      config = if is_map(config), do: config, else: %{}
      options = options(config)
      default = default(config, options)

      %{
        name: normalized,
        label: config["label"] || config[:label] || SourceQueries.humanize_field(normalized),
        options: options,
        default: default,
        type: variable_type(config)
      }
    end
  end

  defp variable(_name, _config), do: nil

  defp options(config) do
    options = config["options"] || config[:options] || []

    options
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp default(config, options) do
    default = config["default"] || config[:default] || List.first(options) || ""
    to_string(default)
  end

  defp variable_type(config) do
    case config["type"] || config[:type] || "string" do
      value when value in ["integer", :integer, "int", :int] -> :integer
      value when value in ["number", :number, "float", :float] -> :number
      value when value in ["boolean", :boolean, "bool", :bool] -> :boolean
      _ -> :string
    end
  end

  defp normalize_value(nil, _variable), do: nil

  defp normalize_value(value, variable) do
    value = to_string(value)

    cond do
      variable.options != [] and value not in variable.options ->
        nil

      typed_value_valid?(value, variable.type) ->
        value

      true ->
        nil
    end
  end

  defp typed_value_valid?(value, :integer), do: match?({_number, ""}, Integer.parse(value))

  defp typed_value_valid?(value, :number),
    do: match?({_number, ""}, Float.parse(value)) or typed_value_valid?(value, :integer)

  defp typed_value_valid?(value, :boolean), do: String.downcase(value) in ["true", "false"]
  defp typed_value_valid?(_value, :string), do: true
  defp typed_value_valid?(_value, _type), do: false

  defp replacement_value(name, values, variable_map) do
    value = Map.get(values, name, "")
    variable = Map.get(variable_map, name)

    case variable && variable.type do
      :integer -> numeric_literal(value, :integer)
      :number -> numeric_literal(value, :number)
      :boolean -> boolean_literal(value)
      _ -> string_literal(value)
    end
  end

  defp numeric_literal(value, :integer) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> Integer.to_string(number)
      _ -> "0"
    end
  end

  defp numeric_literal(value, :number) do
    value = to_string(value)

    cond do
      match?({_number, ""}, Float.parse(value)) -> value
      match?({_number, ""}, Integer.parse(value)) -> value
      true -> "0"
    end
  end

  defp boolean_literal(value) do
    if String.downcase(to_string(value)) == "true", do: "true", else: "false"
  end

  defp string_literal(value) do
    ~s("#{escaped_string_content(value, "\"")}")
  end

  defp escaped_string_content(value, quote) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.replace("\\", "\\\\")
    |> String.replace(quote, "\\#{quote}")
  end

  defp normalize_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "_")
  end
end
