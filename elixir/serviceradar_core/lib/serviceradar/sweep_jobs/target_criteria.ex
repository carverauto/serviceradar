defmodule ServiceRadar.SweepJobs.TargetCriteria do
  @moduledoc """
  Device targeting DSL for sweep groups.

  This module provides functions to parse and evaluate target criteria
  against device records. The criteria DSL supports various operators
  for flexible device targeting.

  ## Supported Operators

  - `eq`: Exact match (string, number, boolean)
  - `neq`: Not equal
  - `in`: Value in list
  - `not_in`: Value not in list
  - `contains`: String contains (for text fields or array fields)
  - `not_contains`: String does not contain
  - `starts_with`: String starts with prefix
  - `ends_with`: String ends with suffix
  - `in_cidr`: IP address within CIDR range
  - `in_range`: IP address within range (e.g. 10.0.0.1-10.0.0.50)
  - `not_in_cidr`: IP address not within CIDR range
  - `has_any`: Map contains any of the provided tag keys/values
  - `has_all`: Map contains all of the provided tag keys/values
  - `gt`, `gte`, `lt`, `lte`: Numeric comparisons
  - `is_null`: Field is nil
  - `is_not_null`: Field is not nil

  ## Example Criteria

      %{
        "tags" => %{"has_any" => ["critical", "env=prod"]},
        "ip" => %{"in_cidr" => "10.0.0.0/8"},
        "partition" => %{"eq" => "datacenter-1"}
      }

  ## Usage

      # Check if a device matches criteria
      criteria = %{"tags" => %{"has_any" => ["critical"]}}
      device = %{tags: %{"critical" => ""}, ip: "10.0.1.5"}
      TargetCriteria.matches?(device, criteria)
      # => true

      # Get IPs from devices matching criteria
      devices = [%{ip: "10.0.1.1"}, %{ip: "192.168.1.1"}]
      criteria = %{"ip" => %{"in_cidr" => "10.0.0.0/8"}}
      TargetCriteria.filter_devices(devices, criteria)
      # => [%{ip: "10.0.1.1"}]

      # Build Ash filter from criteria
      TargetCriteria.to_ash_filter(criteria)
      # => Ash-compatible filter expression
  """

  require Logger

  import Bitwise

  @type criteria :: %{String.t() => operator_spec()}
  @type operator_spec :: %{String.t() => term()}

  @doc """
  Checks if a device matches the given criteria.

  Returns `true` if the device matches all criteria, `false` otherwise.
  Empty criteria matches all devices.
  """
  @spec matches?(map(), criteria()) :: boolean()
  def matches?(_device, criteria) when criteria == %{}, do: true

  def matches?(device, criteria) when is_map(criteria) do
    Enum.all?(criteria, fn {field, operator_spec} ->
      field_atom = to_atom_key(field)
      value = get_field_value(device, field_atom, field)
      evaluate_operator(value, operator_spec)
    end)
  end

  @doc """
  Filters a list of devices based on criteria.

  Returns only devices that match all criteria.
  """
  @spec filter_devices([map()], criteria()) :: [map()]
  def filter_devices(devices, criteria) when is_list(devices) do
    Enum.filter(devices, &matches?(&1, criteria))
  end

  @doc """
  Extracts target IPs from devices matching criteria.

  Combines:
  1. IPs from devices matching `target_criteria`
  2. Explicit `static_targets` (CIDRs/IPs)

  Returns a list of target strings (IPs or CIDRs).
  """
  @spec extract_targets([map()], criteria(), [String.t()]) :: [String.t()]
  def extract_targets(devices, criteria, static_targets \\ []) do
    # Get IPs from matching devices
    device_ips =
      devices
      |> filter_devices(criteria)
      |> Enum.map(&get_ip/1)
      |> Enum.reject(&is_nil/1)

    # Combine with static targets and deduplicate
    (device_ips ++ static_targets)
    |> Enum.uniq()
  end

  @doc """
  Validates criteria structure.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(criteria()) :: :ok | {:error, String.t()}
  def validate(criteria) when criteria == %{}, do: :ok

  def validate(criteria) when is_map(criteria) do
    errors =
      criteria
      |> Enum.map(fn {field, operator_spec} ->
        validate_operator_spec(field, operator_spec)
      end)
      |> Enum.reject(&(&1 == :ok))

    case errors do
      [] -> :ok
      [{:error, msg} | _] -> {:error, msg}
    end
  end

  def validate(_), do: {:error, "Criteria must be a map"}

  @doc """
  Converts criteria to an Ash-compatible filter expression.

  This allows using the criteria DSL directly in Ash queries.
  """
  @spec to_ash_filter(criteria()) :: Keyword.t()
  def to_ash_filter(criteria) when criteria == %{}, do: []

  def to_ash_filter(criteria) when is_map(criteria) do
    Enum.flat_map(criteria, fn {field, operator_spec} ->
      field_atom = to_atom_key(field)
      build_ash_condition(field_atom, operator_spec)
    end)
  end

  # Private functions

  defp get_field_value(device, field_atom, field_string) when is_map(device) do
    case field_string do
      "tags" ->
        get_tags(device)

      _ ->
        case String.split(field_string, ".", parts: 2) do
          ["tags", key] ->
            get_tags(device)
            |> Map.get(key)

          _ ->
            # Try atom key first, then string key
            case Map.get(device, field_atom) do
              nil -> Map.get(device, field_string)
              value -> value
            end
        end
    end
  end

  defp get_tags(device) do
    Map.get(device, :tags) || Map.get(device, "tags") || %{}
  end

  defp get_ip(device) do
    Map.get(device, :ip) || Map.get(device, "ip")
  end

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  # Operator evaluation

  defp evaluate_operator(value, %{"eq" => expected}), do: value == expected
  defp evaluate_operator(value, %{"neq" => expected}), do: value != expected

  defp evaluate_operator(value, %{"in" => list}) when is_list(list), do: value in list
  defp evaluate_operator(value, %{"not_in" => list}) when is_list(list), do: value not in list

  defp evaluate_operator(value, %{"contains" => substr}) when is_binary(value) do
    String.contains?(value, substr)
  end

  defp evaluate_operator(value, %{"contains" => item}) when is_list(value) do
    item in value
  end

  defp evaluate_operator(value, %{"not_contains" => substr}) when is_binary(value) do
    not String.contains?(value, substr)
  end

  defp evaluate_operator(value, %{"not_contains" => item}) when is_list(value) do
    item not in value
  end

  defp evaluate_operator(value, %{"starts_with" => prefix}) when is_binary(value) do
    String.starts_with?(value, prefix)
  end

  defp evaluate_operator(value, %{"ends_with" => suffix}) when is_binary(value) do
    String.ends_with?(value, suffix)
  end

  defp evaluate_operator(value, %{"in_cidr" => cidr}) when is_binary(value) do
    ip_in_cidr?(value, cidr)
  end

  defp evaluate_operator(value, %{"in_range" => range}) when is_binary(value) do
    ip_in_range?(value, range)
  end

  defp evaluate_operator(value, %{"not_in_cidr" => cidr}) when is_binary(value) do
    not ip_in_cidr?(value, cidr)
  end

  defp evaluate_operator(value, %{"has_any" => list}) when is_map(value) and is_list(list) do
    Enum.any?(list, &tag_entry_match?(value, &1))
  end

  defp evaluate_operator(value, %{"has_all" => list}) when is_map(value) and is_list(list) do
    Enum.all?(list, &tag_entry_match?(value, &1))
  end

  defp evaluate_operator(value, %{"gt" => threshold}) when is_number(value) do
    value > threshold
  end

  defp evaluate_operator(value, %{"gte" => threshold}) when is_number(value) do
    value >= threshold
  end

  defp evaluate_operator(value, %{"lt" => threshold}) when is_number(value) do
    value < threshold
  end

  defp evaluate_operator(value, %{"lte" => threshold}) when is_number(value) do
    value <= threshold
  end

  defp evaluate_operator(value, %{"is_null" => true}), do: is_nil(value)
  defp evaluate_operator(value, %{"is_null" => false}), do: not is_nil(value)

  defp evaluate_operator(value, %{"is_not_null" => true}), do: not is_nil(value)
  defp evaluate_operator(value, %{"is_not_null" => false}), do: is_nil(value)

  # Default: no match for unsupported operators or type mismatches
  defp evaluate_operator(_value, _operator_spec), do: false

  # CIDR matching

  defp ip_in_cidr?(ip_string, cidr_string) do
    with {:ok, ip} <- parse_ip(ip_string),
         {:ok, {network, mask}} <- parse_cidr(cidr_string) do
      ip_matches_cidr?(ip, network, mask)
    else
      _ -> false
    end
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp parse_cidr(cidr_string) do
    case String.split(cidr_string, "/") do
      [ip_part, mask_part] ->
        with {:ok, network} <- parse_ip(ip_part),
             {mask, ""} <- Integer.parse(mask_part) do
          {:ok, {network, mask}}
        else
          _ -> :error
        end

      [ip_part] ->
        # Single IP treated as /32 for IPv4 or /128 for IPv6
        with {:ok, network} <- parse_ip(ip_part) do
          mask = if tuple_size(network) == 4, do: 32, else: 128
          {:ok, {network, mask}}
        end

      _ ->
        :error
    end
  end

  defp ip_matches_cidr?(ip, network, mask) when tuple_size(ip) == 4 and tuple_size(network) == 4 do
    # IPv4
    ip_int = ipv4_to_int(ip)
    network_int = ipv4_to_int(network)
    mask_bits = bsl(0xFFFFFFFF, 32 - mask) &&& 0xFFFFFFFF
    (ip_int &&& mask_bits) == (network_int &&& mask_bits)
  end

  defp ip_matches_cidr?(_ip, _network, _mask), do: false

  defp ipv4_to_int({a, b, c, d}) do
    bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
  end

  defp ip_in_range?(ip_string, range_string) do
    case String.split(range_string, "-", parts: 2) do
      [start_ip, end_ip] ->
        with {:ok, ip} <- parse_ip(ip_string),
             {:ok, start} <- parse_ip(String.trim(start_ip)),
             {:ok, stop} <- parse_ip(String.trim(end_ip)),
             true <- tuple_size(ip) == 4 and tuple_size(start) == 4 and tuple_size(stop) == 4 do
          ip_int = ipv4_to_int(ip)
          start_int = ipv4_to_int(start)
          stop_int = ipv4_to_int(stop)
          ip_int >= start_int and ip_int <= stop_int
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp tag_entry_match?(tags, entry) when is_binary(entry) do
    case String.split(entry, "=", parts: 2) do
      [key, value] -> Map.get(tags, String.trim(key)) == String.trim(value)
      [key] -> Map.has_key?(tags, String.trim(key))
    end
  end

  defp tag_entry_match?(_tags, _entry), do: false

  # Ash filter building

  defp build_ash_condition(field, %{"eq" => value}), do: [{field, value}]
  defp build_ash_condition(field, %{"neq" => value}), do: [{:not, [{field, value}]}]

  defp build_ash_condition(field, %{"in" => values}) do
    [{field, [in: values]}]
  end

  defp build_ash_condition(field, %{"not_in" => values}) do
    [{:not, [{field, [in: values]}]}]
  end

  defp build_ash_condition(field, %{"gt" => value}), do: [{field, [gt: value]}]
  defp build_ash_condition(field, %{"gte" => value}), do: [{field, [gte: value]}]
  defp build_ash_condition(field, %{"lt" => value}), do: [{field, [lt: value]}]
  defp build_ash_condition(field, %{"lte" => value}), do: [{field, [lte: value]}]

  defp build_ash_condition(field, %{"is_null" => true}), do: [{field, [is_nil: true]}]
  defp build_ash_condition(field, %{"is_null" => false}), do: [{:not, [{field, [is_nil: true]}]}]

  # For operators that need custom handling (contains, cidr, etc.)
  # these will need to be handled specially in the query layer
  defp build_ash_condition(_field, _operator_spec), do: []

  # Validation

  @valid_operators ~w(eq neq in not_in contains not_contains starts_with ends_with in_cidr not_in_cidr in_range has_any has_all gt gte lt lte is_null is_not_null)

  defp validate_operator_spec(field, operator_spec) when is_map(operator_spec) do
    operators = Map.keys(operator_spec)

    case operators do
      [] ->
        {:error, "Field '#{field}' has empty operator spec"}

      [op] ->
        if op in @valid_operators do
          validate_operator_value(field, op, Map.get(operator_spec, op))
        else
          {:error, "Field '#{field}' has invalid operator '#{op}'. Valid: #{Enum.join(@valid_operators, ", ")}"}
        end

      _ ->
        {:error, "Field '#{field}' has multiple operators. Use only one per field."}
    end
  end

  defp validate_operator_spec(field, _) do
    {:error, "Field '#{field}' operator spec must be a map"}
  end

  defp validate_operator_value(field, "has_any", value) do
    validate_tag_operator(field, "has_any", value)
  end

  defp validate_operator_value(field, "has_all", value) do
    validate_tag_operator(field, "has_all", value)
  end

  defp validate_operator_value(field, "in_range", value) when is_binary(value) do
    if valid_ip_range?(value) do
      :ok
    else
      {:error, "Field '#{field}' has invalid in_range value '#{value}'"}
    end
  end

  defp validate_operator_value(field, "in_range", _value) do
    {:error, "Field '#{field}' in_range expects a string range like 10.0.0.1-10.0.0.50"}
  end

  defp validate_operator_value(field, op, value) when op in ["in_cidr", "not_in_cidr"] do
    if is_binary(value) and valid_cidr?(value) do
      :ok
    else
      {:error, "Field '#{field}' has invalid #{op} value '#{value}'"}
    end
  end

  defp validate_operator_value(field, op, value) when op in ["in", "not_in"] do
    if is_list(value) do
      :ok
    else
      {:error, "Field '#{field}' #{op} expects a list value"}
    end
  end

  defp validate_operator_value(_field, _op, _value), do: :ok

  defp validate_tag_operator(field, op, value) do
    cond do
      field != "tags" ->
        {:error, "Field '#{field}' does not support #{op} operator"}

      not is_list(value) ->
        {:error, "Field '#{field}' #{op} expects a list of tags"}

      Enum.any?(value, &(!valid_tag_entry?(&1))) ->
        {:error, "Field '#{field}' #{op} has invalid tag entries"}

      true ->
        :ok
    end
  end

  defp valid_tag_entry?(entry) when is_binary(entry) do
    trimmed = String.trim(entry)

    case String.split(trimmed, "=", parts: 2) do
      [key, value] -> key != "" and value != ""
      [key] -> key != ""
      _ -> false
    end
  end

  defp valid_tag_entry?(_entry), do: false

  defp valid_cidr?(cidr) when is_binary(cidr) do
    case parse_cidr(String.trim(cidr)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_cidr?(_), do: false

  defp valid_ip_range?(range) when is_binary(range) do
    case String.split(range, "-", parts: 2) do
      [start_ip, end_ip] ->
        with {:ok, start} <- parse_ip(String.trim(start_ip)),
             {:ok, stop} <- parse_ip(String.trim(end_ip)),
             true <- tuple_size(start) == 4 and tuple_size(stop) == 4 do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_ip_range?(_), do: false
end
