defmodule ServiceRadar.Inventory.PackageUrl do
  @moduledoc false

  @type components :: %{
          type: String.t(),
          namespace: [String.t()],
          name: String.t(),
          version: String.t() | nil,
          qualifiers: %{String.t() => String.t()},
          subpath: [String.t()] | nil
        }

  @spec parse(term()) :: {:ok, components()} | :error
  def parse("pkg:" <> rest) do
    with {path_and_query, subpath} <- split_once(rest, "#"),
         {path_and_version, query} <- split_once(path_and_query, "?"),
         {path, version} <- split_rightmost(path_and_version, "@"),
         {raw_type, package_path} <- split_once(path, "/"),
         {:ok, type} <- decode_component(raw_type),
         true <- present?(type),
         {:ok, segments} <- decode_path(package_path),
         [name | namespace] <- Enum.reverse(segments),
         {:ok, qualifiers} <- decode_qualifiers(query),
         {:ok, subpath} <- decode_subpath(subpath),
         {:ok, version} <- decode_optional(version) do
      {:ok,
       %{
         type: String.downcase(type),
         namespace: Enum.reverse(namespace),
         name: name,
         version: version,
         qualifiers: qualifiers,
         subpath: subpath
       }}
    else
      _ -> :error
    end
  end

  def parse(_value), do: :error

  @spec canonical(components()) :: String.t()
  def canonical(%{
        type: type,
        namespace: namespace,
        name: name,
        version: version,
        qualifiers: qualifiers,
        subpath: subpath
      }) do
    path = Enum.map_join(namespace ++ [name], "/", &encode_component/1)
    version_part = if is_nil(version), do: "", else: "@#{encode_component(version)}"

    "pkg:#{String.downcase(type)}/#{path}#{version_part}#{canonical_qualifiers(qualifiers)}#{canonical_subpath(subpath)}"
  end

  @spec canonicalize(term()) :: {:ok, String.t()} | :error
  def canonicalize(value) do
    with {:ok, components} <- parse(value), do: {:ok, canonical(components)}
  end

  defp decode_path(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> decode_components()
    |> case do
      {:ok, []} -> :error
      result -> result
    end
  end

  defp decode_path(_path), do: :error

  defp decode_subpath(nil), do: {:ok, nil}

  defp decode_subpath(subpath) do
    subpath |> String.split("/", trim: true) |> decode_components()
  end

  defp decode_optional(nil), do: {:ok, nil}
  defp decode_optional(value), do: decode_component(value)

  defp decode_components(components) do
    components
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, decoded} ->
      case decode_component(component) do
        {:ok, ""} -> {:halt, :error}
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      :error -> :error
    end
  end

  defp decode_qualifiers(nil), do: {:ok, %{}}

  defp decode_qualifiers(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, qualifiers} ->
      {raw_key, raw_value} = split_once(entry, "=")

      with {:ok, key} <- decode_component(raw_key),
           true <- present?(key),
           {:ok, value} <- decode_optional(raw_value),
           normalized_key = String.downcase(key),
           false <- Map.has_key?(qualifiers, normalized_key) do
        {:cont, {:ok, Map.put(qualifiers, normalized_key, value || "")}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp decode_component(value) when is_binary(value) do
    if valid_percent_escapes?(value), do: {:ok, URI.decode(value)}, else: :error
  end

  defp decode_component(_value), do: :error

  defp valid_percent_escapes?(value), do: valid_percent_escapes?(value, 0)

  defp valid_percent_escapes?(value, index) when index >= byte_size(value), do: true

  defp valid_percent_escapes?(value, index) do
    case :binary.at(value, index) do
      ?% when index + 2 < byte_size(value) ->
        hex_digit?(:binary.at(value, index + 1)) and hex_digit?(:binary.at(value, index + 2)) and
          valid_percent_escapes?(value, index + 3)

      ?% ->
        false

      _ ->
        valid_percent_escapes?(value, index + 1)
    end
  end

  defp hex_digit?(byte) when byte in ?0..?9, do: true
  defp hex_digit?(byte) when byte in ?a..?f, do: true
  defp hex_digit?(byte) when byte in ?A..?F, do: true
  defp hex_digit?(_byte), do: false

  defp canonical_qualifiers(qualifiers) when map_size(qualifiers) == 0, do: ""

  defp canonical_qualifiers(qualifiers) do
    encoded =
      qualifiers
      |> Enum.sort_by(fn {key, _value} -> String.downcase(key) end)
      |> Enum.map_join("&", fn {key, value} ->
        "#{encode_component(String.downcase(key))}=#{encode_component(value)}"
      end)

    "?#{encoded}"
  end

  defp canonical_subpath(nil), do: ""
  defp canonical_subpath([]), do: ""
  defp canonical_subpath(subpath), do: "#" <> Enum.map_join(subpath, "/", &encode_component/1)

  defp encode_component(value) do
    value
    |> to_string()
    |> URI.encode(&(URI.char_unreserved?(&1) or &1 == ?:))
  end

  defp split_once(value, marker) do
    case String.split(value, marker, parts: 2) do
      [left, right] -> {left, right}
      [left] -> {left, nil}
    end
  end

  defp split_rightmost(value, marker) do
    case String.split(value, marker) do
      [left] -> {left, nil}
      segments -> {segments |> Enum.drop(-1) |> Enum.join(marker), List.last(segments)}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
