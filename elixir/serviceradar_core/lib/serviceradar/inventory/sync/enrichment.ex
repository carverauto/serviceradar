defmodule ServiceRadar.Inventory.Sync.Enrichment do
  @moduledoc """
  Inference of vendor/model/os/type/risk/owner from update payloads and
  SNMP metadata, plus classification metadata merging.
  """

  alias ServiceRadar.Inventory.Sync.FieldAliases
  alias ServiceRadar.Inventory.Sync.Normalize

  @classification_metadata_keys ~w(
    classification_source
    classification_rule_id
    classification_confidence
    classification_reason
  )

  def infer_vendor_name(update, classification) do
    metadata = update.metadata || %{}
    ruled_vendor = Map.get(classification, :vendor_name)

    explicit = Normalize.first_meaningful_string(metadata, FieldAliases.vendor_aliases())

    cond do
      explicit not in [nil, ""] ->
        explicit

      ruled_vendor not in [nil, ""] ->
        ruled_vendor

      (sys_object_id = sys_object_id_from_metadata(metadata)) not in [nil, ""] ->
        vendor_from_sys_object_id(sys_object_id) ||
          vendor_from_sys_descr(sys_descr_from_metadata(metadata))

      (sys_descr = sys_descr_from_metadata(metadata)) not in [nil, ""] ->
        vendor_from_sys_descr(sys_descr)

      true ->
        nil
    end
  end

  def infer_model(update, classification) do
    metadata = update.metadata || %{}
    explicit = Normalize.first_meaningful_string(metadata, FieldAliases.model_aliases())
    ruled_model = Map.get(classification, :model)

    cond do
      explicit not in [nil, ""] ->
        explicit

      ruled_model not in [nil, ""] ->
        ruled_model

      (sys_descr = sys_descr_from_metadata(metadata)) not in [nil, ""] ->
        parse_model_from_sys_descr(sys_descr) ||
          parse_model_from_sys_name(
            Normalize.get_string(metadata, ["sys_name", "snmp_name", "sysName"])
          )

      true ->
        parse_model_from_sys_name(
          Normalize.get_string(metadata, ["sys_name", "snmp_name", "sysName"])
        )
    end
  end

  def infer_os(metadata, vendor_name, classification) when is_map(metadata) do
    explicit_name =
      Normalize.get_string(metadata, [
        "os_name",
        "os",
        "operating_system",
        "osName"
      ])

    routeros_version =
      Normalize.get_string(metadata, ["routeros_version", "os_version", "version"])

    sys_descr = sys_descr_from_metadata(metadata)
    classified_family = Map.get(classification, :os_family)

    os =
      cond do
        explicit_name not in [nil, ""] ->
          %{"name" => explicit_name}

        routeros_metadata?(metadata, vendor_name, sys_descr) ->
          %{"name" => "RouterOS"}

        classified_family not in [nil, ""] ->
          %{"family" => classified_family}

        true ->
          %{}
      end

    os
    |> maybe_put_map_value("version", routeros_version)
    |> empty_map_to_nil()
  end

  def infer_os(_metadata, _vendor_name, _classification), do: nil

  def infer_hw_info(metadata) when is_map(metadata) do
    nested = Normalize.get_map(metadata, ["hw_info", :hw_info])

    %{}
    |> maybe_put_map_value(
      "serial_number",
      Normalize.get_string(nested, ["serial_number", "serial"]) ||
        Normalize.get_string(metadata, ["serial_number", "serial"])
    )
    |> maybe_put_map_value(
      "cpu_architecture",
      Normalize.get_string(metadata, ["cpu_architecture", "architecture_name", "architecture"])
    )
    |> maybe_put_map_value(
      "processor",
      Normalize.get_string(nested, ["processor"]) || Normalize.get_string(metadata, ["processor"])
    )
    |> maybe_put_map_value(
      "memory_bytes",
      Normalize.get_value(nested, ["memory_bytes", "memory"]) ||
        Normalize.get_value(metadata, ["memory_bytes", "memory"])
    )
    |> maybe_put_map_value(
      "total_ports",
      Normalize.get_value(nested, ["total_ports"]) ||
        Normalize.get_value(metadata, ["total_ports"])
    )
    |> maybe_put_map_value(
      "free_ports",
      Normalize.get_value(nested, ["free_ports"]) || Normalize.get_value(metadata, ["free_ports"])
    )
    |> maybe_put_map_value(
      "driver_name",
      Normalize.get_string(nested, ["driver_name"]) ||
        Normalize.get_string(metadata, ["driver_name"])
    )
    |> maybe_put_map_value(
      "firmware_version",
      Normalize.get_string(nested, ["firmware_version"]) ||
        Normalize.get_string(metadata, ["firmware_version"])
    )
    |> maybe_put_map_value(
      "rom_version",
      Normalize.get_string(nested, ["rom_version"]) ||
        Normalize.get_string(metadata, ["rom_version"])
    )
    |> maybe_put_map_value(
      "chassis_serials",
      Normalize.get_value(nested, ["chassis_serials"]) ||
        Normalize.get_value(metadata, ["chassis_serials"])
    )
    |> empty_map_to_nil()
  end

  def infer_hw_info(_metadata), do: nil

  def infer_risk_score(metadata) when is_map(metadata) do
    metadata
    |> Normalize.get_string(["risk_score", "risk_level"])
    |> parse_int_value()
  end

  def infer_risk_score(_metadata), do: nil

  def infer_risk_level(metadata) when is_map(metadata) do
    case infer_risk_score(metadata) do
      score when is_integer(score) and score >= 90 -> "Critical"
      score when is_integer(score) and score >= 70 -> "High"
      score when is_integer(score) and score >= 40 -> "Medium"
      score when is_integer(score) and score >= 1 -> "Low"
      _ -> nil
    end
  end

  def infer_risk_level(_metadata), do: nil

  def infer_owner(update, metadata) do
    explicit_owner =
      update.metadata
      |> Normalize.get_map(["owner", :owner])
      |> case do
        map when is_map(map) and map_size(map) > 0 -> map
        _ -> nil
      end

    cond do
      is_map(explicit_owner) ->
        explicit_owner

      (owner_name = Normalize.get_string(metadata, ["sys_owner", "sys_contact", "sysContact"])) not in [
        nil,
        ""
      ] ->
        %{"name" => owner_name}

      true ->
        nil
    end
  end

  defp vendor_from_sys_descr(nil), do: nil

  defp vendor_from_sys_descr(sys_descr) when is_binary(sys_descr) do
    sys_descr = String.downcase(sys_descr)

    Enum.find_value(FieldAliases.vendor_tokens(), fn {token, vendor} ->
      if String.contains?(sys_descr, token), do: vendor
    end)
  end

  defp vendor_from_sys_object_id(nil), do: nil

  @sys_object_id_vendor_prefixes [
    {"1.3.6.1.4.1.41112", "Ubiquiti"},
    {"1.3.6.1.4.1.4413", "Ubiquiti"},
    {"1.3.6.1.4.1.10002", "Ubiquiti"},
    {"1.3.6.1.4.1.9", "Cisco"},
    {"1.3.6.1.4.1.2636", "Juniper"},
    {"1.3.6.1.4.1.14988", "MikroTik"},
    {"1.3.6.1.4.1.2011", "Huawei"},
    {"1.3.6.1.4.1.8072", "Net-SNMP"}
  ]

  defp vendor_from_sys_object_id(sys_object_id) when is_binary(sys_object_id) do
    normalized =
      sys_object_id
      |> String.trim()
      |> String.trim_leading(".")

    Enum.find_value(@sys_object_id_vendor_prefixes, fn {prefix, vendor} ->
      if String.starts_with?(normalized, prefix), do: vendor
    end)
  end

  defp parse_model_from_sys_descr(sys_descr) when is_binary(sys_descr) do
    cleaned = String.trim(sys_descr)

    cond do
      cleaned == "" ->
        nil

      String.contains?(cleaned, ",") ->
        cleaned
        |> String.split(",", parts: 2)
        |> List.first()
        |> normalize_model_token()

      true ->
        cleaned
        |> String.split()
        |> List.first()
        |> normalize_model_token()
    end
  end

  defp normalize_model_token(nil), do: nil

  defp normalize_model_token(model) when is_binary(model) do
    token =
      model
      |> String.trim()
      |> String.trim_trailing(".")

    if token == "", do: nil, else: token
  end

  defp parse_model_from_sys_name(nil), do: nil

  defp parse_model_from_sys_name(sys_name) when is_binary(sys_name) do
    sys_name
    |> String.trim()
    |> case do
      "" -> nil
      value -> normalize_model_token(value)
    end
  end

  defp sys_descr_from_metadata(metadata) do
    Normalize.get_string(metadata, [
      "sys_descr",
      "snmp_description",
      "sysDescr",
      "sys_description",
      "sysDescr"
    ])
  end

  defp sys_object_id_from_metadata(metadata) do
    Normalize.get_string(metadata, ["sys_object_id", "sysObjectID", "sys_objectid", "sysObjectId"])
  end

  defp routeros_metadata?(metadata, vendor_name, sys_descr) do
    Normalize.get_string(metadata, ["routeros_version"]) not in [nil, ""] or
      vendor_name == "MikroTik" or
      (is_binary(sys_descr) and String.contains?(String.downcase(sys_descr), "routeros"))
  end

  def infer_device_type(update, classification) do
    metadata = update.metadata || %{}
    explicit_type = infer_explicit_type(metadata)
    ruled_type = Map.get(classification, :type)
    ruled_type_id = Map.get(classification, :type_id)
    role = infer_role(metadata)

    cond do
      ruled_type not in [nil, ""] and is_integer(ruled_type_id) ->
        {ruled_type, ruled_type_id}

      explicit_type != nil ->
        explicit_type

      role in ["router"] ->
        {"Router", 12}

      role in ["switch_l2"] ->
        {"Switch", 10}

      role in ["ap_bridge"] ->
        {"Access Point", 99}

      role in ["hypervisor"] ->
        {"Hypervisor", 99}

      role in ["virtual-guest", "virtual_guest"] ->
        {"Virtual", 6}

      true ->
        infer_device_type_from_snmp(metadata)
    end
  end

  defp infer_explicit_type(metadata) do
    explicit = Normalize.first_meaningful_string(metadata, FieldAliases.device_type_aliases())

    if explicit in [nil, ""] do
      nil
    else
      explicit_type_tuple(explicit)
    end
  end

  defp explicit_type_tuple(explicit) do
    normalized =
      explicit
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    cond do
      normalized in ["server", "server_system"] ->
        {"Server", 1}

      normalized in ["desktop", "desktop_computer", "workstation"] ->
        {"Desktop", 2}

      normalized in ["laptop", "notebook"] ->
        {"Laptop", 3}

      normalized in ["tablet", "ipad"] ->
        {"Tablet", 4}

      normalized in ["mobile", "mobile_phone", "phone", "smartphone", "mobile_device"] ->
        {"Mobile", 5}

      normalized in ["browser", "web_browser"] ->
        {"Browser", 8}

      normalized in ["firewall", "network_firewall"] ->
        {"Firewall", 9}

      normalized in ["router", "gateway"] ->
        {"Router", 12}

      normalized in ["switch", "switch_l2"] ->
        {"Switch", 10}

      normalized in ["access_point", "access point", "ap", "wireless_ap"] ->
        {"Access Point", 99}

      normalized in ["hypervisor", "virtualization_host", "virtualization host"] ->
        {"Hypervisor", 99}

      normalized in ["virtual", "vm", "virtual_machine", "virtual_guest", "lxc", "container"] ->
        {"Virtual", 6}

      normalized in ["iot", "io_t", "internet_of_things"] ->
        {"IOT", 7}

      normalized in ["hub"] ->
        {"Hub", 11}

      normalized in ["ids", "intrusion_detection_system"] ->
        {"IDS", 13}

      normalized in ["ips", "intrusion_prevention_system"] ->
        {"IPS", 14}

      normalized in ["load_balancer", "loadbalancer"] ->
        {"Load Balancer", 15}

      true ->
        {explicit, 99}
    end
  end

  defp infer_role(metadata) do
    metadata
    |> Normalize.get_string(["device_role", "_device_role"])
    |> to_string()
    |> String.downcase()
  end

  defp infer_device_type_from_snmp(metadata) do
    sys_descr = String.downcase(to_string(sys_descr_from_metadata(metadata) || ""))

    sys_name =
      String.downcase(
        to_string(Normalize.get_string(metadata, ["sys_name", "snmp_name", "sysName"]) || "")
      )

    ip_forwarding =
      parse_int_value(Normalize.get_string(metadata, ["ip_forwarding", "ipForwarding"]))

    has_router_token? =
      contains_any_token?(sys_descr, sys_name, ["router", "gateway", "udm", "edgerouter"])

    has_switch_token? =
      contains_any_token?(sys_descr, sys_name, ["switch", "usw", "ethernet switch"])

    has_ap_token? =
      contains_any_token?(sys_descr, sys_name, [
        "access point",
        "uap",
        "u6-",
        "wireless",
        "nanohd"
      ])

    cond do
      has_ap_token? ->
        {"Access Point", 99}

      has_switch_token? ->
        {"Switch", 10}

      has_router_token? or ip_forwarding == 1 ->
        {"Router", 12}

      true ->
        {nil, 0}
    end
  end

  defp contains_any_token?(sys_descr, sys_name, tokens) do
    Enum.any?(tokens, fn token ->
      String.contains?(sys_descr, token) || String.contains?(sys_name, token)
    end)
  end

  defp parse_int_value(nil), do: nil

  defp parse_int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def merge_classification_metadata(metadata, classification) do
    metadata = strip_classification_metadata(metadata)

    case Map.get(classification, :rule_id) do
      nil ->
        metadata

      rule_id ->
        metadata
        |> Map.put("classification_source", Map.get(classification, :source))
        |> Map.put("classification_rule_id", rule_id)
        |> Map.put("classification_confidence", Map.get(classification, :confidence))
        |> Map.put("classification_reason", Map.get(classification, :reason))
    end
  end

  def strip_classification_metadata(metadata) when is_map(metadata) do
    Enum.reduce(@classification_metadata_keys, metadata, &Map.delete(&2, &1))
  end

  def strip_classification_metadata(_metadata), do: %{}

  defp maybe_put_map_value(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)

  defp empty_map_to_nil(map) when is_map(map) and map_size(map) == 0, do: nil
  defp empty_map_to_nil(map), do: map

  def merge_inferred_map(explicit, inferred) when is_map(explicit) and is_map(inferred),
    do: Map.merge(inferred, explicit)

  def merge_inferred_map(explicit, _inferred) when is_map(explicit) and map_size(explicit) > 0,
    do: explicit

  def merge_inferred_map(_explicit, inferred), do: inferred
end
