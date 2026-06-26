defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Builder do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import Phoenix.Component, only: [assign: 3, to_form: 1]

  alias AshPhoenix.Form
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  def default_builder_state do
    config = Catalog.entity("interfaces")

    %{
      "filters" => [
        %{
          "field" => config.default_filter_field,
          "op" => "contains",
          "value" => ""
        }
      ]
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
          # Query is too complex for the builder
          {default_builder_state(), false}
      end
    end
  end

  def parse_filters_from_query(query) do
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

  def parse_filter_token(token) do
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

        {op, final_value} = parse_filter_value(negated, value)

        %{
          "field" => field_name,
          "op" => op,
          "value" => final_value
        }

      _ ->
        nil
    end
  end

  def parse_filter_value(negated, value) do
    if String.contains?(value, "%") do
      op = if negated, do: "not_contains", else: "contains"
      unwrapped = unwrap_like(value)
      {op, unwrapped}
    else
      op = if negated, do: "not_equals", else: "equals"
      {op, value}
    end
  end

  def unwrap_like("%" <> rest) do
    rest
    |> String.trim_trailing("%")
    |> String.replace("\\ ", " ")
  end

  def unwrap_like(value), do: value

  def update_builder(builder, params) do
    builder
    |> Map.merge(stringify_params(params))
    |> normalize_builder_filters()
  end

  def stringify_params(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  def normalize_builder_filters(builder) do
    config = Catalog.entity("interfaces")

    filters =
      builder
      |> Map.get("filters", %{})
      |> normalize_filters_list(config)

    Map.put(builder, "filters", filters)
  end

  def normalize_filters_list(filters, config) when is_list(filters) do
    Enum.map(filters, fn filter ->
      %{
        "field" => normalize_filter_field(filter["field"], config),
        "op" => normalize_filter_op(filter["op"]),
        "value" => filter["value"] || ""
      }
    end)
  end

  def normalize_filters_list(filters_by_index, config) when is_map(filters_by_index) do
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

  def normalize_filters_list(_, config) do
    [%{"field" => config.default_filter_field, "op" => "contains", "value" => ""}]
  end

  def normalize_filter_field(nil, config), do: config.default_filter_field
  def normalize_filter_field("", config), do: config.default_filter_field
  def normalize_filter_field(field, _config), do: field

  def maybe_set_target_query(form, nil), do: form
  def maybe_set_target_query(form, ""), do: form

  def maybe_set_target_query(form, target_query) do
    Form.validate(form, %{"target_query" => target_query})
  end

  def normalize_filter_op(op) when op in ["contains", "not_contains", "equals", "not_equals"], do: op

  def normalize_filter_op(_), do: "contains"

  def build_target_query(builder) do
    filters = Map.get(builder, "filters", [])

    filters
    |> Enum.map(&build_filter_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def build_filter_token(%{"field" => field, "op" => op, "value" => value}) do
    field = String.trim(field || "")
    value = String.trim(value || "")

    if field == "" or value == "" do
      nil
    else
      escaped = String.replace(value, " ", "\\ ")

      case op do
        "equals" -> "#{field}:#{escaped}"
        "not_equals" -> "!#{field}:#{escaped}"
        "not_contains" -> "!#{field}:%#{escaped}%"
        _ -> "#{field}:%#{escaped}%"
      end
    end
  end

  def build_filter_token(_), do: nil

  def maybe_sync_builder_to_form(socket) do
    if socket.assigns.builder_sync do
      builder = socket.assigns.builder
      query = build_target_query(builder)

      ash_form = Form.validate(socket.assigns.ash_form, %{"target_query" => query})

      socket
      |> assign(:ash_form, ash_form)
      |> assign(:form, to_form(ash_form))
      |> Targeting.assign_target_preview(query)
    else
      socket
    end
  end
end
