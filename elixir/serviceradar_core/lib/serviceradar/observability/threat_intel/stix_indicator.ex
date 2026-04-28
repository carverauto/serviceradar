defmodule ServiceRadar.Observability.ThreatIntel.StixIndicator do
  @moduledoc """
  Minimal STIX 2.1 Indicator pattern normalization for NetFlow-matchable IOCs.

  This is intentionally narrow: it extracts IPv4/IPv6 address and CIDR
  constants from STIX Indicator patterns and leaves full STIX pattern evaluation
  to a later provider slice.
  """

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Types.Cidr

  @ip_comparison ~r/\b(?:ipv4-addr|ipv6-addr):value\s*(?:=|ISSUBSET|ISSUPERSET)\s*'((?:\\'|[^'])+)'/i
  @ip_in ~r/\b(?:ipv4-addr|ipv6-addr):value\s+IN\s*\(([^)]*)\)/i
  @quoted_value ~r/'((?:\\'|[^'])+)'/

  @doc """
  Extracts supported IP/CIDR constants from a STIX Indicator pattern.
  """
  @spec extract_cidrs(String.t()) :: [String.t()]
  def extract_cidrs(pattern) when is_binary(pattern) do
    pattern
    |> extract_pattern_values()
    |> Enum.map(&normalize_cidr/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def extract_cidrs(_pattern), do: []

  @doc """
  Converts a STIX Indicator object into threat-intel indicator attrs.
  """
  @spec attrs_from_object(map(), String.t(), DateTime.t()) :: [map()]
  def attrs_from_object(object, default_source, observed_at)
      when is_map(object) and is_binary(default_source) and is_struct(observed_at, DateTime) do
    if indicator_object?(object) do
      object
      |> string_value(["pattern"])
      |> extract_cidrs()
      |> Enum.map(&attrs_for_cidr(&1, object, default_source, observed_at))
    else
      []
    end
  end

  def attrs_from_object(_object, _default_source, _observed_at), do: []

  defp extract_pattern_values(pattern) do
    comparison_values =
      @ip_comparison
      |> Regex.scan(pattern, capture: :all_but_first)
      |> List.flatten()

    in_values =
      @ip_in
      |> Regex.scan(pattern, capture: :all_but_first)
      |> Enum.flat_map(fn [list] ->
        @quoted_value
        |> Regex.scan(list, capture: :all_but_first)
        |> List.flatten()
      end)

    comparison_values ++ in_values
  end

  defp normalize_cidr(value) do
    case Cidr.cast_input(unescape_string(value), []) do
      {:ok, cidr} when is_binary(cidr) and cidr != "" -> cidr
      _ -> nil
    end
  end

  defp attrs_for_cidr(cidr, object, default_source, observed_at) do
    %{
      indicator: cidr,
      indicator_type: "cidr",
      source: string_value(object, ["source", "created_by_ref"]) || default_source,
      label: string_value(object, ["name", "id"]),
      severity: nil,
      confidence: int_value(object, ["confidence"]),
      first_seen_at: datetime_value(object, ["valid_from", "created"]) || observed_at,
      last_seen_at: datetime_value(object, ["modified", "valid_from", "created"]) || observed_at,
      expires_at: datetime_value(object, ["valid_until", "revoked_at"])
    }
  end

  defp indicator_object?(object) do
    String.downcase(string_value(object, ["type"]) || "") == "indicator" and
      String.downcase(string_value(object, ["pattern_type"]) || "stix") == "stix"
  end

  defp unescape_string(value) do
    value
    |> String.replace("\\'", "'")
    |> String.replace("\\\\", "\\")
    |> String.trim()
  end

  defp string_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _ ->
        nil
    end
  end

  defp int_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_int(value)
      _ -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp datetime_value(map, keys) do
    case fetch_value(map, keys) do
      nil -> nil
      "" -> nil
      value -> FieldParser.parse_timestamp(value)
    end
  rescue
    _ -> nil
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil
end
