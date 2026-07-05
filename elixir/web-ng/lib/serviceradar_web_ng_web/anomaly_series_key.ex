defmodule ServiceRadarWebNGWeb.AnomalySeriesKey do
  @moduledoc false

  @leading_tags ["core_id", "mount_point", "label"]

  @spec decode(term()) :: map() | nil
  def decode(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.starts_with?(value, "v2:") ->
        decode_components(value, ":")

      String.starts_with?(value, "v2|") ->
        decode_components(value, "|")

      true ->
        nil
    end
  end

  def decode(_value), do: nil

  @spec display(term()) :: String.t() | nil
  def display(value) do
    case decode(value) do
      %{} = decoded -> display_decoded(decoded)
      nil -> nil
    end
  end

  @spec component(map() | nil, String.t()) :: String.t() | nil
  def component(%{} = decoded, key) when is_binary(key) do
    decoded
    |> Map.get(:components, %{})
    |> Map.get(key)
  end

  def component(_decoded, _key), do: nil

  @spec tag(map() | nil, String.t()) :: String.t() | nil
  def tag(%{} = decoded, key) when is_binary(key) do
    decoded
    |> Map.get(:tags, %{})
    |> Map.get(key)
  end

  def tag(_decoded, _key), do: nil

  @spec tags(map() | nil) :: map()
  def tags(%{} = decoded), do: Map.get(decoded, :tags, %{})
  def tags(_decoded), do: %{}

  defp decode_components(value, delimiter) do
    parts = String.split(value, delimiter)

    case parts do
      ["v2" | component_parts] ->
        component_parts
        |> Enum.reduce(%{version: "v2", raw: value, components: %{}, tags: %{}}, &decode_part/2)
        |> require_decoded_component()

      _ ->
        nil
    end
  end

  defp decode_part(part, acc) do
    case String.split(part, "=", parts: 2) do
      ["tag_" <> encoded_key, encoded_value] ->
        put_in(acc, [:tags, decode_hex(encoded_key)], decode_hex(encoded_value))

      [key, encoded_value] when key != "" ->
        put_in(acc, [:components, key], decode_hex(encoded_value))

      _ ->
        acc
    end
  end

  defp require_decoded_component(%{components: components, tags: tags} = decoded) do
    if map_size(components) > 0 or map_size(tags) > 0, do: decoded
  end

  defp display_decoded(decoded) do
    components = Map.get(decoded, :components, %{})
    tags = Map.get(decoded, :tags, %{})

    [
      Map.get(components, "partition"),
      class_family_label(components),
      Map.get(components, "identity") || Map.get(components, "hint"),
      metric_label(components),
      if_index_label(Map.get(components, "if_index")),
      tag_summary(tags)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp class_family_label(components) do
    case {Map.get(components, "class"), Map.get(components, "family")} do
      {class, family} when is_binary(class) and is_binary(family) -> "#{class}/#{family}"
      {class, _family} when is_binary(class) -> class
      {_class, family} when is_binary(family) -> family
      _ -> nil
    end
  end

  defp metric_label(%{"metric" => metric}) when is_binary(metric), do: "metric #{metric}"
  defp metric_label(_components), do: nil

  defp if_index_label(value) when is_binary(value) and value != "", do: "ifIndex #{value}"
  defp if_index_label(_value), do: nil

  defp tag_summary(tags) when map_size(tags) == 0, do: nil

  defp tag_summary(tags) do
    ordered =
      Enum.flat_map(@leading_tags, fn key ->
        case Map.get(tags, key) do
          value when is_binary(value) and value != "" -> [{key, value}]
          _ -> []
        end
      end)

    extra =
      tags
      |> Enum.reject(fn {key, value} ->
        key in @leading_tags or blank?(value)
      end)
      |> Enum.sort_by(fn {key, _value} -> key end)

    Enum.map_join(ordered ++ extra, " | ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp decode_hex(value) do
    value = to_string(value)

    if rem(byte_size(value), 2) == 0 and String.match?(value, ~r/\A[0-9a-fA-F]*\z/) do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} -> decoded
        :error -> value
      end
    else
      value
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
