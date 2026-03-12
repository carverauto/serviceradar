defmodule ServiceRadar.Inventory.InterfaceClassifier do
  @moduledoc """
  Rule-based interface classification engine.

  This module evaluates InterfaceClassificationRule definitions against
  interface observations and device context to produce classification tags.
  """

  require Logger
  require Ash.Query
  import Bitwise

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.{Device, InterfaceClassificationRule}

  @exclusive_classifications ~w(management wan lan vpn loopback virtual)

  @spec classify_interfaces(list(map()), term()) :: list(map())
  def classify_interfaces(records, actor) when is_list(records) do
    rules = load_rules(actor)
    device_contexts = load_device_contexts(records, actor)
    classify_records(records, rules, device_contexts)
  end

  @spec classify_records(list(map()), list(map()), map()) :: list(map())
  def classify_records(records, rules, device_contexts)
      when is_list(records) and is_list(rules) and is_map(device_contexts) do
    rules = Enum.sort_by(rules, &(&1.priority || 0), :desc)

    Enum.map(records, fn record ->
      device_ctx = Map.get(device_contexts, record.device_id, %{})
      apply_rules(record, rules, device_ctx)
    end)
  end

  defp load_rules(actor) do
    query =
      InterfaceClassificationRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(enabled == true)
      |> Ash.Query.sort(priority: :desc)

    case Ash.read(query, actor: actor) do
      {:ok, rules} ->
        rules

      {:error, reason} ->
        Logger.warning("Interface classification rule load failed: #{inspect(reason)}")
        []
    end
  end

  defp load_device_contexts([], _actor), do: %{}

  defp load_device_contexts(records, actor) do
    device_ids =
      records
      |> Enum.map(& &1.device_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(uid in ^device_ids)
      |> Ash.Query.select([:uid, :vendor_name, :model, :metadata, :hostname])

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, devices} ->
        devices
        |> Enum.map(fn device ->
          {device.uid,
           %{
             vendor_name: device.vendor_name,
             model: device.model,
             hostname: device.hostname,
             sys_descr: sys_descr_from_metadata(device.metadata || %{})
           }}
        end)
        |> Map.new()

      {:error, reason} ->
        Logger.warning("Interface classifier device context lookup failed: #{inspect(reason)}")
        %{}
    end
  end

  defp apply_rules(record, rules, device_ctx) do
    matched_rules = Enum.filter(rules, &rule_matches?(&1, record, device_ctx))

    if matched_rules == [] do
      record
    else
      {classifications, meta} = merge_rule_classifications(record, matched_rules)

      record
      |> Map.put(:classifications, classifications)
      |> Map.put(:classification_meta, meta)
      |> Map.put(:classification_source, "rules")
    end
  end

  defp rule_matches?(rule, record, device_ctx) do
    rule
    |> rule_match_checks(record, device_ctx)
    |> Enum.all?()
  end

  defp rule_match_checks(rule, record, device_ctx) do
    [
      rule.enabled != false,
      has_constraints?(rule),
      matches_vendor?(rule.vendor_pattern, device_ctx),
      matches_pattern?(rule.model_pattern, Map.get(device_ctx, :model)),
      matches_pattern?(rule.sys_descr_pattern, Map.get(device_ctx, :sys_descr)),
      matches_pattern?(rule.if_name_pattern, record.if_name),
      matches_pattern?(rule.if_descr_pattern, record.if_descr),
      matches_pattern?(rule.if_alias_pattern, record.if_alias),
      matches_if_type?(rule.if_type_ids, record.if_type),
      matches_ip_constraints?(rule, record)
    ]
  end

  defp has_constraints?(rule) do
    not Enum.all?(
      [
        rule.vendor_pattern,
        rule.model_pattern,
        rule.sys_descr_pattern,
        rule.if_name_pattern,
        rule.if_descr_pattern,
        rule.if_alias_pattern
      ],
      &blank?/1
    ) or
      (rule.if_type_ids || []) != [] or
      (rule.ip_cidr_allow || []) != [] or
      (rule.ip_cidr_deny || []) != []
  end

  defp matches_pattern?(nil, _value), do: true
  defp matches_pattern?("", _value), do: true

  defp matches_pattern?(pattern, value) when is_binary(value) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp matches_pattern?(_pattern, _value), do: false

  defp matches_vendor?(nil, _device_ctx), do: true
  defp matches_vendor?("", _device_ctx), do: true

  defp matches_vendor?(pattern, device_ctx) do
    vendor = Map.get(device_ctx, :vendor_name)
    sys_descr = Map.get(device_ctx, :sys_descr)

    matches_pattern?(pattern, vendor) or
      (vendor in [nil, ""] and matches_pattern?(pattern, sys_descr))
  end

  defp matches_if_type?(nil, _if_type), do: true
  defp matches_if_type?([], _if_type), do: true

  defp matches_if_type?(if_type_ids, if_type) when is_integer(if_type) do
    Enum.member?(if_type_ids, if_type)
  end

  defp matches_if_type?(_if_type_ids, _if_type), do: false

  defp matches_ip_constraints?(rule, record) do
    ips = interface_ips(record)

    allow = rule.ip_cidr_allow || []
    deny = rule.ip_cidr_deny || []

    allow_ok = allow == [] or Enum.any?(ips, &ip_in_any_cidr?(&1, allow))
    deny_ok = deny == [] or not Enum.any?(ips, &ip_in_any_cidr?(&1, deny))

    allow_ok and deny_ok
  end

  defp interface_ips(record) do
    ips =
      record
      |> Map.get(:ip_addresses, [])
      |> List.wrap()

    ips
    |> maybe_add_ip(Map.get(record, :device_ip))
    |> Enum.uniq()
  end

  defp maybe_add_ip(ips, nil), do: ips
  defp maybe_add_ip(ips, ""), do: ips
  defp maybe_add_ip(ips, ip), do: [ip | ips]

  defp ip_in_any_cidr?(ip, cidrs) do
    Enum.any?(cidrs, &ip_in_cidr?(ip, &1))
  end

  defp ip_in_cidr?(ip, cidr) when is_binary(ip) and is_binary(cidr) do
    with {:ok, ip_tuple} <- parse_ip(ip),
         {:ok, cidr_ip, prefix} <- parse_cidr(cidr),
         true <- tuple_size(ip_tuple) == tuple_size(cidr_ip) do
      mask_bits = prefix
      ip_int = ip_tuple |> tuple_to_int()
      cidr_int = cidr_ip |> tuple_to_int()

      max_bits = tuple_size(ip_tuple) * bits_per_segment(ip_tuple)
      mask = mask_for_bits(max_bits, mask_bits)

      (ip_int &&& mask) == (cidr_int &&& mask)
    else
      _ -> false
    end
  end

  defp ip_in_cidr?(_, _), do: false

  defp parse_ip(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/") do
      [ip, prefix_str] ->
        with {:ok, ip_tuple} <- parse_ip(ip),
             {prefix, ""} <- Integer.parse(prefix_str) do
          {:ok, ip_tuple, prefix}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp tuple_to_int(tuple) when tuple_size(tuple) == 4 do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn octet, acc -> acc * 256 + octet end)
  end

  defp tuple_to_int(tuple) when tuple_size(tuple) == 8 do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, acc -> acc * 65_536 + segment end)
  end

  defp bits_per_segment(tuple) when tuple_size(tuple) == 4, do: 8
  defp bits_per_segment(tuple) when tuple_size(tuple) == 8, do: 16

  defp mask_for_bits(_max_bits, 0), do: 0

  defp mask_for_bits(max_bits, bits) when bits >= max_bits do
    (1 <<< max_bits) - 1
  end

  defp mask_for_bits(max_bits, bits) do
    ((1 <<< bits) - 1) <<< (max_bits - bits)
  end

  defp merge_rule_classifications(record, rules) do
    {classifications, matched_rule_ids, matched_rule_names} =
      Enum.reduce(rules, initial_rule_state(record), &merge_rule/2)

    meta = build_rule_meta(matched_rule_ids, matched_rule_names)
    {finalize_classifications(classifications), meta}
  end

  defp initial_rule_state(record) do
    {MapSet.new(existing_classifications(record)), [], []}
  end

  defp merge_rule(rule, {acc, ids, names}) do
    {acc, ids, names} = track_rule(rule, acc, ids, names)
    Enum.reduce(rule.classifications || [], {acc, ids, names}, &merge_rule_classification/2)
  end

  defp track_rule(rule, acc, ids, names) do
    names = [rule.name | names]
    ids = if rule.id, do: [rule.id | ids], else: ids
    {acc, ids, names}
  end

  defp merge_rule_classification(classification, {acc, ids, names}) do
    classification = normalize_classification(classification)

    if classification == "" do
      {acc, ids, names}
    else
      {maybe_add_classification(acc, classification), ids, names}
    end
  end

  defp build_rule_meta(matched_rule_ids, matched_rule_names) do
    %{
      matched_rule_ids: Enum.reverse(matched_rule_ids),
      matched_rule_names: Enum.reverse(Enum.uniq(matched_rule_names))
    }
  end

  defp finalize_classifications(classifications) do
    classifications
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp existing_classifications(record) do
    record
    |> Map.get(:classifications, [])
    |> List.wrap()
    |> Enum.map(&normalize_classification/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_add_classification(classifications, classification) do
    if exclusive_classification?(classification) and
         Enum.any?(classifications, &exclusive_classification?/1) do
      classifications
    else
      MapSet.put(classifications, classification)
    end
  end

  defp exclusive_classification?(classification) do
    Enum.member?(@exclusive_classifications, classification)
  end

  defp normalize_classification(nil), do: ""

  defp normalize_classification(classification) when is_atom(classification) do
    classification |> Atom.to_string() |> String.downcase()
  end

  defp normalize_classification(classification) when is_binary(classification) do
    classification |> String.trim() |> String.downcase()
  end

  defp normalize_classification(_), do: ""

  defp sys_descr_from_metadata(metadata) do
    get_first_value(metadata, ["sys_descr", "sysDescr", "sys_description"])
  end

  defp get_first_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
