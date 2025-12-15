defmodule ServiceRadarWebNGWeb.SRQL.Builder do
  @moduledoc false

  @max_limit 500

  @type state :: map()

  def default_state(entity, limit \\ 100) when entity in ["devices", "pollers"] do
    %{
      "entity" => entity,
      "time" => "",
      "sort_field" => default_sort_field(entity),
      "sort_dir" => "desc",
      "limit" => normalize_limit(limit),
      "search_field" => default_search_field(entity),
      "search" => ""
    }
  end

  def build(%{} = state) do
    entity = Map.get(state, "entity", "devices")
    time = Map.get(state, "time", "")
    sort_field = Map.get(state, "sort_field", default_sort_field(entity))
    sort_dir = Map.get(state, "sort_dir", "desc")
    limit = normalize_limit(Map.get(state, "limit", 100))
    search_field = Map.get(state, "search_field", default_search_field(entity))
    search = Map.get(state, "search", "") |> to_string() |> String.trim()

    tokens =
      ["in:#{entity}"]
      |> maybe_add_time(time)
      |> maybe_add_search(search_field, search)
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
         :ok <- reject_unknown_tokens(tokens, parts) do
      {:ok,
       %{
         "entity" => parts.entity,
         "time" => parts.time,
         "sort_field" => parts.sort_field,
         "sort_dir" => parts.sort_dir,
         "limit" => parts.limit,
         "search_field" => parts.search_field,
         "search" => parts.search
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

    %{
      "entity" => entity,
      "time" => normalize_time(Map.get(state, "time", "")),
      "sort_field" => normalize_sort_field(entity, Map.get(state, "sort_field")),
      "sort_dir" => sort_dir,
      "limit" => normalize_limit(Map.get(state, "limit", 100)),
      "search_field" => normalize_search_field(entity, Map.get(state, "search_field")),
      "search" => Map.get(state, "search", "") |> to_string()
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

  defp normalize_search_field(entity, field) when is_binary(field) do
    field = String.trim(field)

    if field in allowed_search_fields(entity) do
      field
    else
      default_search_field(entity)
    end
  end

  defp normalize_search_field(entity, _), do: default_search_field(entity)

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

  defp maybe_add_search(tokens, _field, ""), do: tokens
  defp maybe_add_search(tokens, _field, nil), do: tokens

  defp maybe_add_search(tokens, field, search) do
    search = String.replace(search, " ", "\\ ")
    tokens ++ ["#{field}:%#{search}%"]
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
      search_field: "",
      search: ""
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
              value = String.trim(value)
              {:cont, {:ok, %{acc | search_field: field, search: unwrap_like(value)}}}

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

  defp reject_unknown_tokens(tokens, parts) do
    known_prefixes = ["in:", "time:", "sort:", "limit:"]

    unknown =
      Enum.reject(tokens, fn token ->
        Enum.any?(known_prefixes, &String.starts_with?(token, &1)) or
          (parts.search_field != "" and String.starts_with?(token, parts.search_field <> ":"))
      end)

    if unknown == [], do: :ok, else: {:error, {:unsupported_tokens, unknown}}
  end
end
