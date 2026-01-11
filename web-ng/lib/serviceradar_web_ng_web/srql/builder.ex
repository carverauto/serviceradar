defmodule ServiceRadarWebNGWeb.SRQL.Builder do
  @moduledoc false

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @max_limit 500
  @allowed_filter_ops ["contains", "not_contains", "equals", "not_equals"]
  @allowed_downsample_aggs ["avg", "min", "max", "sum", "count"]

  @type state :: map()

  def default_state(entity, limit \\ 100) when is_binary(entity) do
    config = Catalog.entity(entity)

    %{
      "entity" => config.id,
      "time" => config.default_time || "",
      "bucket" => config[:default_bucket] || "",
      "agg" => config[:default_agg] || "avg",
      "series" => config[:default_series_field] || "",
      "sort_field" => config.default_sort_field,
      "sort_dir" => config.default_sort_dir,
      "limit" => normalize_limit(limit),
      "filters" => [
        %{
          "field" => config.default_filter_field,
          "op" => "contains",
          "value" => ""
        }
      ]
    }
  end

  def build(%{} = state) do
    entity = Map.get(state, "entity", "devices")
    time = Map.get(state, "time", "")
    bucket = Map.get(state, "bucket", "")
    agg = Map.get(state, "agg", "avg")
    series = Map.get(state, "series", "")
    sort_field = Map.get(state, "sort_field", default_sort_field(entity))
    sort_dir = Map.get(state, "sort_dir", "desc")
    limit = normalize_limit(Map.get(state, "limit", 100))
    filters = normalize_filters(entity, Map.get(state, "filters", []))

    tokens =
      ["in:#{entity}"]
      |> maybe_add_time(time)
      |> maybe_add_downsample(entity, time, bucket, agg, series)
      |> maybe_add_filters(filters)
      |> maybe_add_sort(sort_field, sort_dir)
      |> Kernel.++(["limit:#{limit}"])

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
         :ok <- validate_filter_fields(parts.entity, parts.filters),
         :ok <- validate_downsample(parts.entity, parts.bucket, parts.agg, parts.series) do
      {:ok,
       %{
         "entity" => parts.entity,
         "time" => parts.time,
         "bucket" => parts.bucket,
         "agg" => parts.agg,
         "series" => parts.series,
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
      state
      |> Map.get("entity", "devices")
      |> safe_to_string()
      |> String.trim()
      |> case do
        "" -> "devices"
        value -> value
      end

    config = Catalog.entity(entity)

    sort_dir =
      case Map.get(state, "sort_dir") do
        "asc" -> "asc"
        _ -> "desc"
      end

    filters = normalize_filters(entity, Map.get(state, "filters", []))

    bucket = normalize_bucket(config, Map.get(state, "bucket"))
    agg = normalize_agg(config, Map.get(state, "agg"))
    series = normalize_series_field(config, Map.get(state, "series"))

    time =
      state
      |> Map.get("time", "")
      |> normalize_time()
      |> ensure_downsample_time(config, bucket)

    %{
      "entity" => config.id,
      "time" => time,
      "bucket" => bucket,
      "agg" => agg,
      "series" => series,
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

  defp normalize_bucket(%{downsample: true} = config, value) do
    candidate =
      value
      |> safe_to_string()
      |> String.trim()

    default = safe_to_string(Map.get(config, :default_bucket) || "")

    cond do
      candidate == "" -> default
      Regex.match?(~r/^\d+(?:s|m|h|d)$/, candidate) -> candidate
      true -> default
    end
  end

  defp normalize_bucket(_config, _), do: ""

  defp normalize_agg(%{downsample: true} = config, value) do
    candidate =
      value
      |> safe_to_string()
      |> String.trim()
      |> String.downcase()

    default = safe_to_string(Map.get(config, :default_agg) || "avg")

    if candidate in @allowed_downsample_aggs, do: candidate, else: default
  end

  defp normalize_agg(_config, _), do: "avg"

  defp normalize_series_field(%{downsample: true} = config, value) do
    candidate =
      value
      |> safe_to_string()
      |> String.trim()

    allowed = Map.get(config, :series_fields) || Map.get(config, "series_fields")
    default = safe_to_string(Map.get(config, :default_series_field) || "")

    cond do
      candidate == "" -> default
      is_list(allowed) and candidate in allowed -> candidate
      is_nil(allowed) -> candidate
      true -> default
    end
  end

  defp normalize_series_field(_config, _), do: ""

  defp ensure_downsample_time(time, %{downsample: true} = config, bucket) do
    if bucket != "" and time == "" do
      safe_to_string(config.default_time || "last_24h")
    else
      time
    end
  end

  defp ensure_downsample_time(time, _config, _bucket), do: time

  defp normalize_sort_field(entity, field) when is_binary(field) do
    field = String.trim(field)

    allowed = allowed_sort_fields(entity)

    cond do
      is_list(allowed) and Enum.member?(allowed, field) -> field
      field != "" and is_nil(allowed) -> field
      true -> default_sort_field(entity)
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

  defp allowed_sort_fields(entity) do
    case Catalog.entity(entity) do
      %{id: id} when id in ["devices", "gateways"] ->
        if id == "gateways" do
          ["last_seen", "gateway_id", "status", "agent_count", "checker_count"]
        else
          ["last_seen", "hostname", "ip", "uid"]
        end

      _ ->
        nil
    end
  end

  defp allowed_search_fields(entity) do
    case Catalog.entity(entity) do
      %{filter_fields: []} -> nil
      %{filter_fields: fields} when is_list(fields) -> fields
      _ -> nil
    end
  end

  defp default_sort_field(entity) do
    Catalog.entity(entity).default_sort_field
  end

  defp default_search_field(entity) do
    case Catalog.entity(entity).default_filter_field do
      "" -> "field"
      value -> value
    end
  end

  defp maybe_add_time(tokens, ""), do: tokens
  defp maybe_add_time(tokens, nil), do: tokens
  defp maybe_add_time(tokens, time), do: tokens ++ ["time:#{time}"]

  defp maybe_add_downsample(tokens, entity, time, bucket, agg, series) do
    config = Catalog.entity(entity)

    cond do
      not Map.get(config, :downsample, false) ->
        tokens

      safe_to_string(bucket) |> String.trim() == "" ->
        tokens

      safe_to_string(time) |> String.trim() == "" ->
        tokens

      true ->
        bucket = safe_to_string(bucket) |> String.trim()
        agg = safe_to_string(agg) |> String.trim() |> String.downcase()
        series = safe_to_string(series) |> String.trim()

        tokens =
          tokens
          |> Kernel.++(["bucket:#{bucket}"])
          |> Kernel.++(if agg != "", do: ["agg:#{agg}"], else: [])

        if series != "" do
          tokens ++ ["series:#{series}"]
        else
          tokens
        end
    end
  end

  defp maybe_add_sort(tokens, "", _dir), do: tokens
  defp maybe_add_sort(tokens, nil, _dir), do: tokens
  defp maybe_add_sort(tokens, field, dir), do: tokens ++ ["sort:#{field}:#{dir}"]

  defp maybe_add_filters(tokens, filters) when is_list(filters) do
    Enum.reduce(filters, tokens, fn %{"field" => field, "op" => op, "value" => value}, acc ->
      case build_filter_token(field, op, value) do
        nil -> acc
        token -> acc ++ [token]
      end
    end)
  end

  defp build_filter_token(field, op, value) do
    field = field |> safe_to_string() |> String.trim()
    value = value |> safe_to_string() |> String.trim()

    if value == "" or field == "" do
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
      bucket: "",
      agg: "avg",
      series: "",
      sort_field: nil,
      sort_dir: "desc",
      limit: 100,
      filters: []
    }

    Enum.reduce_while(tokens, {:ok, parts}, fn token, {:ok, acc} ->
      case parse_token(token, acc) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
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

  defp parse_token(token, acc) do
    case parse_known_token(token, acc) do
      {:ok, updated} -> {:ok, updated}
      :unknown -> parse_filter_token(token, acc)
    end
  end

  defp parse_known_token(token, acc) do
    cond do
      String.starts_with?(token, "in:") ->
        entity = String.replace_prefix(token, "in:", "")
        {:ok, %{acc | entity: entity}}

      String.starts_with?(token, "time:") ->
        time = String.replace_prefix(token, "time:", "")
        {:ok, %{acc | time: time}}

      String.starts_with?(token, "bucket:") ->
        bucket = String.replace_prefix(token, "bucket:", "")
        {:ok, %{acc | bucket: bucket}}

      String.starts_with?(token, "agg:") ->
        agg = String.replace_prefix(token, "agg:", "")
        {:ok, %{acc | agg: agg}}

      String.starts_with?(token, "series:") ->
        series = String.replace_prefix(token, "series:", "")
        {:ok, %{acc | series: series}}

      String.starts_with?(token, "sort:") ->
        parse_sort_token(token, acc)

      String.starts_with?(token, "limit:") ->
        limit = String.replace_prefix(token, "limit:", "")
        {:ok, %{acc | limit: normalize_limit(limit)}}

      true ->
        :unknown
    end
  end

  defp parse_sort_token(token, acc) do
    sort = String.replace_prefix(token, "sort:", "")

    case String.split(sort, ":", parts: 2) do
      [field, dir] -> {:ok, %{acc | sort_field: field, sort_dir: dir}}
      _ -> {:error, :invalid_sort}
    end
  end

  defp parse_filter_token(token, acc) do
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

        {:ok, %{acc | filters: acc.filters ++ [filter]}}

      _ ->
        {:error, :invalid_token}
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
    known_prefixes = ["in:", "time:", "bucket:", "agg:", "series:", "sort:", "limit:"]

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

  defp validate_downsample(entity, bucket, agg, series) do
    config = Catalog.entity(entity)

    if Map.get(config, :downsample, false) do
      validate_downsample_fields(config, bucket, agg, series)
    else
      validate_downsample_unsupported(bucket)
    end
  end

  defp validate_downsample_fields(config, bucket, agg, series) do
    bucket = safe_to_string(bucket) |> String.trim()
    agg = safe_to_string(agg) |> String.trim() |> String.downcase()
    series = safe_to_string(series) |> String.trim()

    cond do
      bucket == "" ->
        :ok

      not valid_bucket?(bucket) ->
        {:error, {:invalid_bucket, bucket}}

      agg != "" and agg not in @allowed_downsample_aggs ->
        {:error, {:invalid_agg, agg}}

      true ->
        validate_downsample_series(config, series)
    end
  end

  defp validate_downsample_series(config, series) do
    allowed = Map.get(config, :series_fields) || Map.get(config, "series_fields")

    if series != "" and is_list(allowed) and series not in allowed do
      {:error, {:unsupported_series_field, series}}
    else
      :ok
    end
  end

  defp validate_downsample_unsupported(bucket) do
    if safe_to_string(bucket) |> String.trim() != "" do
      {:error, :downsample_not_supported}
    else
      :ok
    end
  end

  defp valid_bucket?(bucket) do
    Regex.match?(~r/^\d+(?:s|m|h|d)$/, bucket)
  end

  defp validate_filter_fields(entity, filters) when entity in ["devices", "gateways"] do
    allowed = allowed_search_fields(entity)

    invalid = invalid_filter_fields(filters, allowed)

    if invalid == [], do: :ok, else: {:error, {:unsupported_filter_fields, invalid}}
  end

  defp validate_filter_fields(entity, filters) do
    case allowed_search_fields(entity) do
      nil ->
        if entity == "" do
          {:error, :missing_entity}
        else
          _ = filters
          :ok
        end

      allowed ->
        invalid = invalid_filter_fields(filters, allowed)

        if invalid == [], do: :ok, else: {:error, {:unsupported_filter_fields, invalid}}
    end
  end

  defp invalid_filter_fields(filters, allowed) do
    filters
    |> Enum.map(&Map.get(&1, "field"))
    |> Enum.reject(fn field -> is_nil(field) or field in allowed end)
  end

  defp normalize_filters(entity, filters) when is_list(filters) do
    filters
    |> Enum.map(fn
      %{"field" => field, "op" => op, "value" => value} ->
        %{
          "field" => normalize_filter_field(entity, field),
          "op" => normalize_filter_op(op),
          "value" => value |> safe_to_string()
        }

      %{} = other ->
        %{
          "field" => normalize_filter_field(entity, Map.get(other, "field")),
          "op" => normalize_filter_op(Map.get(other, "op")),
          "value" => Map.get(other, "value", "") |> safe_to_string()
        }

      other ->
        %{
          "field" => default_search_field(entity),
          "op" => "contains",
          "value" => safe_to_string(other)
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

    allowed = allowed_search_fields(entity)

    cond do
      is_list(allowed) and Enum.member?(allowed, field) -> field
      field != "" and is_nil(allowed) -> field
      true -> default_search_field(entity)
    end
  end

  defp normalize_filter_field(entity, _), do: default_search_field(entity)

  defp normalize_filter_op(op) when op in @allowed_filter_ops, do: op
  defp normalize_filter_op(_), do: "contains"

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_float(value), do: :erlang.float_to_binary(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)

  defp safe_to_string(value) when is_list(value) do
    if Enum.all?(value, &is_integer/1) do
      to_string(value)
    else
      inspect(value)
    end
  end

  defp safe_to_string(value), do: inspect(value)
end
