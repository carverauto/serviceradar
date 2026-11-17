defmodule ServiceRadar.Camera.StreamAddressReduction do
  @moduledoc """
  The one definition of a "reduced" plugin result (design D2 of the
  `resolve-camera-stream-sources-at-edge` change).

  A camera stream address is a secret: a UniFi Protect RTSP(S) path alias works
  as a bearer token, and other camera addresses carry `user:password@`.
  `reduce/1` walks any term and, for every string value:

    1. If the string itself parses as JSON (an object, an array or a string), it
       decodes it, reduces the decoded value by this same rule and re-encodes the
       result in place. Nesting is followed through four decodes; a value still
       JSON-encoded beyond that depth is replaced by `"[reduced]"` and never
       left unreduced.
    2. It then rewrites every URL in the string: an `rtsp://` or `rtsps://` URL
       becomes its origin (`scheme://host[:port]`) and any other URL loses its
       userinfo. For detection, the JSON escapes `\\/`, `\\u002f`, `\\u003a` and
       `\\u0040` (in any letter case) count as `/`, `:` and `@`; a string with a
       rewritten URL is written back in unescaped form.

  Map keys named `rtsp_alias`, `rtsps_alias`, `rtspAlias` or `rtspsAlias`, in any
  letter case, are removed with their values.

  A string that needs none of this is returned unchanged, byte for byte, so a
  clean value is a fixed point: `reduce(reduce(x)) == reduce(x)`, and a value
  counts as holding a stream secret exactly when `reduce(value) != value`.
  `PluginResultIngestor` applies it to every plugin result on entry, and
  `ServiceRadar.Camera.StreamSecretScrubWorker` applies it, and counts with it,
  for rows stored before that.

  Structs (such as `DateTime`) are left as they are.
  """

  @max_json_depth 4
  @depth_marker "[reduced]"
  @alias_keys ~w(rtsp_alias rtsps_alias rtspalias rtspsalias)
  @origin_schemes ~w(rtsp rtsps)
  @escape_pattern ~r/\\(?:\/|[uU]002[fF]|[uU]003[aA]|[uU]0040)/
  @url_pattern ~r/[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s"'<>\\]+/

  @doc "The value that replaces a string still JSON-encoded beyond the nesting depth."
  @spec depth_marker() :: String.t()
  def depth_marker, do: @depth_marker

  @doc "Reduces `term` by the stream address rule. See the module documentation."
  @spec reduce(term()) :: term()
  def reduce(term), do: reduce(term, 0)

  defp reduce(%_{} = struct, _depth), do: struct

  defp reduce(map, depth) when is_map(map) do
    for {key, value} <- map, not alias_key?(key), into: %{} do
      {key, reduce(value, depth)}
    end
  end

  defp reduce(list, depth) when is_list(list), do: Enum.map(list, &reduce(&1, depth))
  defp reduce(string, depth) when is_binary(string), do: reduce_string(string, depth)
  defp reduce(other, _depth), do: other

  defp alias_key?(key) when is_binary(key), do: String.downcase(key) in @alias_keys
  defp alias_key?(key) when is_atom(key), do: alias_key?(Atom.to_string(key))
  defp alias_key?(_key), do: false

  defp reduce_string(string, depth) do
    case reduce_json(string, depth) do
      @depth_marker -> @depth_marker
      value -> reduce_urls(value)
    end
  end

  defp reduce_json(string, depth) do
    with true <- json_candidate?(string),
         {:ok, decoded} when is_map(decoded) or is_list(decoded) or is_binary(decoded) <-
           Jason.decode(string) do
      reduce_decoded(string, decoded, depth)
    else
      _ -> string
    end
  end

  defp reduce_decoded(_string, _decoded, depth) when depth >= @max_json_depth, do: @depth_marker

  defp reduce_decoded(string, decoded, depth) do
    case reduce(decoded, depth + 1) do
      ^decoded -> string
      reduced -> Jason.encode!(reduced)
    end
  end

  defp json_candidate?(string) do
    case String.trim_leading(string) do
      <<first, _rest::binary>> when first in [?{, ?[, ?"] -> true
      _ -> false
    end
  end

  defp reduce_urls(string) do
    if String.contains?(string, [":", "\\"]) do
      normalized = Regex.replace(@escape_pattern, string, &unescape/1)
      reduced = Regex.replace(@url_pattern, normalized, &reduce_url/1)

      if reduced == normalized, do: string, else: reduced
    else
      string
    end
  end

  defp unescape(escape) do
    case String.downcase(escape) do
      "\\/" -> "/"
      "\\u002f" -> "/"
      "\\u003a" -> ":"
      "\\u0040" -> "@"
    end
  end

  defp reduce_url(url) do
    [scheme, rest] = String.split(url, "://", parts: 2)
    {authority, tail} = split_authority(rest)
    host = authority |> String.split("@") |> List.last()

    cond do
      String.downcase(scheme) in @origin_schemes -> scheme <> "://" <> host
      host != authority -> scheme <> "://" <> host <> tail
      true -> url
    end
  end

  defp split_authority(rest) do
    case :binary.match(rest, ["/", "?", "#"]) do
      {index, _length} -> :erlang.split_binary(rest, index)
      :nomatch -> {rest, ""}
    end
  end
end
