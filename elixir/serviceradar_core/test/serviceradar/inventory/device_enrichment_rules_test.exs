defmodule ServiceRadar.Inventory.DeviceEnrichmentRulesTest do
  @moduledoc """
  Built-in classification and YAML validation for `DeviceEnrichmentRules`.

  Nothing here mutates `:device_enrichment_rules_dir`; the tests that do live in
  `device_enrichment_rules_filesystem_test.exs`. The `reload/0` below is the
  guard for that separation -- it drops any override left in the VM-wide
  `:persistent_term` cache, so these assertions always run against the built-in
  ruleset regardless of what ran before them.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.DeviceEnrichmentRules

  setup do
    DeviceEnrichmentRules.reload()
    :ok
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

  test "classifies passive TCP fingerprint evidence" do
    update = %{
      hostname: "passive-linux-host",
      source: "passive-netprobe",
      metadata: %{
        "passive_fingerprint.tcp.os_family" => "linux",
        "passive_fingerprint.tcp.os_name" => "Linux 5.x",
        "passive_fingerprint.tcp.signature" => "64240:64:1:60:M1460,S,T,N,W7"
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "Linux"
    assert classification.type == "Server"
    assert classification.type_id == 1
    assert classification.os_family == "Linux"
    assert classification.rule_id == "passive-fingerprint-linux-host"
  end

  test "classifies nested passive HTTP server evidence" do
    update = %{
      hostname: "passive-http-host",
      source: "passive-netprobe",
      metadata: %{
        "passive_fingerprint" => %{
          "http" => %{
            "server" => "nginx/1.24.0"
          }
        }
      }
    }

    classification = DeviceEnrichmentRules.classify(update)

    assert classification.vendor_name == "NGINX"
    assert classification.type == "Server"
    assert classification.type_id == 1
    assert classification.rule_id == "passive-fingerprint-nginx-http-server"
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

  test "parse_and_validate_yaml accepts passive fingerprint selectors and os_family output" do
    yaml = """
    rules:
      - id: passive-test-rule
        enabled: true
        priority: 100
        confidence: 60
        reason: "Passive selector test"
        match:
          any:
            metadata.passive_fingerprint.tcp.os_family: ["linux"]
            passive_fingerprint.tls.ja4: ["t13d"]
        set:
          vendor_name: "Linux"
          type: "Server"
          type_id: 1
          os_family: "Linux"
    """

    assert {:ok, [rule]} =
             DeviceEnrichmentRules.parse_and_validate_yaml(yaml,
               source: "filesystem",
               file: "passive-test.yaml"
             )

    assert rule.match["any"]["metadata.passive_fingerprint.tcp.os_family"] == ["linux"]
    assert rule.set["os_family"] == "Linux"
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
