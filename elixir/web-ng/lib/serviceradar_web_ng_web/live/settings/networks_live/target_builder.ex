defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.TargetBuilder do
  @moduledoc false

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  def default_builder_state do
    %{"filters" => [default_filter()]}
  end

  def default_filter do
    config = Catalog.entity("devices")

    %{
      "field" => config.default_filter_field,
      "op" => "contains",
      "value" => ""
    }
  end

  def parse_target_query_to_builder(nil), do: {default_builder_state(), true}
  def parse_target_query_to_builder(""), do: {default_builder_state(), true}

  def parse_target_query_to_builder(query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {default_builder_state(), true}
    else
      case parse_filters_from_query(query) do
        {:ok, filters} when filters != [] ->
          {%{"filters" => filters}, true}

        _ ->
          {default_builder_state(), false}
      end
    end
  end

  def update_builder(builder, params) do
    builder
    |> Map.merge(stringify_params(params))
    |> normalize_builder_filters()
  end

  def build_target_query(builder) do
    builder
    |> Map.get("filters", [])
    |> Enum.map(&build_filter_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp parse_filters_from_query(query) do
    known_prefixes = ["in:", "limit:", "sort:", "time:"]

    tokens =
      query
      |> String.split(~r/(?<!\\)\s+/, trim: true)
      |> Enum.reject(fn token ->
        Enum.any?(known_prefixes, &String.starts_with?(token, &1))
      end)

    filters =
      tokens
      |> Enum.map(&parse_filter_token/1)
      |> Enum.reject(&is_nil/1)

    if length(filters) == length(tokens) do
      {:ok, filters}
    else
      {:error, :unsupported_query}
    end
  end

  defp parse_filter_token(token) do
    {field, negated} =
      if String.starts_with?(token, "!") do
        {String.replace_prefix(token, "!", ""), true}
      else
        {token, false}
      end

    case String.split(field, ":", parts: 2) do
      [field_name, value] ->
        field_name = String.trim(field_name)
        value = value |> String.trim() |> String.replace("\\ ", " ")

        {op, final_value} = parse_filter_value(field_name, negated, value)

        %{
          "field" => field_name,
          "op" => op,
          "value" => final_value
        }

      _ ->
        nil
    end
  end

  defp parse_filter_value(field, negated, value) do
    cond do
      list_filter_field?(field) ->
        normalized = value |> normalize_list_value() |> Enum.join(", ")
        {maybe_negate_op("equals", negated), normalized}

      String.contains?(value, "%") ->
        {maybe_negate_op("contains", negated), unwrap_like(value)}

      true ->
        {maybe_negate_op("equals", negated), value}
    end
  end

  defp maybe_negate_op("equals", true), do: "not_equals"
  defp maybe_negate_op("contains", true), do: "not_contains"
  defp maybe_negate_op(op, _), do: op

  defp unwrap_like("%" <> rest) do
    rest
    |> String.trim_trailing("%")
    |> String.replace("\\ ", " ")
  end

  defp unwrap_like(value), do: value

  defp list_filter_field?(field) when is_binary(field) do
    field in ["discovery_sources"]
  end

  defp list_filter_field?(_), do: false

  defp normalize_list_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp stringify_params(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp normalize_builder_filters(builder) do
    config = Catalog.entity("devices")

    filters =
      builder
      |> Map.get("filters", %{})
      |> normalize_filters_list(config)

    Map.put(builder, "filters", filters)
  end

  defp normalize_filters_list(filters, config) when is_list(filters) do
    Enum.map(filters, fn filter ->
      field = normalize_filter_field(filter["field"], config)

      %{
        "field" => field,
        "op" => normalize_filter_op(filter["op"], field),
        "value" => filter["value"] || ""
      }
    end)
  end

  defp normalize_filters_list(filters_by_index, config) when is_map(filters_by_index) do
    filters_by_index
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(to_string(k)) do
        {i, ""} -> i
        _ -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
    |> normalize_filters_list(config)
  end

  defp normalize_filters_list(_, config) do
    [%{"field" => config.default_filter_field, "op" => "contains", "value" => ""}]
  end

  defp normalize_filter_field(nil, config), do: config.default_filter_field
  defp normalize_filter_field("", config), do: config.default_filter_field
  defp normalize_filter_field(field, _config), do: field

  defp normalize_filter_op(op, field) do
    if list_filter_field?(field) do
      case op do
        "not_equals" -> "not_equals"
        "not_contains" -> "not_equals"
        "equals" -> "equals"
        "contains" -> "equals"
        _ -> "equals"
      end
    else
      case op do
        "contains" -> "contains"
        "not_contains" -> "not_contains"
        "equals" -> "equals"
        "not_equals" -> "not_equals"
        _ -> "contains"
      end
    end
  end

  defp build_filter_token(%{"field" => field, "op" => op, "value" => value}) do
    field = String.trim(field || "")
    value = String.trim(value || "")

    cond do
      field == "" or value == "" ->
        nil

      list_filter_field?(field) ->
        build_list_filter_token(field, op, value)

      true ->
        build_scalar_filter_token(field, op, value)
    end
  end

  defp build_filter_token(_), do: nil

  defp build_list_filter_token(field, op, value) do
    values =
      value
      |> normalize_list_value()
      |> Enum.map(&String.replace(&1, " ", "\\ "))

    token = Enum.join(values, ",")

    case op do
      "not_equals" -> "!#{field}:(#{token})"
      "not_contains" -> "!#{field}:(#{token})"
      _ -> "#{field}:(#{token})"
    end
  end

  defp build_scalar_filter_token(field, op, value) do
    escaped = String.replace(value, " ", "\\ ")

    case op do
      "equals" -> "#{field}:#{escaped}"
      "not_equals" -> "!#{field}:#{escaped}"
      "not_contains" -> "!#{field}:%#{escaped}%"
      _ -> "#{field}:%#{escaped}%"
    end
  end
end
