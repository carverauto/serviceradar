defmodule ServiceRadar.Inventory.DeviceEnrichmentRulesTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.DeviceEnrichmentRules

  setup do
    original_dir = Application.get_env(:serviceradar_core, :device_enrichment_rules_dir)

    if is_nil(original_dir) do
      Application.delete_env(:serviceradar_core, :device_enrichment_rules_dir)
    else
      Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, original_dir)
    end

    DeviceEnrichmentRules.reload()

    on_exit(fn ->
      if is_nil(original_dir) do
        Application.delete_env(:serviceradar_core, :device_enrichment_rules_dir)
      else
        Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, original_dir)
      end

      DeviceEnrichmentRules.reload()
    end)
  end

  test "classifies UDM sysDescr as Ubiquiti router" do
    update = %{
      hostname: "farm01",
      source: "mapper",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
        "sys_name" => "farm01",
        "ip_forwarding" => "1"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Ubiquiti"
    assert classification.type == "Router"
    assert classification.type_id == 12
    assert classification.rule_id == "ubiquiti-router-udm"
  end

  test "classifies USW sysName as Ubiquiti switch" do
    update = %{
      hostname: "USW16PoE",
      source: "mapper",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Linux UBNT 3.18.24 #0 Thu Aug 30 12:10:54 2018 mips",
        "sys_name" => "USW16PoE",
        "ip_forwarding" => "2"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Ubiquiti"
    assert classification.type == "Switch"
    assert classification.type_id == 10
    assert classification.rule_id == "ubiquiti-switch-usw"
  end

  test "does not misclassify Aruba switch as Ubiquiti" do
    update = %{
      hostname: "aruba-24g-02",
      source: "snmp",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.11.2.3.7.11.153",
        "sys_descr" =>
          "HP J9727A 2920-24G-PoE+ Switch, revision WB.16.10.0025 (Formerly ProCurve)",
        "sys_name" => "aruba-24g-02",
        "ip_forwarding" => "1"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Aruba"
    assert classification.type == "Switch"
    assert classification.type_id == 10
    assert classification.rule_id == "aruba-switch"
  end

  test "classifies RouterOS identity as MikroTik router" do
    update = %{
      hostname: "mikrotik-6-167",
      source: "mapper",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.14988.1",
        "sys_descr" => "MikroTik RouterOS RB5009UG+S+",
        "sys_name" => "mikrotik-6-167",
        "ip_forwarding" => "1"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "MikroTik"
    assert classification.type == "Router"
    assert classification.type_id == 12
    assert classification.rule_id == "mikrotik-router"
  end

  test "classifies vJunos identity as Juniper router" do
    update = %{
      hostname: "vjunos-lab-01",
      source: "mapper",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.2636.1.1.1.2.160",
        "sys_descr" => "Juniper Networks, Inc. vJunos-router",
        "sys_name" => "vjunos-lab-01",
        "ip_forwarding" => "1"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Juniper"
    assert classification.type == "Router"
    assert classification.type_id == 12
    assert classification.rule_id == "juniper-router-vjunos"
  end

  test "does not fall through to MikroTik for Juniper enterprise OID" do
    update = %{
      hostname: "vjunos-lab-02",
      source: "mapper",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.2636.1.1.1.2.160",
        "sys_descr" => "JUNOS 24.2R1.17 Kernel 64-bit  JNPR-14.1-20240215.8d8224c_buil",
        "sys_name" => "vjunos-lab-02",
        "ip_forwarding" => "1"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Juniper"
    refute classification.vendor_name == "MikroTik"
    assert classification.rule_id == "juniper-router-vjunos"
  end

  test "filesystem override with same rule id takes precedence over built-in rule" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "device-enrichment-rules-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    File.write!(
      Path.join(tmp_dir, "override.yaml"),
      """
      rules:
        - id: ubiquiti-router-udm
          enabled: true
          priority: 2000
          confidence: 99
          reason: "test override"
          match:
            all:
              ip_forwarding: [1]
            any:
              sys_name: ["farm01"]
          set:
            vendor_name: "Ubiquiti-Override"
            type: "Router"
            type_id: 12
      """
    )

    Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, tmp_dir)
    DeviceEnrichmentRules.reload()

    update = %{
      hostname: "farm01",
      source: "mapper",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
        "sys_name" => "farm01",
        "ip_forwarding" => "1"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Ubiquiti-Override"
    assert classification.rule_id == "ubiquiti-router-udm"
    assert classification.source == "filesystem"
  end

  test "invalid filesystem rules are skipped and built-in defaults still apply" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "device-enrichment-rules-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    File.write!(
      Path.join(tmp_dir, "invalid.yaml"),
      """
      rules:
        - id: broken-ubiquiti
          enabled: true
          priority: 100
          confidence: 95
          set:
            vendor_name: "Broken"
      """
    )

    Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, tmp_dir)
    DeviceEnrichmentRules.reload()

    update = %{
      hostname: "farm01",
      source: "mapper",
      metadata: %{
        "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
        "sys_name" => "farm01",
        "ip_forwarding" => "1"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Ubiquiti"
    assert classification.rule_id == "ubiquiti-router-udm"
    assert classification.source == "builtin"
  end

  test "parse_and_validate_yaml returns normalized rules for valid content" do
    yaml = """
    rules:
      - id: ui-test-rule
        enabled: true
        priority: 1000
        confidence: 90
        reason: "UI test"
        match:
          all:
            source: ["mapper"]
          any:
            sys_descr: ["udm"]
        set:
          vendor_name: "Ubiquiti"
          type: "Router"
          type_id: 12
    """

    assert {:ok, [rule]} =
             DeviceEnrichmentRules.parse_and_validate_yaml(yaml,
               source: "filesystem",
               file: "ui-test.yaml"
             )

    assert rule.id == "ui-test-rule"
    assert rule.set["vendor_name"] == "Ubiquiti"
  end

  test "parse_and_validate_yaml returns errors for invalid schema" do
    yaml = """
    rules:
      - id: bad-rule
        set:
          vendor_name: "No match map"
    """

    assert {:error, errors} =
             DeviceEnrichmentRules.parse_and_validate_yaml(yaml,
               source: "filesystem",
               file: "bad.yaml"
             )

    assert Enum.any?(errors, &String.contains?(&1, "match"))
  end
end
