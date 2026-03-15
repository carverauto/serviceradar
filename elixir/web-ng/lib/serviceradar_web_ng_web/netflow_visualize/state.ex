defmodule ServiceRadarWebNGWeb.NetflowVisualize.State do
  @moduledoc false

  # Versioned, compressed URL state for /netflow.
  #
  # Format: "v1-" <> base64url(gzip(json))

  @version "v1"
  @prefix @version <> "-"

  @max_encoded_len 24_000
  @max_uncompressed_bytes 64_000

  @allowed_graph ~w(stacked stacked100 lines grid sankey)
  @allowed_units ~w(Bps bps pps pct)
  @allowed_limit_type ~w(avg max last)

  def default do
    %{
      "graph" => "stacked",
      "units" => "Bps",
      "time" => "last_1h",
      "dims" => [],
      "limit" => 12,
      "limit_type" => "avg",
      "truncate_v4" => 32,
      "truncate_v6" => 128,
      "bidirectional" => false,
      "previous_period" => false
    }
  end

  def decode_param(nil), do: {:ok, default()}
  def decode_param(""), do: {:ok, default()}

  def decode_param(value) when is_binary(value) do
    if String.length(value) > @max_encoded_len do
      {:error, :too_large}
    else
      decode(value)
    end
  end

  def decode_param(_), do: {:ok, default()}

  def encode_param(%{} = state) do
    with {:ok, normalized} <- normalize(state),
         {:ok, json} <- Jason.encode(normalized),
         gz when is_binary(gz) <- :zlib.gzip(json) do
      payload = Base.url_encode64(gz, padding: false)
      {:ok, @prefix <> payload}
    end
  rescue
    _ -> {:error, :encode_failed}
  end

  defp decode(<<@prefix, payload::binary>>) do
    with {:ok, gz} <- Base.url_decode64(payload, padding: false),
         json when is_binary(json) <- safe_gunzip(gz),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, normalized} <- normalize(decoded) do
      {:ok, normalized}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid}
    end
  end

  defp decode(_), do: {:error, :unsupported_version}

  defp safe_gunzip(gz) when is_binary(gz) do
    json = :zlib.gunzip(gz)

    if byte_size(json) > @max_uncompressed_bytes do
      raise ArgumentError, "nf state too large"
    end

    json
  end

  defp normalize(%{} = raw) do
    raw = stringify_keys(raw)

    state = Map.merge(default(), Map.take(raw, Map.keys(default())))

    with {:ok, graph} <- validate_enum(state["graph"], @allowed_graph),
         {:ok, units} <- validate_enum(state["units"], @allowed_units),
         {:ok, limit_type} <- validate_enum(state["limit_type"], @allowed_limit_type),
         {:ok, dims} <- validate_dims(state["dims"]),
         {:ok, limit} <- validate_int(state["limit"], 1, 50),
         {:ok, t4} <- validate_int(state["truncate_v4"], 0, 32),
         {:ok, t6} <- validate_int(state["truncate_v6"], 0, 128),
         {:ok, bidirectional} <- validate_bool(state["bidirectional"]),
         {:ok, previous_period} <- validate_bool(state["previous_period"]),
         {:ok, time} <- validate_time(state["time"]) do
      {:ok,
       %{
         "graph" => graph,
         "units" => units,
         "time" => time,
         "dims" => dims,
         "limit" => limit,
         "limit_type" => limit_type,
         "truncate_v4" => t4,
         "truncate_v6" => t6,
         "bidirectional" => bidirectional,
         "previous_period" => previous_period
       }}
    end
  end

  defp stringify_keys(%{} = map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end

  defp validate_enum(value, allowed) when is_list(allowed) do
    v =
      case value do
        a when is_atom(a) -> Atom.to_string(a)
        b when is_binary(b) -> b
        _ -> nil
      end

    v = if is_binary(v), do: String.trim(v)

    if v && Enum.member?(allowed, v) do
      {:ok, v}
    else
      {:error, :invalid_enum}
    end
  end

  defp validate_dims(value) do
    dims =
      value
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(6)

    {:ok, dims}
  end

  defp validate_int(value, min, max) do
    parsed =
      cond do
        is_integer(value) ->
          value

        is_binary(value) ->
          case Integer.parse(value) do
            {i, ""} -> i
            _ -> nil
          end

        true ->
          nil
      end

    if is_integer(parsed) and parsed >= min and parsed <= max do
      {:ok, parsed}
    else
      {:error, :invalid_int}
    end
  end

  defp validate_bool(value) when is_boolean(value), do: {:ok, value}
  defp validate_bool("true"), do: {:ok, true}
  defp validate_bool("false"), do: {:ok, false}
  defp validate_bool(_), do: {:error, :invalid_bool}

  # For now we accept either a relative token (last_1h, last_24h, etc.) or an absolute
  # bracket range (delegated to SRQL). We don't parse it here; we just bound size.
  defp validate_time(value) when is_binary(value) do
    v = String.trim(value)

    cond do
      v == "" -> {:ok, default()["time"]}
      String.length(v) > 128 -> {:error, :invalid_time}
      true -> {:ok, v}
    end
  end

  defp validate_time(_), do: {:ok, default()["time"]}
end
