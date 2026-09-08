defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceFormData do
  @moduledoc false

  def format_tags(nil), do: ""
  def format_tags(tags) when is_list(tags), do: Enum.join(tags, "\n")

  def format_tags(tags) when is_map(tags) do
    Enum.map_join(tags, "\n", fn {key, value} -> if value, do: "#{key}=#{value}", else: key end)
  end

  def format_tags(_), do: ""

  def parse_tags(nil), do: %{}
  def parse_tags(""), do: %{}

  def parse_tags(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        [key] -> Map.put(acc, String.trim(key), nil)
      end
    end)
  end

  def parse_bool(value) when value in [true, false], do: value
  def parse_bool("true"), do: true
  def parse_bool("false"), do: false
  def parse_bool("on"), do: true
  def parse_bool("1"), do: true
  def parse_bool("0"), do: false
  def parse_bool(_), do: nil
end
