defmodule ServiceRadarWebNGWeb.SRQL.Builder do
  @moduledoc false

  @max_limit 500
  @allowed_filter_ops ["contains", "not_contains", "equals", "not_equals"]

  @type state :: map()

  def default_state(entity, limit \\ 100) when entity in ["devices", "pollers"] do
    %{
      "entity" => entity,
      "time" => "",
      "sort_field" => default_sort_field(entity),
      "sort_dir" => "desc",
      "limit" => normalize_limit(limit),
      "filters" => [
        %{
          "field" => default_search_field(entity),
          "op" => "contains",
          "value" => ""
        }
      ]
    }
  end

  def build(%{} = state) do
    entity = Map.get(state, "entity", "devices")
    time = Map.get(state, "time", "")
    sort_field = Map.get(state, "sort_field", default_sort_field(entity))
    sort_dir = Map.get(state, "sort_dir", "desc")
    limit = normalize_limit(Map.get(state, "limit", 100))
    filters = normalize_filters(entity, Map.get(state, "filters", []))

    tokens =
      ["in:#{entity}"]
      |> maybe_add_time(time)
      |> maybe_add_filters(filters)
      |> Kernel.++(["sort:#{sort_field}:#{sort_dir}", "limit:#{limit}"])

    Enum.join(tokens, " ")
  end

  def update(%{} = state, %{} = params) do
    state
    |> Map.merge(stringify_map(params))
    |> normalize_state()
  end

  def parse(query) when is_binary(query) do
    tokens =
      query
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    with {:ok, parts} <- parse_tokens(tokens),
         :ok <- reject_unknown_tokens(tokens, parts),
         :ok <- validate_filter_fields(parts.entity, parts.filters) do
      {:ok,
       %{
         "entity" => parts.entity,
         "time" => parts.time,
         "sort_field" => parts.sort_field,
         "sort_dir" => parts.sort_dir,
         "limit" => parts.limit,
         "filters" => parts.filters
       }
       |> normalize_state()}
    end
  end

  def parse(_), do: {:error, :invalid_query}

  defp normalize_state(%{} = state) do
    entity =
      case Map.get(state, "entity") do
        value when value in ["devices", "pollers"] -> value
        _ -> "devices"
      end

    sort_dir =
      case Map.get(state, "sort_dir") do
        "asc" -> "asc"
        _ -> "desc"
      end

    filters = normalize_filters(entity, Map.get(state, "filters", []))

    %{
      "entity" => entity,
      "time" => normalize_time(Map.get(state, "time", "")),
      "sort_field" => normalize_sort_field(entity, Map.get(state, "sort_field")),
      "sort_dir" => sort_dir,
      "limit" => normalize_limit(Map.get(state, "limit", 100)),
      "filters" => filters
    }
  end

  defp normalize_time(nil), do: ""

  defp normalize_time(time) when time in ["", "last_1h", "last_24h", "last_7d", "last_30d"] do
    time
  end

  defp normalize_time(_), do: ""

  defp normalize_sort_field(entity, field) when is_binary(field) do
    field = String.trim(field)

    if field in allowed_sort_fields(entity) do
      field
    else
      default_sort_field(entity)
    end
  end

  defp normalize_sort_field(entity, _), do: default_sort_field(entity)

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {value, ""} -> normalize_limit(value)
      _ -> 100
    end
  end

  defp normalize_limit(_), do: 100

  defp allowed_sort_fields("devices"), do: ["last_seen", "hostname", "ip", "device_id"]

  defp allowed_sort_fields("pollers"),
    do: ["last_seen", "poller_id", "status", "agent_count", "checker_count"]

  defp allowed_sort_fields(_), do: allowed_sort_fields("devices")

  defp allowed_search_fields("devices"),
    do: ["hostname", "ip", "device_id", "poller_id", "agent_id"]

  defp allowed_search_fields("pollers"),
    do: ["poller_id", "status", "component_id", "registration_source"]

  defp allowed_search_fields(_), do: allowed_search_fields("devices")

  defp default_sort_field("pollers"), do: "last_seen"
  defp default_sort_field(_), do: "last_seen"

  defp default_search_field("pollers"), do: "poller_id"
  defp default_search_field(_), do: "hostname"

  defp maybe_add_time(tokens, ""), do: tokens
  defp maybe_add_time(tokens, nil), do: tokens
  defp maybe_add_time(tokens, time), do: tokens ++ ["time:#{time}"]

  defp maybe_add_filters(tokens, filters) when is_list(filters) do
    Enum.reduce(filters, tokens, fn %{"field" => field, "op" => op, "value" => value}, acc ->
      value = value |> to_string() |> String.trim()

      if value == "" do
        acc
      else
        escaped = String.replace(value, " ", "\\ ")

        token =
          case op do
            "equals" -> "#{field}:#{escaped}"
            "not_equals" -> "!#{field}:#{escaped}"
            "not_contains" -> "!#{field}:%#{escaped}%"
            _ -> "#{field}:%#{escaped}%"
          end

        acc ++ [token]
      end
    end)
  end

  defp stringify_map(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp parse_tokens(tokens) do
    parts = %{
      entity: nil,
      time: "",
      sort_field: nil,
      sort_dir: "desc",
      limit: 100,
      filters: []
    }

    Enum.reduce_while(tokens, {:ok, parts}, fn token, {:ok, acc} ->
      cond do
        String.starts_with?(token, "in:") ->
          entity = String.replace_prefix(token, "in:", "")
          {:cont, {:ok, %{acc | entity: entity}}}

        String.starts_with?(token, "time:") ->
          time = String.replace_prefix(token, "time:", "")
          {:cont, {:ok, %{acc | time: time}}}

        String.starts_with?(token, "sort:") ->
          sort = String.replace_prefix(token, "sort:", "")

          case String.split(sort, ":", parts: 2) do
            [field, dir] ->
              {:cont, {:ok, %{acc | sort_field: field, sort_dir: dir}}}

            _ ->
              {:halt, {:error, :invalid_sort}}
          end

        String.starts_with?(token, "limit:") ->
          limit = String.replace_prefix(token, "limit:", "")
          {:cont, {:ok, %{acc | limit: normalize_limit(limit)}}}

        true ->
          case String.split(token, ":", parts: 2) do
            [field, value] ->
              {field, negated} = parse_filter_field(field)
              value = String.trim(value)
              {op, final_value} = parse_filter_value(negated, value)

              filter = %{
                "field" => String.downcase(field),
                "op" => op,
                "value" => final_value
              }

              {:cont, {:ok, %{acc | filters: acc.filters ++ [filter]}}}

            _ ->
              {:halt, {:error, :invalid_token}}
          end
      end
    end)
    |> case do
      {:ok, %{entity: nil}} ->
        {:error, :missing_entity}

      {:ok, %{sort_field: nil} = parts} ->
        {:ok, %{parts | sort_field: default_sort_field(parts.entity)}}

      other ->
        other
    end
  end

  defp unwrap_like("%" <> rest) do
    rest
    |> String.trim_trailing("%")
    |> String.replace("\\ ", " ")
  end

  defp unwrap_like(value), do: value

  defp parse_filter_field(field) when is_binary(field) do
    field = String.trim(field)

    case String.starts_with?(field, "!") do
      true -> {String.replace_prefix(field, "!", ""), true}
      false -> {field, false}
    end
  end

  defp parse_filter_field(_), do: {"", false}

  defp parse_filter_value(negated, value) do
    if String.contains?(value, "%") do
      op = if negated, do: "not_contains", else: "contains"
      {op, unwrap_like(value)}
    else
      op = if negated, do: "not_equals", else: "equals"
      {op, String.replace(value, "\\ ", " ")}
    end
  end

  defp reject_unknown_tokens(tokens, parts) do
    known_prefixes = ["in:", "time:", "sort:", "limit:"]

    unknown =
      Enum.reject(tokens, fn token ->
        Enum.any?(known_prefixes, &String.starts_with?(token, &1)) or
          Enum.any?(parts.filters, fn %{"field" => field} ->
            String.starts_with?(token, field <> ":") or
              String.starts_with?(token, "!" <> field <> ":")
          end)
      end)

    if unknown == [], do: :ok, else: {:error, {:unsupported_tokens, unknown}}
  end

  defp validate_filter_fields(entity, filters) when entity in ["devices", "pollers"] do
    allowed = allowed_search_fields(entity)

    invalid =
      filters
      |> Enum.map(&Map.get(&1, "field"))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 in allowed))

    if invalid == [], do: :ok, else: {:error, {:unsupported_filter_fields, invalid}}
  end

  defp validate_filter_fields(_entity, _filters), do: {:error, :missing_entity}

  defp normalize_filters(entity, filters) when is_list(filters) do
    filters
    |> Enum.map(fn
      %{"field" => field, "op" => op, "value" => value} ->
        %{
          "field" => normalize_filter_field(entity, field),
          "op" => normalize_filter_op(op),
          "value" => value |> to_string()
        }

      %{} = other ->
        %{
          "field" => normalize_filter_field(entity, Map.get(other, "field")),
          "op" => normalize_filter_op(Map.get(other, "op")),
          "value" => Map.get(other, "value", "") |> to_string()
        }

      other ->
        %{
          "field" => default_search_field(entity),
          "op" => "contains",
          "value" => to_string(other)
        }
    end)
  end

  defp normalize_filters(entity, %{} = filters_by_index) do
    filters_by_index
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(to_string(k)) do
        {i, ""} -> i
        _ -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
    |> then(&normalize_filters(entity, &1))
  end

  defp normalize_filters(entity, _), do: normalize_filters(entity, [])

  defp normalize_filter_field(entity, field) when is_binary(field) do
    field = String.trim(field)

    if field in allowed_search_fields(entity) do
      field
    else
      default_search_field(entity)
    end
  end

  defp normalize_filter_field(entity, _), do: default_search_field(entity)

  defp normalize_filter_op(op) when op in @allowed_filter_ops, do: op
  defp normalize_filter_op(_), do: "contains"
end
