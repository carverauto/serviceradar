defmodule ServiceRadarWebNGWeb.SRQL.ScopeBuilder do
  @moduledoc """
  Bidirectional bridge between a raw SRQL device scope and the visual filter
  rows a builder UI edits.

  Shared by every settings page that scopes devices with SRQL — visibility
  profiles and composite checks today. It was extracted rather than copied
  because the token grammar here (escaping, negation, list-valued fields) is
  the kind of thing that silently diverges once there are two of it.

  `parse_query_to_builder/1` returns `{builder_state, in_sync?}`. When a query
  cannot be represented as filter rows, `in_sync?` is false and the caller must
  leave the raw string authoritative rather than overwriting it with a lossy
  round-trip. That single flag is what keeps a hand-written query from being
  silently rewritten by the visual editor.
  """

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  def default_builder_state do
    config = Catalog.entity("devices")

    %{
      "filters" => [
        %{"field" => config.default_filter_field, "op" => "contains", "value" => ""}
      ]
    }
  end

  def parse_query_to_builder(nil), do: {default_builder_state(), true}
  def parse_query_to_builder(""), do: {default_builder_state(), true}

  def parse_query_to_builder(query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {default_builder_state(), true}
    else
      case parse_filters_from_query(query) do
        {:ok, filters} when filters != [] ->
          {%{"filters" => filters}, true}

        # A query of only control tokens (`in:devices`, `limit:`, `sort:`) has no
        # filter rows to show, which the builder represents exactly. Reporting it
        # out of sync would make every entity-only scope — including the default
        # a new check opens with — render a "cannot represent this" warning.
        {:ok, []} ->
          {default_builder_state(), true}

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

  def build_query(builder) do
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
      |> Enum.reject(fn token -> Enum.any?(known_prefixes, &String.starts_with?(token, &1)) end)

    filters = tokens |> Enum.map(&parse_filter_token/1) |> Enum.reject(&is_nil/1)
    if length(filters) == length(tokens), do: {:ok, filters}, else: {:error, :unsupported_query}
  end

  defp parse_filter_token(token) do
    {field, negated} =
      if String.starts_with?(token, "!"), do: {String.replace_prefix(token, "!", ""), true}, else: {token, false}

    case String.split(field, ":", parts: 2) do
      [field_name, value] ->
        {op, final_value} = parse_filter_value(field_name, negated, value)
        %{"field" => String.trim(field_name), "op" => op, "value" => final_value}

      _ ->
        nil
    end
  end

  defp parse_filter_value(field, negated, value) do
    value = value |> String.trim() |> String.replace("\\ ", " ")

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
  defp unwrap_like("%" <> rest), do: rest |> String.trim_trailing("%") |> String.replace("\\ ", " ")
  defp unwrap_like(value), do: value
  defp list_filter_field?(field) when is_binary(field), do: field in ["discovery_sources"]
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
      %{"field" => field, "op" => normalize_filter_op(filter["op"], field), "value" => filter["value"] || ""}
    end)
  end

  defp normalize_filters_list(filters_by_index, config) when is_map(filters_by_index) do
    filters_by_index
    |> Enum.sort_by(fn {key, _value} -> parse_int(key, 0) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> normalize_filters_list(config)
  end

  defp normalize_filters_list(_, config),
    do: [%{"field" => config.default_filter_field, "op" => "contains", "value" => ""}]

  defp normalize_filter_field(nil, config), do: config.default_filter_field
  defp normalize_filter_field("", config), do: config.default_filter_field
  defp normalize_filter_field(field, _config), do: field

  defp normalize_filter_op(op, field) do
    if list_filter_field?(field) do
      if op in ["not_equals", "not_contains"], do: "not_equals", else: "equals"
    else
      if op in ["contains", "not_contains", "equals", "not_equals"], do: op, else: "contains"
    end
  end

  defp build_filter_token(%{"field" => field, "op" => op, "value" => value}) do
    field = String.trim(field || "")
    value = String.trim(value || "")

    cond do
      field == "" or value == "" -> nil
      list_filter_field?(field) -> build_list_filter_token(field, op, value)
      true -> build_scalar_filter_token(field, op, value)
    end
  end

  defp build_filter_token(_), do: nil

  defp stringify_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_params(_params), do: %{}

  defp parse_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp build_list_filter_token(field, op, value) do
    token = value |> normalize_list_value() |> Enum.map_join(",", &String.replace(&1, " ", "\\ "))
    if op in ["not_equals", "not_contains"], do: "!#{field}:(#{token})", else: "#{field}:(#{token})"
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
