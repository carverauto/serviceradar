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

  def values(dashboard, current_values) do
    current_values = current_values || %{}

    Map.new(list(dashboard), fn variable ->
      value = Map.get(current_values, variable.name) || variable.default || List.first(variable.options) || ""
      {variable.name, to_string(value)}
    end)
  end

  def substitute(query, values) when is_binary(query) and is_map(values) do
    Regex.replace(~r/\$\{([a-zA-Z][a-zA-Z0-9_-]*)\}/, query, fn _match, name ->
      Map.get(values, name, "")
    end)
  end

  def substitute(query, _values), do: query

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
        default: default
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

  defp normalize_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "_")
  end
end
